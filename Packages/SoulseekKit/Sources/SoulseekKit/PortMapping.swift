import Foundation

// Checking the listening port from outside, and limiting who may connect. No networking here, so
// all of it is covered by the Linux tests; the app does the actual talking.

// MARK: - Port test

public enum PortTest {
    /// slsknet.org's own checker, as used by Nicotine+. It connects back to whoever asks.
    public static func url(port: UInt16) -> URL {
        URL(string: "https://www.slsknet.org/porttest.php?port=\(port)")!
    }

    /// true: open, false: closed, nil: an answer we don't understand.
    public static func parse(_ body: String, port: UInt16) -> Bool? {
        let text = body.lowercased()
        /// "2234/tcp open", but not as the end of "12234/tcp open".
        func says(_ phrase: String) -> Bool {
            var searchStart = text.startIndex
            while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
                if range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isNumber { return true }
                searchStart = range.upperBound
            }
            return false
        }
        if says("\(port)/tcp open") { return true }
        if says("\(port)/tcp closed") || says("\(port)/tcp filtered") { return false }
        return nil
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
