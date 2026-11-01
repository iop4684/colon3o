import Foundation

// Pure encoders and parsers for opening the listening port on a home router (NAT-PMP, then
// UPnP), checking it from outside, and limiting who may connect. No networking here, so all of it
// is covered by the Linux tests; the app does the actual talking.

// MARK: - NAT-PMP (RFC 6886)

public enum NATPMP {
    public static let port: UInt16 = 5351

    /// Asks the router for its public address; also tells whether it speaks NAT-PMP at all.
    public static let publicAddressRequest = Data([0, 0])

    /// Maps a TCP port. A lifetime of 0 removes the mapping.
    public static func mapTCPRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var bytes: [UInt8] = [0, 2, 0, 0]
        bytes += bigEndian(internalPort)
        bytes += bigEndian(externalPort)
        bytes += bigEndian(lifetime)
        return Data(bytes)
    }

    public struct PublicAddressResponse: Equatable, Sendable {
        public let result: UInt16
        public let address: String
    }

    public struct MapResponse: Equatable, Sendable {
        public let result: UInt16
        public let internalPort: UInt16
        public let externalPort: UInt16
        public let lifetime: UInt32
    }

    public static func parsePublicAddressResponse(_ data: Data) -> PublicAddressResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] == 0, bytes[1] == 128 else { return nil }
        let result = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        return PublicAddressResponse(result: result, address: "\(bytes[8]).\(bytes[9]).\(bytes[10]).\(bytes[11])")
    }

    /// Only answers to a TCP mapping request (opcode 2 + 128).
    public static func parseMapResponse(_ data: Data) -> MapResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 0, bytes[1] == 130 else { return nil }
        func u16(_ index: Int) -> UInt16 { UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) }
        let lifetime = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        return MapResponse(result: u16(2), internalPort: u16(8), externalPort: u16(10), lifetime: lifetime)
    }

    public static func describe(result: UInt16) -> String {
        switch result {
        case 0: return "Success"
        case 1: return "Unsupported version"
        case 2: return "Not authorized (port mapping is turned off on the router)"
        case 3: return "Router's network is down"
        case 4: return "Router is out of resources"
        case 5: return "Unsupported request"
        default: return "Error \(result)"
        }
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

// MARK: - UPnP Internet Gateway Device

public enum UPnP {
    public static let ssdpPort: UInt16 = 1900

    /// What to ask for, most specific first. Routers answer the ones they offer.
    public static let searchTargets = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    /// Services that can map ports, in order of preference.
    public static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    /// A unicast M-SEARCH, sent straight to the router (iOS doesn't let sideloaded apps multicast).
    public static func searchRequest(host: String, target: String) -> Data {
        Data(("M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(host):\(ssdpPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: \(target)\r\n"
            + "\r\n").utf8)
    }

    /// The LOCATION header of an SSDP answer.
    public static func location(fromSearchResponse data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let status = lines.first, status.hasPrefix("HTTP/"), status.contains(" 200") else { return nil }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value), url.scheme?.lowercased() == "http", url.host != nil else { return nil }
            return url
        }
        return nil
    }

    public struct Service: Equatable, Sendable {
        public let type: String
        public let controlURL: URL
    }

    /// The best port-mapping service in a device description, with its control URL made absolute.
    public static func portMappingService(inDescription xml: String, location: URL) -> Service? {
        var base = location
        if let urlBase = firstElement("URLBase", in: xml), let url = URL(string: urlBase), url.host != nil {
            base = url
        }
        var found: [Service] = []
        for block in elements("service", in: xml) {
            guard let type = firstElement("serviceType", in: block), serviceTypes.contains(type),
                  let control = firstElement("controlURL", in: block), !control.isEmpty,
                  let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
            found.append(Service(type: type, controlURL: url))
        }
        for type in serviceTypes {
            if let service = found.first(where: { $0.type == type }) { return service }
        }
        return nil
    }

    public static func addPortMappingBody(serviceType: String, externalPort: UInt16, internalPort: UInt16,
                                          internalClient: String, description: String, leaseSeconds: UInt32) -> String {
        envelope(action: "AddPortMapping", serviceType: serviceType, arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "TCP"),
            ("NewInternalPort", String(internalPort)),
            ("NewInternalClient", internalClient),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", description),
            ("NewLeaseDuration", String(leaseSeconds)),
        ])
    }

    public static func deletePortMappingBody(serviceType: String, externalPort: UInt16) -> String {
        envelope(action: "DeletePortMapping", serviceType: serviceType, arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "TCP"),
        ])
    }

    public static func getSpecificEntryBody(serviceType: String, externalPort: UInt16) -> String {
        envelope(action: "GetSpecificPortMappingEntry", serviceType: serviceType, arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "TCP"),
        ])
    }

    public static func getExternalAddressBody(serviceType: String) -> String {
        envelope(action: "GetExternalIPAddress", serviceType: serviceType, arguments: [])
    }

    public static func soapAction(serviceType: String, action: String) -> String { "\"\(serviceType)#\(action)\"" }

    /// The UPnP error code in a SOAP fault (e.g. 718: the port is mapped to another device).
    public static func errorCode(inFault xml: String) -> Int? {
        firstElement("errorCode", in: xml).flatMap { Int($0) }
    }

    /// A named value in a SOAP answer, like NewExternalIPAddress or NewInternalClient.
    public static func value(_ name: String, in xml: String) -> String? {
        firstElement(name, in: xml)
    }

    private static func envelope(action: String, serviceType: String, arguments: [(String, String)]) -> String {
        let body = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>\r\n"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(escape(serviceType))\">\(body)</u:\(action)></s:Body></s:Envelope>\r\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Contents of every <name>…</name>, ignoring namespace prefixes and attributes.
    static func elements(_ name: String, in xml: String) -> [String] {
        var results: [String] = []
        var searchStart = xml.startIndex
        while let open = openTag(name, in: xml, from: searchStart) {
            guard let close = closeTag(name, in: xml, from: open.upperBound) else { break }
            results.append(String(xml[open.upperBound..<close.lowerBound]))
            searchStart = close.upperBound
        }
        return results
    }

    static func firstElement(_ name: String, in xml: String) -> String? {
        guard let open = openTag(name, in: xml, from: xml.startIndex),
              let close = closeTag(name, in: xml, from: open.upperBound) else { return nil }
        return unescape(xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "<name>", "<name attr=…>" or "<prefix:name …>".
    private static func openTag(_ name: String, in xml: String, from start: String.Index) -> Range<String.Index>? {
        var index = start
        while let lt = xml[index...].firstIndex(of: "<") {
            guard let gt = xml[lt...].firstIndex(of: ">") else { return nil }
            let inside = xml[xml.index(after: lt)..<gt]
            let tagName = inside.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).first ?? ""
            let local = tagName.split(separator: ":").last ?? ""
            if !inside.hasPrefix("/"), !inside.hasSuffix("/"), local == name {
                return lt..<xml.index(after: gt)
            }
            index = xml.index(after: lt)
        }
        return nil
    }

    private static func closeTag(_ name: String, in xml: String, from start: String.Index) -> Range<String.Index>? {
        var index = start
        while let lt = xml[index...].range(of: "</") {
            guard let gt = xml[lt.upperBound...].firstIndex(of: ">") else { return nil }
            let tagName = xml[lt.upperBound..<gt].trimmingCharacters(in: .whitespaces)
            if (tagName.split(separator: ":").last.map(String.init) ?? "") == name {
                return lt.lowerBound..<xml.index(after: gt)
            }
            index = lt.upperBound
        }
        return nil
    }
}

// MARK: - Minimal HTTP/1.1

/// Builds requests and reads responses for talking to a router over a plain TCP connection.
public enum MiniHTTP {
    public struct Response: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data

        public var text: String { String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? "" }
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case tooLarge
    }

    public static func request(method: String, host: String, port: UInt16, path: String,
                               headers: [(String, String)] = [], body: Data? = nil) -> Data {
        var text = "\(method) \(path.isEmpty ? "/" : path) HTTP/1.1\r\n"
        text += "Host: \(host):\(port)\r\n"
        text += "User-Agent: colon3o UPnP/1.1\r\n"
        text += "Connection: close\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if let body { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Parses a response. Returns nil while more bytes are needed; `connectionClosed` means
    /// nothing more will come (a body without a length ends there).
    public static func parse(_ data: Data, connectionClosed: Bool, limit: Int = 1024 * 1024) throws -> Response? {
        guard data.count <= limit else { throw ParseError.tooLarge }
        // Plain byte arrays with integer offsets: the same behaviour everywhere.
        let bytes = [UInt8](data)
        let headerLimit = 64 * 1024
        guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            if connectionClosed || bytes.count > headerLimit { throw ParseError.malformed }
            return nil
        }
        guard headerEnd <= headerLimit else { throw ParseError.malformed }
        // Split into lines on the raw bytes: in a Swift String "\r\n" is one character, so
        // splitting text on "\n" wouldn't find it.
        let head = Array(bytes[0..<headerEnd])
        var lines: [String] = []
        var lineStart = 0
        while lineStart <= headerEnd {
            let lineEnd = find([13, 10], in: head, from: lineStart) ?? headerEnd
            guard let line = String(bytes: head[lineStart..<lineEnd], encoding: .isoLatin1) else { throw ParseError.malformed }
            lines.append(line)
            lineStart = lineEnd + 2
        }
        let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw ParseError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Array(bytes[(headerEnd + 4)...])

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = try dechunk(rest) else {
                if connectionClosed { throw ParseError.malformed }
                return nil
            }
            return Response(status: status, headers: headers, body: Data(body))
        }
        if let lengthText = headers["content-length"] {
            guard lengthText.count <= 9, let length = Int(lengthText), length >= 0, length <= limit else {
                throw ParseError.malformed
            }
            guard rest.count >= length else {
                if connectionClosed { throw ParseError.malformed }
                return nil
            }
            return Response(status: status, headers: headers, body: Data(rest[0..<length]))
        }
        // No length: the body runs until the connection closes.
        guard connectionClosed else { return nil }
        return Response(status: status, headers: headers, body: Data(rest))
    }

    /// nil while the final zero-length chunk hasn't arrived yet.
    static func dechunk(_ bytes: [UInt8]) throws -> [UInt8]? {
        var body: [UInt8] = []
        var index = 0
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: index) else { return nil }
            guard let sizeLine = String(bytes: bytes[index..<lineEnd], encoding: .isoLatin1) else { throw ParseError.malformed }
            let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard sizeText.count <= 8, let size = Int(sizeText, radix: 16), size >= 0 else { throw ParseError.malformed }
            guard body.count + size <= 1024 * 1024 else { throw ParseError.tooLarge }
            let chunkStart = lineEnd + 2
            if size == 0 { return body }
            guard bytes.count - chunkStart >= size + 2 else { return nil }
            body += bytes[chunkStart..<(chunkStart + size)]
            guard bytes[chunkStart + size] == 13, bytes[chunkStart + size + 1] == 10 else { throw ParseError.malformed }
            index = chunkStart + size + 2
        }
    }

    /// Offset of the first occurrence of `pattern` at or after `start`.
    static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, start >= 0, bytes.count - start >= pattern.count else { return nil }
        var offset = start
        while offset + pattern.count <= bytes.count {
            if bytes[offset] == pattern[0], Array(bytes[offset..<(offset + pattern.count)]) == pattern { return offset }
            offset += 1
        }
        return nil
    }
}

