import Combine
import Darwin
import Foundation
import Network
import SoulseekKit

/// Makes colon3o reachable by other Soulseek users, like Nicotine+ does on a computer: asks the
/// home router to forward the listening port (NAT-PMP first, then UPnP), keeps that rule renewed
/// while online, removes it when going offline, and checks the port from outside.
///
/// Only on Wi-Fi: mobile networks don't let anyone open ports, and the app never asks routers on
/// other networks it passes through for more than it needs. Rules are short (an hour, renewed
/// every 20 minutes), so one left behind when the app is closed soon expires.
@MainActor
final class PortSharing: ObservableObject {
    enum RouterStatus: Equatable {
        /// Not trying, and why.
        case off(String)
        case working
        case opened(method: String, externalPort: UInt16)
        case failed(String)
    }

    enum CheckStatus: Equatable {
        case unknown
        case checking
        case open(UInt16)
        case closed(UInt16)
        case failed(String)
    }

    static let portKey = "soulseek.listenPort"
    static let openRouterPortKey = "soulseek.openRouterPort"
    static let shareOnlyOnWiFiKey = "soulseek.shareOnlyOnWiFi"
    static let defaultPort: UInt16 = 2234
    static let portRange: ClosedRange<Int> = 1024...65535

    @Published private(set) var router: RouterStatus = .off("Not connected to Soulseek")
    @Published private(set) var check: CheckStatus = .unknown
    @Published private(set) var onWiFi = false
    /// This phone's address on the Wi-Fi, for forwarding the port by hand.
    @Published private(set) var localIP: String?
    /// Set when the router's own internet address is shared by the provider, which no rule fixes.
    @Published private(set) var providerNote: String?

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return Self.portRange.contains(stored) ? UInt16(stored) : Self.defaultPort
    }

    private var openRouterPort: Bool { AppSettings.flag(Self.openRouterPortKey) }
    private var shareOnlyOnWiFi: Bool { AppSettings.flag(Self.shareOnlyOnWiFiKey) }

    private let soulseek: SoulseekModel
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var mapping: PortMapper.Mapping?
    /// Where mapping last failed; not retried there until something changes or Try Again.
    private var failedAt: (router: PortMapper.RouterInfo, port: UInt16)?
    private var renewal: Task<Void, Never>?
    /// Router work runs one step at a time, in order.
    private var work: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(soulseek: SoulseekModel) {
        self.soulseek = soulseek
        soulseek.client.setListenPort(port)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathChanged(path) }
        }
        monitor.start(queue: DispatchQueue(label: "colon3o.network-path"))
        // Published values arrive on the main thread (SoulseekModel is main-actor); the work itself
        // runs a moment later, after the new value is in place.
        soulseek.$connection.removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
        soulseek.$listenerStatus
            .map { status -> Bool in
                if case .listening = status { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
    }

    // MARK: Settings

    /// After the toggles change.
    func settingsChanged() {
        updateSharingAllowed()
        refresh()
    }

    func setPort(_ newPort: UInt16) {
        guard Self.portRange.contains(Int(newPort)), newPort != port else { return }
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        check = .unknown
        soulseek.client.setListenPort(newPort)
        refresh()
    }

    func tryAgain() {
        enqueue { await self.reconcile(renewing: false, retry: true) }
    }

    func checkPort() {
        enqueue { await self.runCheck() }
    }

    // MARK: State

    private var isListening: Bool {
        if case .listening = soulseek.listenerStatus { return true }
        return false
    }

    private func pathChanged(_ newPath: NWPath) {
        path = newPath
        onWiFi = newPath.status == .satisfied && newPath.usesInterfaceType(.wifi)
        localIP = PortMapper.routerInfo(for: newPath)?.localIP
        updateSharingAllowed()
        refresh()
    }

    private func updateSharingAllowed() {
        soulseek.client.setSharingAllowed(!shareOnlyOnWiFi || onWiFi)
    }

    private func refresh() {
        enqueue { await self.reconcile(renewing: false, retry: false) }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Brings the router rule in line with the current network, port, settings and login.
    private func reconcile(renewing: Bool, retry: Bool) async {
        let info = path.flatMap(PortMapper.routerInfo(for:))
        let wanted: PortMapper.RouterInfo? = openRouterPort && soulseek.isLoggedIn && isListening ? info : nil

        // Drop a rule that no longer fits: another network, another port, turned off, logged out.
        if let current = mapping, wanted == nil || current.router != wanted || current.internalPort != port {
            mapping = nil
            renewal?.cancel()
            renewal = nil
            providerNote = nil
            soulseek.client.setAdvertisedPort(0)
            // Only reachable while still on the same network; otherwise it simply expires.
            if current.router == info { await PortMapper.unmap(current) }
        }

        guard let wanted else {
            failedAt = nil
            router = .off(offReason(hasRouter: info != nil))
            if !soulseek.isLoggedIn { check = .unknown }
            return
        }
        if mapping != nil, !renewing { return }
        if !retry, !renewing, let failedAt, failedAt.router == wanted, failedAt.port == port { return }
        failedAt = nil

        if !renewing { router = .working }
        switch await PortMapper.map(port: port, router: wanted, lease: PortMapper.lease) {
        case let .success(newMapping):
            // Things may have changed while the router answered.
            guard openRouterPort, soulseek.isLoggedIn, path.flatMap(PortMapper.routerInfo(for:)) == wanted else {
                await PortMapper.unmap(newMapping)
                router = .off(offReason(hasRouter: info != nil))
                return
            }
            let firstTime = mapping == nil
            mapping = newMapping
            router = .opened(method: newMapping.method.name, externalPort: newMapping.externalPort)
            soulseek.client.setAdvertisedPort(newMapping.externalPort)
            providerNote = newMapping.externalIP.flatMap { address in
                IPv4.isSharedByProvider(address) || IPv4.isPrivate(address)
                    ? "Your router's own internet address (\(address)) is shared by your provider or sits behind another router, so peers may still not reach you."
                    : nil
            }
            scheduleRenewal(after: newMapping.renewAfter)
            if firstTime { await runCheck() }
        case let .failure(failure):
            if renewing, let current = mapping, !current.hasExpired {
                // The rule still holds for a while; try again sooner.
                scheduleRenewal(after: 120)
                return
            }
            mapping = nil
            providerNote = nil
            failedAt = (wanted, port)
            router = .failed(failure.message)
            soulseek.client.setAdvertisedPort(0)
            // Try again in a while; Try Again or a change of network does it sooner.
            scheduleRetry(after: 10 * 60)
            // It may still be forwarded by hand.
            await runCheck()
        }
    }

    private func offReason(hasRouter: Bool) -> String {
        if !openRouterPort { return "Turned off" }
        if !soulseek.isLoggedIn { return "Not connected to Soulseek" }
        if !isListening { return "Waiting for the listening port" }
        if !onWiFi { return "Only on Wi-Fi" }
        if !hasRouter { return "Couldn't find the router on this Wi-Fi" }
        return "Waiting"
    }

    private func scheduleRenewal(after seconds: TimeInterval) {
        renewal?.cancel()
        renewal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 15) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.enqueue { await self.reconcile(renewing: true, retry: false) }
        }
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        renewal?.cancel()
        renewal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.enqueue { await self.reconcile(renewing: false, retry: true) }
        }
    }

    private func runCheck() async {
        guard soulseek.isLoggedIn, isListening else {
            check = .unknown
            return
        }
        let outside = mapping?.externalPort ?? port
        check = .checking
        // Give the router a moment to apply a new rule.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        switch await PortMapper.checkFromOutside(port: outside) {
        case .some(true): check = .open(outside)
        case .some(false): check = .closed(outside)
        case .none: check = .failed("Couldn't reach the port checker")
        }
    }
}

