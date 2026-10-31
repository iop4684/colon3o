import Foundation

/// Japanese lyrics in Latin letters, made on the phone with the system's Japanese reading of each
/// word (kanji included). Readings of unusual kanji can be off; there's no network involved.
enum Romaji {
    /// nil when the text has no Japanese in it.
    static func of(_ text: String) -> String? {
        guard containsJapanese(text) else { return nil }
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWord,
                                                      Locale(identifier: "ja") as CFLocale) else { return nil }
        var words: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (CFStringCreateWithSubstring(nil, string, tokenRange) as String?) ?? ""
            if let particle = particles[token] {
                words.append(particle)
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                      !latin.isEmpty {
                words.append(plainVowels(latin))
            } else if !token.isEmpty {
                words.append(token)
            }
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    /// Particles read differently from how they're written.
    private static let particles = ["は": "wa", "へ": "e", "を": "wo"]

    /// Long vowels spelled out, as Apple Music shows them ("moumokuteki", not "mōmokuteki").
    private static func plainVowels(_ text: String) -> String {
        var result = text.lowercased()
        for (long, plain) in [("ō", "ou"), ("ū", "uu"), ("ā", "aa"), ("ē", "ee"), ("ī", "ii"),
                              ("ô", "ou"), ("û", "uu"), ("â", "aa"), ("ê", "ee"), ("î", "ii")] {
            result = result.replacingOccurrences(of: long, with: plain)
        }
        return result
    }

    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