// MARK: - Port test

public enum PortTest {
    /// slsknet.org's own checker, as used by Nicotine+. It connects back to whoever asks.
    public static func url(port: UInt16) -> URL {
        URL(string: "https://www.slsknet.org/porttest.php?port=\(port)")!
    }

    /// true: open, false: closed, nil: an answer we don't understand.
    public static func parse(_ body: String, port: UInt16) -> Bool? {
        let text = body.lowercased()
        if text.contains("\(port)/tcp open") { return true }
        if text.contains("\(port)/tcp closed") || text.contains("\(port)/tcp filtered") { return false }
        return nil
    }
}

// MARK: - Addresses

public enum IPv4 {
    public static func octets(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = UInt8(part) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Home and office networks: 10/8, 172.16/12, 192.168/16.
    public static func isPrivate(_ address: String) -> Bool {
        guard let o = octets(address) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// 100.64/10: an address an internet provider shares between customers (carrier-grade NAT).
    public static func isSharedByProvider(_ address: String) -> Bool {
        guard let o = octets(address) else { return false }
        return o[0] == 100 && (64...127).contains(o[1])
    }
}

// MARK: - Connection limits

/// Caps connections that haven't said who they are yet, overall and per address, so nobody can
/// tie up the app by opening lots of idle connections.
public struct ConnectionLimiter: Sendable {
    public let maxTotal: Int
    public let maxPerAddress: Int
    private var counts: [String: Int] = [:]
    public private(set) var total = 0

    public init(maxTotal: Int, maxPerAddress: Int) {
        self.maxTotal = maxTotal
        self.maxPerAddress = maxPerAddress
    }

    public mutating func admit(_ address: String) -> Bool {
        guard total < maxTotal, counts[address, default: 0] < maxPerAddress else { return false }
        counts[address, default: 0] += 1
        total += 1
        return true
    }

    public mutating func release(_ address: String) {
        guard let count = counts[address], count > 0 else { return }
        counts[address] = count == 1 ? nil : count - 1
        total -= 1
    }

    public mutating func reset() {
        counts.removeAll()
        total = 0
    }
}
