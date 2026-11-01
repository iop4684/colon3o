import XCTest
@testable import SoulseekKit

/// Router port mapping, the port test and the limits on incoming connections.
final class PortMappingTests: XCTestCase {
    // MARK: NAT-PMP

    func testNATPMPMapRequestLayout() {
        let request = NATPMP.mapTCPRequest(internalPort: 2234, externalPort: 2234, lifetime: 3600)
        XCTAssertEqual([UInt8](request), [0, 2, 0, 0, 0x08, 0xBA, 0x08, 0xBA, 0, 0, 0x0E, 0x10])
        XCTAssertEqual([UInt8](NATPMP.mapTCPRequest(internalPort: 2234, externalPort: 0, lifetime: 0)),
                       [0, 2, 0, 0, 0x08, 0xBA, 0, 0, 0, 0, 0, 0])
    }

    func testNATPMPMapResponse() {
        // Version 0, opcode 130, success, epoch, internal 2234, external 40000, lifetime 7200.
        let bytes: [UInt8] = [0, 130, 0, 0, 0, 0, 0x10, 0, 0x08, 0xBA, 0x9C, 0x40, 0, 0, 0x1C, 0x20]
        XCTAssertEqual(NATPMP.parseMapResponse(Data(bytes)),
                       NATPMP.MapResponse(result: 0, internalPort: 2234, externalPort: 40000, lifetime: 7200))
        // Too short, wrong opcode (a UDP answer to something else) and wrong version are refused.
        XCTAssertNil(NATPMP.parseMapResponse(Data(bytes.prefix(15))))
        var wrongOpcode = bytes
        wrongOpcode[1] = 129
        XCTAssertNil(NATPMP.parseMapResponse(Data(wrongOpcode)))
        var wrongVersion = bytes
        wrongVersion[0] = 2
        XCTAssertNil(NATPMP.parseMapResponse(Data(wrongVersion)))
    }