// MARK: - Talking to the router

enum PortMapper {
    /// One hour, renewed every 20 minutes while online.
    static let lease: UInt32 = 3600
    /// Names our UPnP rules, with an ID for this install so another phone's rule is never
    /// mistaken for ours.
    static let description: String = {
        let key = "soulseek.portMappingID"
        if let id = UserDefaults.standard.string(forKey: key) { return "colon3o " + id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return "colon3o " + id
    }()

    struct RouterInfo: Equatable {
        let gateway: String
        let localIP: String
    }

    enum Method: Equatable {
        case natpmp
        case upnp(UPnP.Service)

        var name: String {
            switch self {
            case .natpmp: return "NAT-PMP"
            case .upnp: return "UPnP"
            }
        }
    }

    struct Mapping: Equatable {
        let method: Method
        let router: RouterInfo
        let internalPort: UInt16
        let externalPort: UInt16
        /// Seconds; 0 means the router only does permanent rules.
        let lifetime: UInt32
        var externalIP: String?
        var obtained = Date()

        /// Halfway through the lease (at most 20 minutes), well before it runs out.
        var renewAfter: TimeInterval {
            lifetime == 0 ? 30 * 60 : max(15, min(Double(lifetime) / 2, 20 * 60))
        }

        var hasExpired: Bool {
            lifetime > 0 && Date().timeIntervalSince(obtained) >= Double(lifetime)
        }
    }

    struct Failure: Error {
        let message: String
    }

    // MARK: Network facts

    /// The router and this phone's address, on Wi-Fi with a private IPv4 network only.
    static func routerInfo(for path: NWPath) -> RouterInfo? {
        guard path.status == .satisfied, path.usesInterfaceType(.wifi),
              let wifi = path.availableInterfaces.first(where: { $0.type == .wifi }) else { return nil }
        let gateway = path.gateways.lazy.compactMap { endpoint -> String? in
            guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else { return nil }
            return strippingInterface("\(address)")
        }.first
        guard let gateway, IPv4.isPrivate(gateway),
              let local = ipv4Address(ofInterface: wifi.name), IPv4.isPrivate(local) else { return nil }
        return RouterInfo(gateway: gateway, localIP: local)
    }

    private static func strippingInterface(_ text: String) -> String {
        text.firstIndex(of: "%").map { String(text[..<$0]) } ?? text
    }

    private static func ipv4Address(ofInterface name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: entry.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: Mapping

    static func map(port: UInt16, router: RouterInfo, lease: UInt32) async -> Result<Mapping, Failure> {
        let natpmp = await mapWithNATPMP(port: port, router: router, lease: lease)
        if case .success = natpmp { return natpmp }
        let upnp = await mapWithUPnP(port: port, router: router, lease: lease)
        if case .success = upnp { return upnp }
        // Report the more useful of the two reasons.
        if case let .failure(upnpFailure) = upnp, upnpFailure.message != Self.noUPnP { return upnp }
        if case let .failure(natpmpFailure) = natpmp, natpmpFailure.message != Self.noNATPMP { return natpmp }
        return .failure(Failure(message: "The router didn't answer NAT-PMP or UPnP. Turn on UPnP in its settings, or forward the port by hand."))
    }

    static func unmap(_ mapping: Mapping) async {
        switch mapping.method {
        case .natpmp:
            let request = NATPMP.mapTCPRequest(internalPort: mapping.internalPort, externalPort: 0, lifetime: 0)
            _ = await udp(to: mapping.router, port: NATPMP.port, payloads: [request], waits: [0.25, 0.5], collect: false,
                          sameSourcePort: true) {
                NATPMP.parseMapResponse($0) != nil
            }
        case let .upnp(service):
            _ = try? await soap(service, router: mapping.router, action: "DeletePortMapping",
                                body: UPnP.deletePortMappingBody(serviceType: service.type, externalPort: mapping.externalPort))
        }
    }

    private static let noNATPMP = "No NAT-PMP"
    private static let noUPnP = "No UPnP"

    private static func mapWithNATPMP(port: UInt16, router: RouterInfo, lease: UInt32) async -> Result<Mapping, Failure> {
        let addressReplies = await udp(to: router, port: NATPMP.port, payloads: [NATPMP.publicAddressRequest],
                                       waits: [0.25, 0.5, 1], collect: false, sameSourcePort: true) {
            NATPMP.parsePublicAddressResponse($0) != nil
        }
        guard let addressReply = addressReplies.first.flatMap(NATPMP.parsePublicAddressResponse) else {
            return .failure(Failure(message: noNATPMP))
        }
        let request = NATPMP.mapTCPRequest(internalPort: port, externalPort: port, lifetime: lease)
        let replies = await udp(to: router, port: NATPMP.port, payloads: [request], waits: [0.25, 0.5, 1, 2], collect: false,
                                sameSourcePort: true) {
            NATPMP.parseMapResponse($0)?.internalPort == port
        }
        guard let reply = replies.first.flatMap(NATPMP.parseMapResponse) else {
            return .failure(Failure(message: "The router stopped answering NAT-PMP"))
        }
        guard reply.result == 0, reply.externalPort != 0, reply.lifetime > 0 else {
            return .failure(Failure(message: "NAT-PMP: " + NATPMP.describe(result: reply.result)))
        }
        return .success(Mapping(method: .natpmp, router: router, internalPort: port, externalPort: reply.externalPort,
                                lifetime: reply.lifetime,
                                externalIP: addressReply.result == 0 ? addressReply.address : nil))
    }

    private static func mapWithUPnP(port: UInt16, router: RouterInfo, lease: UInt32) async -> Result<Mapping, Failure> {
        guard let service = await findUPnPService(router: router) else { return .failure(Failure(message: noUPnP)) }

        func add(_ leaseSeconds: UInt32) async throws -> MiniHTTP.Response {
            try await soap(service, router: router, action: "AddPortMapping",
                           body: UPnP.addPortMappingBody(serviceType: service.type, externalPort: port, internalPort: port,
                                                         internalClient: router.localIP, description: description,
                                                         leaseSeconds: leaseSeconds))
        }

        do {
            var granted = lease
            var response = try await add(lease)
            var code = response.status == 200 ? nil : UPnP.errorCode(inFault: response.text)

            if code == 725 {
                // OnlyPermanentLeasesSupported (older routers).
                granted = 0
                response = try await add(0)
                code = response.status == 200 ? nil : UPnP.errorCode(inFault: response.text)
            }
            if code == 718 {
                // The port is already forwarded somewhere. If it's our own rule from an earlier
                // address of this phone, replace it; anyone else's is left alone.
                let entry = try await soap(service, router: router, action: "GetSpecificPortMappingEntry",
                                           body: UPnP.getSpecificEntryBody(serviceType: service.type, externalPort: port))
                let owner = UPnP.value("NewInternalClient", in: entry.text) ?? "another device"
                guard UPnP.value("NewPortMappingDescription", in: entry.text) == description else {
                    return .failure(Failure(message: "Port \(port) is already forwarded to \(owner) on the router."))
                }
                _ = try await soap(service, router: router, action: "DeletePortMapping",
                                   body: UPnP.deletePortMappingBody(serviceType: service.type, externalPort: port))
                response = try await add(granted)
                code = response.status == 200 ? nil : UPnP.errorCode(inFault: response.text)
            }
            guard response.status == 200 else {
                switch code {
                case 606?: return .failure(Failure(message: "UPnP is set to read-only on the router."))
                case 718?: return .failure(Failure(message: "Port \(port) is already forwarded to another device on the router."))
                case let other?: return .failure(Failure(message: "The router refused the UPnP request (error \(other))."))
                case nil: return .failure(Failure(message: "The router refused the UPnP request (HTTP \(response.status))."))
                }
            }

            let addressReply = try? await soap(service, router: router, action: "GetExternalIPAddress",
                                               body: UPnP.getExternalAddressBody(serviceType: service.type))
            let externalIP = addressReply.flatMap { UPnP.value("NewExternalIPAddress", in: $0.text) }.flatMap { $0.isEmpty ? nil : $0 }
            return .success(Mapping(method: .upnp(service), router: router, internalPort: port, externalPort: port,
                                    lifetime: granted, externalIP: externalIP))
        } catch {
            return .failure(Failure(message: "Lost contact with the router: \(error.localizedDescription)"))
        }
    }

    /// Asks the router itself (unicast, since iOS blocks multicast for sideloaded apps) where its
    /// UPnP description is, and reads the port-mapping service from it.
    private static func findUPnPService(router: RouterInfo) async -> UPnP.Service? {
        let requests = UPnP.searchTargets.map { UPnP.searchRequest(host: router.gateway, target: $0) }
        // Routers may answer M-SEARCH from another port, so only the address is checked here.
        let replies = await udp(to: router, port: UPnP.ssdpPort, payloads: requests, waits: [1.5, 1.5], collect: true,
                                sameSourcePort: false) {
            UPnP.location(fromSearchResponse: $0) != nil
        }
        var seen = Set<String>()
        // Only descriptions on the router itself: nothing else on the network gets a say.
        let locations = replies.compactMap(UPnP.location(fromSearchResponse:))
            .filter { $0.host == router.gateway && seen.insert($0.absoluteString).inserted }
        for location in locations.prefix(3) {
            guard let response = try? await http(location, method: "GET", headers: [], body: nil),
                  response.status == 200,
                  let service = UPnP.portMappingService(inDescription: response.text, location: location),
                  service.controlURL.host == router.gateway else { continue }
            return service
        }
        return nil
    }

    private static func soap(_ service: UPnP.Service, router: RouterInfo, action: String, body: String) async throws -> MiniHTTP.Response {
        guard service.controlURL.host == router.gateway else { throw Failure(message: "Unexpected router address") }
        return try await http(service.controlURL, method: "POST",
                              headers: [("Content-Type", "text/xml; charset=\"utf-8\""),
                                        ("SOAPAction", UPnP.soapAction(serviceType: service.type, action: action))],
                              body: Data(body.utf8))
    }

    // MARK: Port check

    /// Asks slsknet.org's tester to connect back to us. nil: no usable answer.
    static func checkFromOutside(port: UInt16) async -> Bool? {
        var request = URLRequest(url: PortTest.url(port: port), timeoutInterval: 20)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PortTest.parse(String(decoding: data.prefix(64 * 1024), as: UTF8.self), port: port)
    }

    // MARK: Transport

    /// Sends UDP datagrams to the router and gathers its replies (only the router's: anything
    /// from another address is ignored). Each entry in `waits` is one round: send, then listen
    /// that long. `collect` keeps listening for more replies through the round.
    private static func udp(to router: RouterInfo, port: UInt16, payloads: [Data], waits: [TimeInterval], collect: Bool,
                            sameSourcePort: Bool, accept: @escaping @Sendable (Data) -> Bool) async -> [Data] {
        await Task.detached(priority: .utility) {
            udpExchange(gateway: router.gateway, port: port, localIP: router.localIP, payloads: payloads,
                        waits: waits, collect: collect, sameSourcePort: sameSourcePort, accept: accept)
        }.value
    }

    private static func udpExchange(gateway: String, port: UInt16, localIP: String, payloads: [Data],
                                    waits: [TimeInterval], collect: Bool, sameSourcePort: Bool, accept: (Data) -> Bool) -> [Data] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return [] }
        defer { close(socketFD) }

        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        // Send from the Wi-Fi address, so the request never goes out over mobile data.
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, localIP, &local.sin_addr) == 1 else { return [] }
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0 else { return [] }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        guard inet_pton(AF_INET, gateway, &remote.sin_addr) == 1 else { return [] }

