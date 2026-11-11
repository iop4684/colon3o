import XCTest
@testable import SoulseekKit

/// The port test and the limits on incoming connections.
final class PortMappingTests: XCTestCase {
    // MARK: Port test, limits

    func testPortTest() {
        XCTAssertEqual(PortTest.parse("<html>Port: 2234/tcp open</html>", port: 2234), true)
        XCTAssertEqual(PortTest.parse("2234/TCP CLOSED", port: 2234), false)
        XCTAssertEqual(PortTest.parse("2234/tcp filtered", port: 2234), false)
        XCTAssertNil(PortTest.parse("2235/tcp open", port: 2234))
        XCTAssertNil(PortTest.parse("12234/tcp open", port: 2234))
        XCTAssertEqual(PortTest.parse("12234/tcp open, 2234/tcp closed", port: 2234), false)
        XCTAssertNil(PortTest.parse("", port: 2234))
        XCTAssertEqual(PortTest.url(port: 2234).absoluteString, "https://www.slsknet.org/porttest.php?port=2234")
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
