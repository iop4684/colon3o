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
        // っ at the end of a word doubles the next consonant (言って → itte, not itsute).
        var doubleNext = false
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (CFStringCreateWithSubstring(nil, string, tokenRange) as String?) ?? ""
            var piece: String
            if let particle = particles[token] {
                piece = particle
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                      !latin.isEmpty {
                piece = plainVowels(latin)
            } else {
                piece = token
            }

            let endsInSokuon = token.hasSuffix("っ") || token.hasSuffix("ッ")
            if endsInSokuon {
                for tail in ["xtsu", "ltsu", "xtu", "ltu", "tsu"] where piece.hasSuffix(tail) {
                    piece.removeLast(tail.count)
                    break
                }
            }
            if doubleNext, let first = piece.first, first.isLetter, !"aeiou".contains(first) {
                piece = String(first) + piece
            }

            // Endings written in kana (て, てる, ます…) belong to the word before them, as in
            // Apple Music's "kidzuiteru"; particles stand on their own.
            let attaches = !words.isEmpty && (doubleNext || (isHiragana(token) && !standalone.contains(token)))
            if attaches {
                words[words.count - 1] += piece
            } else if !piece.isEmpty {
                words.append(piece)
            }
            doubleNext = endsInSokuon
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    /// Particles read differently from how they're written.
    private static let particles = ["は": "wa", "へ": "e", "を": "wo"]

    /// Kana words that stand apart in romaji (particles and interjections), rather than joining
    /// the word before them.
    private static let standalone: Set<String> = ["は", "が", "を", "に", "で", "と", "の", "へ", "も", "や", "か",
                                                  "ね", "よ", "な", "わ", "ぞ", "さ", "から", "まで", "より", "けど", "ほら"]

    private static func isHiragana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }

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