        var replies: [Data] = []
        let capacity = 2048
        var buffer = [UInt8](repeating: 0, count: capacity)
        for wait in waits {
            for payload in payloads {
                _ = payload.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &remote) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, length)
                        }
                    }
                }
            }
            let deadline = Date().addingTimeInterval(wait)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                var poller = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(max(1, remaining * 1000))) > 0 else { break }
                var from = sockaddr_in()
                var fromLength = length
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, &buffer, capacity, 0, $0, &fromLength)
                    }
                }
                guard count > 0 else { break }
                guard from.sin_addr.s_addr == remote.sin_addr.s_addr,
                      !sameSourcePort || from.sin_port == remote.sin_port else { continue }
                let data = Data(buffer[0..<count])
                guard accept(data) else { continue }
                replies.append(data)
                if !collect || replies.count >= 8 { return replies }
            }
            if !replies.isEmpty { return replies }
        }
        return replies
    }

    /// A small HTTP request to the router over a plain TCP connection (it's on the local network,
    /// so there's no TLS, and URLSession's security rules don't fit).
    private static func http(_ url: URL, method: String, headers: [(String, String)], body: Data?) async throws -> MiniHTTP.Response {
        guard url.scheme?.lowercased() == "http", let host = url.host, IPv4.isPrivate(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw Failure(message: "Unexpected router address")
        }
        let portNumber = UInt16(clamping: url.port ?? 80)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { throw Failure(message: "Unexpected router address") }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let request = MiniHTTP.request(method: method, host: host, port: portNumber, path: path, headers: headers, body: body)
        return try await withCheckedThrowingContinuation { continuation in
            RouterHTTPExchange(host: host, port: port, continuation: continuation).start(request: request, timeout: 6)
        }
    }
}

/// One request/response over its own connection; the continuation is resumed exactly once.
private final class RouterHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "colon3o.router-http")
    private var received = Data()
    private var continuation: CheckedContinuation<MiniHTTP.Response, Error>?

    init(host: String, port: NWEndpoint.Port, continuation: CheckedContinuation<MiniHTTP.Response, Error>) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        self.continuation = continuation
    }

    func start(request: Data, timeout: TimeInterval) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { finish(.failure(error)) }
                })
                receive()
            case let .waiting(error), let .failed(error):
                finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(PortMapper.Failure(message: "The router didn't answer in time")))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { received.append(data) }
            let closed = isComplete || error != nil
            do {
                if let response = try MiniHTTP.parse(received, connectionClosed: closed) {
                    finish(.success(response))
                    return
                }
            } catch {
                finish(.failure(PortMapper.Failure(message: "The router sent an answer colon3o can't read")))
                return
            }
            if closed {
                finish(.failure(PortMapper.Failure(message: "The router closed the connection")))
            } else {
                receive()
            }
        }
    }

    /// Always on `queue`, so it can't race with itself.
    private func finish(_ result: Result<MiniHTTP.Response, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