    func testNATPMPFailureResult() {
        let bytes: [UInt8] = [0, 130, 0, 2, 0, 0, 0, 1, 0x08, 0xBA, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(NATPMP.parseMapResponse(Data(bytes))?.result, 2)
        XCTAssertTrue(NATPMP.describe(result: 2).contains("Not authorized"))
    }

    func testNATPMPPublicAddress() {
        let bytes: [UInt8] = [0, 128, 0, 0, 0, 0, 0, 5, 100, 72, 3, 9]
        XCTAssertEqual(NATPMP.parsePublicAddressResponse(Data(bytes)),
                       NATPMP.PublicAddressResponse(result: 0, address: "100.72.3.9"))
        XCTAssertNil(NATPMP.parsePublicAddressResponse(Data(bytes.prefix(11))))
    }

    // MARK: UPnP

    func testSearchRequestIsUnicastToRouter() {
        let text = String(decoding: UPnP.searchRequest(host: "192.168.1.1", target: UPnP.searchTargets[0]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("HOST: 192.168.1.1:1900\r\n"))
        XCTAssertTrue(text.contains("ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testSearchResponseLocation() {
        let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
            + "location:   http://192.168.1.1:5000/rootDesc.xml \r\nSERVER: OpenWRT UPnP/1.1 MiniUPnPd/2.3\r\n\r\n"
        XCTAssertEqual(UPnP.location(fromSearchResponse: Data(answer.utf8))?.absoluteString, "http://192.168.1.1:5000/rootDesc.xml")
        XCTAssertNil(UPnP.location(fromSearchResponse: Data("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n".utf8)))
        XCTAssertNil(UPnP.location(fromSearchResponse: Data("HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n".utf8)))
        XCTAssertNil(UPnP.location(fromSearchResponse: Data("HTTP/1.1 200 OK\r\nST: x\r\n\r\n".utf8)))
    }

    private let description = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
            <controlURL>/ctl/L3F</controlURL>
          </service>
        </serviceList>
        <deviceList><device><deviceList><device>
          <serviceList>
            <service>
              <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
              <controlURL>/ctl/PPPConn</controlURL>
            </service>
            <service>
              <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
              <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
              <controlURL>/ctl/IPConn</controlURL>
            </service>
          </serviceList>
        </device></deviceList></device></deviceList>
      </device>
    </root>
    """

    func testDescriptionPicksWANIPConnection() throws {
        let location = try XCTUnwrap(URL(string: "http://192.168.1.1:5000/rootDesc.xml"))
        let service = try XCTUnwrap(UPnP.portMappingService(inDescription: description, location: location))
        XCTAssertEqual(service.type, "urn:schemas-upnp-org:service:WANIPConnection:1")
        XCTAssertEqual(service.controlURL.absoluteString, "http://192.168.1.1:5000/ctl/IPConn")
    }

    func testDescriptionWithURLBaseAndPrefixes() throws {
        let xml = """
        <root><URLBase>http://10.0.0.1:49000/</URLBase><s:service xmlns:s="x">
        <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
        <controlURL>upnp/control/WANPPPConn1</controlURL></s:service></root>
        """
        let location = try XCTUnwrap(URL(string: "http://10.0.0.1:49000/igddesc.xml"))
        let service = try XCTUnwrap(UPnP.portMappingService(inDescription: xml, location: location))
        XCTAssertEqual(service.controlURL.absoluteString, "http://10.0.0.1:49000/upnp/control/WANPPPConn1")
    }

    func testDescriptionWithoutPortMappingService() throws {
        let location = try XCTUnwrap(URL(string: "http://192.168.1.1/desc.xml"))
        XCTAssertNil(UPnP.portMappingService(inDescription: "<root><service><serviceType>urn:x</serviceType><controlURL>/a</controlURL></service></root>",
                                             location: location))
        XCTAssertNil(UPnP.portMappingService(inDescription: "not xml at all <<<", location: location))
    }

    func testAddPortMappingBody() {
        let body = UPnP.addPortMappingBody(serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
                                           externalPort: 2234, internalPort: 2234, internalClient: "192.168.1.20",
                                           description: "colon3o <&>", leaseSeconds: 3600)
        XCTAssertTrue(body.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"))
        XCTAssertTrue(body.contains("<NewExternalPort>2234</NewExternalPort><NewProtocol>TCP</NewProtocol>"))
        XCTAssertTrue(body.contains("<NewInternalClient>192.168.1.20</NewInternalClient>"))
        XCTAssertTrue(body.contains("<NewPortMappingDescription>colon3o &lt;&amp;&gt;</NewPortMappingDescription>"))
        XCTAssertTrue(body.contains("<NewLeaseDuration>3600</NewLeaseDuration>"))
        XCTAssertEqual(UPnP.soapAction(serviceType: "urn:x:1", action: "AddPortMapping"), "\"urn:x:1#AddPortMapping\"")
    }

    func testSOAPFaultAndValues() {
        let fault = """
        <s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>718</errorCode>
        <errorDescription>ConflictInMappingEntry</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
        XCTAssertEqual(UPnP.errorCode(inFault: fault), 718)
        let entry = "<u:GetSpecificPortMappingEntryResponse><NewInternalClient>192.168.1.7</NewInternalClient>"
            + "<NewPortMappingDescription>colon3o</NewPortMappingDescription></u:GetSpecificPortMappingEntryResponse>"
        XCTAssertEqual(UPnP.value("NewInternalClient", in: entry), "192.168.1.7")
        XCTAssertEqual(UPnP.value("NewPortMappingDescription", in: entry), "colon3o")
        XCTAssertNil(UPnP.value("NewExternalIPAddress", in: entry))
    }

    // MARK: HTTP

    func testHTTPRequest() {
        let request = String(decoding: MiniHTTP.request(method: "POST", host: "192.168.1.1", port: 5000, path: "/ctl/IPConn",
                                                        headers: [("SOAPAction", "\"x#y\"")], body: Data("abc".utf8)), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("POST /ctl/IPConn HTTP/1.1\r\nHost: 192.168.1.1:5000\r\n"))
        XCTAssertTrue(request.contains("Connection: close\r\n"))
        XCTAssertTrue(request.contains("Content-Length: 3\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\nabc"))
    }

    func testHTTPContentLength() throws {
        let full = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nServer: x\r\n\r\nhello".utf8)
        XCTAssertNil(try MiniHTTP.parse(full.prefix(full.count - 2), connectionClosed: false))
        XCTAssertThrowsError(try MiniHTTP.parse(full.prefix(full.count - 2), connectionClosed: true))
        let response = try XCTUnwrap(try MiniHTTP.parse(full, connectionClosed: false))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.text, "hello")
        XCTAssertEqual(response.headers["server"], "x")
    }

    func testHTTPChunked() throws {
        let full = Data("HTTP/1.1 500 Internal Server Error\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n6;ext=1\r\npedia!\r\n0\r\n\r\n".utf8)
        XCTAssertNil(try MiniHTTP.parse(full.prefix(full.count - 5), connectionClosed: false))
        let response = try XCTUnwrap(try MiniHTTP.parse(full, connectionClosed: false))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(response.text, "Wikipedia!")
    }

    func testHTTPBodyUntilClose() throws {
        let data = Data("HTTP/1.0 200 OK\r\n\r\n<root/>".utf8)
        XCTAssertNil(try MiniHTTP.parse(data, connectionClosed: false))
        XCTAssertEqual(try MiniHTTP.parse(data, connectionClosed: true)?.text, "<root/>")
    }

    func testHTTPRejectsHostileInput() {
        XCTAssertThrowsError(try MiniHTTP.parse(Data("garbage\r\n\r\n".utf8), connectionClosed: false))
        XCTAssertThrowsError(try MiniHTTP.parse(Data(count: 2_000_000), connectionClosed: false))
        // A chunk size that would overflow, and one far beyond the limit.
        XCTAssertThrowsError(try MiniHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n".utf8),
                                                connectionClosed: false))
        XCTAssertThrowsError(try MiniHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffff\r\n".utf8),
                                                connectionClosed: false))
        XCTAssertThrowsError(try MiniHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n".utf8),
                                                connectionClosed: false))
        // Chunk data not followed by CRLF.
        XCTAssertThrowsError(try MiniHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX0\r\n\r\n".utf8),
                                                connectionClosed: false))
    }

    // MARK: Port test, addresses, limits

    func testPortTest() {
        XCTAssertEqual(PortTest.parse("<html>Port: 2234/tcp open</html>", port: 2234), true)
        XCTAssertEqual(PortTest.parse("2234/TCP CLOSED", port: 2234), false)
        XCTAssertEqual(PortTest.parse("2234/tcp filtered", port: 2234), false)
        XCTAssertNil(PortTest.parse("2235/tcp open", port: 2234))
        XCTAssertNil(PortTest.parse("", port: 2234))
        XCTAssertEqual(PortTest.url(port: 2234).absoluteString, "https://www.slsknet.org/porttest.php?port=2234")
    }

    func testIPv4Ranges() {
        XCTAssertTrue(IPv4.isPrivate("192.168.1.1"))
        XCTAssertTrue(IPv4.isPrivate("10.0.0.138"))
        XCTAssertTrue(IPv4.isPrivate("172.16.0.1"))
        XCTAssertTrue(IPv4.isPrivate("172.31.255.254"))
        XCTAssertFalse(IPv4.isPrivate("172.32.0.1"))
        XCTAssertFalse(IPv4.isPrivate("8.8.8.8"))
        XCTAssertFalse(IPv4.isPrivate("192.168.1"))
        XCTAssertFalse(IPv4.isPrivate("192.168.1.256"))
        XCTAssertFalse(IPv4.isPrivate("fe80::1"))
        XCTAssertTrue(IPv4.isSharedByProvider("100.64.0.1"))
        XCTAssertTrue(IPv4.isSharedByProvider("100.127.1.1"))
        XCTAssertFalse(IPv4.isSharedByProvider("100.128.0.1"))
    }

    func testConnectionLimiter() {
        var limiter = ConnectionLimiter(maxTotal: 3, maxPerAddress: 2)
        XCTAssertTrue(limiter.admit("1.1.1.1"))
        XCTAssertTrue(limiter.admit("1.1.1.1"))
        XCTAssertFalse(limiter.admit("1.1.1.1"))
        XCTAssertTrue(limiter.admit("2.2.2.2"))
        XCTAssertFalse(limiter.admit("3.3.3.3"))
        limiter.release("1.1.1.1")
        XCTAssertTrue(limiter.admit("3.3.3.3"))
        limiter.release("9.9.9.9")  // Unknown: ignored, never goes negative.
        XCTAssertEqual(limiter.total, 3)
        limiter.reset()
        XCTAssertEqual(limiter.total, 0)
        XCTAssertTrue(limiter.admit("1.1.1.1"))
    }

    // MARK: Frame and inflate limits

    func testFrameBufferLimit() {
        var buffer = FrameBuffer(limit: 16)
        var writer = ByteWriter()
        writer.u32(17)
        buffer.append(writer.data)
        XCTAssertThrowsError(try buffer.nextFrame())

        var ok = FrameBuffer(limit: 16)
        var small = ByteWriter()
        small.u32(2)
        small.raw(Data([1, 2]))
        ok.append(small.data)
        XCTAssertEqual(try ok.nextFrame(), Data([1, 2]))
    }

    func testInflateLimitStopsZipBombs() throws {
        // 2 MB of zeros packs to a few KB; with a 1 MB limit it must be refused.
        var writer = ByteWriter()
        writer.u32(9)
        writer.raw(try Zlib.compress(Data(count: 2_000_000)))
        XCTAssertThrowsError(try PeerMessage.decode(writer.data, inflateLimit: 1_000_000))
    }
}
