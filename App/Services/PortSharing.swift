import Combine
import Foundation
import Network
import SoulseekKit

/// Makes colon3o reachable by other Soulseek users. The app listens on a port; getting that port
/// open to the internet is left to the network: a VPN that forwards it to this phone (how colon3o
/// is meant to be used), or a rule set by hand on a router. This keeps the port setting, pauses
/// sharing off Wi-Fi if asked, and checks the port from outside.
@MainActor
final class PortSharing: ObservableObject {
    enum CheckStatus: Equatable {
        case unknown
        case checking
        case open(UInt16)
        case closed(UInt16)
        case failed(String)
    }

    static let portKey = "soulseek.listenPort"
    static let shareOnlyOnWiFiKey = "soulseek.shareOnlyOnWiFi"
    static let defaultPort: UInt16 = 2234
    static let portRange: ClosedRange<Int> = 1024...65535

    @Published private(set) var check: CheckStatus = .unknown
    @Published private(set) var onWiFi = false

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return Self.portRange.contains(stored) ? UInt16(stored) : Self.defaultPort
    }

    /// Off unless turned on: a forwarded port works on mobile data too.
    private var shareOnlyOnWiFi: Bool { UserDefaults.standard.bool(forKey: Self.shareOnlyOnWiFiKey) }

    private let soulseek: SoulseekModel
    private let monitor = NWPathMonitor()
    /// Checks run one at a time, in order.
    private var work: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(soulseek: SoulseekModel) {
        self.soulseek = soulseek
        soulseek.client.setListenPort(port)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathChanged(path) }
        }
        monitor.start(queue: DispatchQueue(label: "colon3o.network-path"))
        // Published values arrive on the main thread (SoulseekModel is main-actor); the check itself
        // runs a moment later, after the new value is in place. Checks once each time we log in or
        // the listening port comes up.
        soulseek.$connection.removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkPort() } }
            .store(in: &cancellables)
        soulseek.$listenerStatus
            .map { status -> Bool in
                if case .listening = status { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkPort() } }
            .store(in: &cancellables)
    }

    // MARK: Settings

    /// After the toggle changes.
    func settingsChanged() {
        updateSharingAllowed()
    }

    func setPort(_ newPort: UInt16) {
        guard Self.portRange.contains(Int(newPort)), newPort != port else { return }
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        check = .unknown
        soulseek.client.setListenPort(newPort)
    }

    func checkPort() {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await self.runCheck()
        }
    }

    // MARK: State

    private var isListening: Bool {
        if case .listening = soulseek.listenerStatus { return true }
        return false
    }

    private func pathChanged(_ newPath: NWPath) {
        onWiFi = newPath.status == .satisfied && newPath.usesInterfaceType(.wifi)
        updateSharingAllowed()
    }

    private func updateSharingAllowed() {
        soulseek.client.setSharingAllowed(!shareOnlyOnWiFi || onWiFi)
    }

    /// Asks slsknet.org's tester (as Nicotine+ does) to connect back to us. It tries the address
    /// the request came from, so through a VPN it tests the VPN's forwarded port.
    private func runCheck() async {
        guard soulseek.isLoggedIn, isListening else {
            check = .unknown
            return
        }
        let port = self.port
        check = .checking
        var request = URLRequest(url: PortTest.url(port: port), timeoutInterval: 20)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let open = PortTest.parse(String(decoding: data.prefix(64 * 1024), as: UTF8.self), port: port) else {
            check = .failed("Couldn't reach the port checker")
            return
        }
        check = open ? .open(port) : .closed(port)
    }
}
