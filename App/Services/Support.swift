import Foundation
import Network
import Security

/// Password storage. Works with free-account sideloading (no extra entitlements needed).
enum Keychain {
    static let soulseekService = "colon3.soulseek"

    static func save(_ value: String, account: String, service: String = soulseekService) {
        delete(account: account, service: service)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String, service: String = soulseekService) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String = soulseekService) {
        guard !account.isEmpty else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum Formatting {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Names in a list without the long beginning they all share ("Artist Album (Deluxe) 03 Song"
    /// becomes "03 Song"), so rows cut off at the end can still be told apart. Keyed by the full
    /// name; empty when there's nothing worth removing.
    static func withoutSharedStart(_ names: [String]) -> [String: String] {
        let unique = Array(Set(names))
        guard unique.count >= 2, var prefix = unique.first else { return [:] }
        for name in unique.dropFirst() { prefix = name.commonPrefix(with: prefix) }
        // Back to the end of a word, so a title isn't cut in the middle of one.
        let breaks = CharacterSet(charactersIn: " -_.()[]")
        guard let cut = prefix.unicodeScalars.lastIndex(where: { breaks.contains($0) }) else { return [:] }
        prefix = String(prefix.unicodeScalars[...cut])
        guard prefix.count >= 8 else { return [:] }
        let leading = CharacterSet(charactersIn: " -_.)]")
        var short: [String: String] = [:]
        for name in unique {
            guard name.hasPrefix(prefix) else { return [:] }
            let rest = String(name.dropFirst(prefix.count))
            let trimmed = String(rest.unicodeScalars.drop(while: { leading.contains($0) }))
            // Something has to be left of every name (more than a file extension).
            guard (trimmed as NSString).deletingPathExtension.count >= 2 else { return [:] }
            short[name] = trimmed
        }
        return short
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: UInt32) -> String {
        bytes(UInt64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1 hr 12 min" / "42 minutes".
    static func longDuration(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        return total >= 60 ? "\(total / 60) hr \(total % 60) min" : "\(total) minute\(total == 1 ? "" : "s")"
    }

    /// "3.2 h" / "45 min" for listening totals.
    static func hours(_ seconds: Double) -> String {
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        return "\(Int(seconds / 60)) min"
    }

    static func sampleRate(_ hertz: Double) -> String {
        guard hertz > 0 else { return "–" }
        return kilohertz(UInt32(hertz.rounded())) + " kHz"
    }

    static func kilohertz(_ hertz: UInt32) -> String {
        let value = Double(hertz) / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// User-facing switches, stored in UserDefaults so views can bind with @AppStorage.
/// Whether the app's own background lookups (covers, lyrics, tracklists, update checks, Last.fm
/// suggestions, the port check) may use the network. On mobile data or a hotspot, or in Low Data
/// Mode, they wait until Wi-Fi unless "Use Mobile Data" is on. Downloads, searches and anything
/// started by a tap are never held back by this.
final class NetworkPolicy: @unchecked Sendable {
    static let shared = NetworkPolicy()
    static let useMobileDataKey = "network.useMobileData"

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// Counted as metered until the first path report, so nothing slips out on a cellular launch.
    private var isMetered = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.isMetered = path.isExpensive || path.isConstrained
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "colon3o.network-policy"))
    }

    var metered: Bool {
        lock.lock(); defer { lock.unlock() }
        return isMetered
    }

    /// True on Wi-Fi, or anywhere when Use Mobile Data is on.
    static var allowed: Bool {
        UserDefaults.standard.bool(forKey: useMobileDataKey) || !shared.metered
    }
}

enum AppSettings {
    static let artworkLookupKey = "artworkLookup"
    static let lyricsLookupKey = "lyricsLookup"
    static let scrobblingKey = "lastfmScrobbling"
    static let backgroundTransfersKey = "backgroundTransfers"
    static let transferActivityKey = "transferLiveActivity"
    static let showMissingKey = "showMissingSongs"
    /// Search results: fetch the rest of a folder (songs that didn't match) when one is opened.
    static let wholeFolderKey = "search.wholeFolder"
    static let musicBrainzKey = "musicBrainzLookup"
    static let autoplayKey = "autoplay"
    /// Defaults to off: autoplay may download songs it finds through Last.fm.
    static let autoplayLibraryOnlyKey = "autoplayLibraryOnly"
    /// Defaults to off: autoplay suggestions you don't have wait for you to tap Download.
    static let autoplayAutoDownloadKey = "autoplayAutoDownload"
    /// These three default to off.
    static let bitPerfectKey = "bitPerfect"
    static let seedingKey = "seedingMode"

    /// Use Apple's copy of a cover even when the song has its own (on by default).
    static let preferAppleArtworkKey = "artwork.preferApple"

    static var artworkLookupEnabled: Bool { flag(artworkLookupKey) }
    static var preferAppleArtwork: Bool { flag(artworkLookupKey) && flag(preferAppleArtworkKey) }
    static var lyricsLookupEnabled: Bool { flag(lyricsLookupKey) }
    static var scrobblingEnabled: Bool { flag(scrobblingKey) }
    static var seedingEnabled: Bool { UserDefaults.standard.bool(forKey: seedingKey) }

    /// Most switches default to on.
    static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum HTTP {
    static let userAgent = "colon3/0.4 (https://github.com/AmineWallah/colon3)"

    static func formBody(_ parameters: [String: String]) -> Data {
        // ASCII-only unreserved set; CharacterSet.alphanumerics would let accented letters through raw.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
