import Foundation

/// Japanese lyrics in Latin letters, made on the phone. The system's Japanese tokenizer splits the
/// line into words and gives each word's reading (kanji included); the reading is turned back into
/// kana and spelled out here with Hepburn-style rules, the way Apple Music shows lyrics: っ doubles
/// the next consonant (itte), long vowels are written as spelled (moumokuteki), particles read as
/// spoken (wa, e, wo). Readings of unusual kanji can be off; nothing goes over the network.
enum Romaji {
    /// nil when the text has no Japanese in it.
    static func of(_ text: String) -> String? {
        guard containsJapanese(text) else { return nil }
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWord,
                                                      Locale(identifier: "ja") as CFLocale) else { return nil }

        // Each word's reading in hiragana, and whether it stands on its own in romaji.
        var words: [(kana: String, attaches: Bool)] = []
        var previousToken: String?
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (CFStringCreateWithSubstring(nil, string, tokenRange) as String?) ?? ""
            guard !token.isEmpty else { continue }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            let kana = reading(of: token, latin: latin)
            // Endings written in hiragana (て, てる, ます…) belong to the word before them, as in
            // Apple Music's "kidzuiteru"; particles and interjections stand on their own. So does
            // anything after a word ending in っ (言っ + て → itte).
            let previousEndsInSokuon = words.last?.kana.hasSuffix("っ") ?? false
            // Nothing joins onto a particle (君が + いった is "kimi ga itta", not "gaitta").
            let previousStandsAlone = previousToken.map { standalone.contains($0) } ?? true
            let attaches: Bool
            if words.isEmpty {
                attaches = false
            } else if suffixes.contains(token) || token == "ん" {
                // 盲目 + 的 → moumokuteki; な + ん → nan.
                attaches = true
            } else if startsWord.contains(token) {
                attaches = false
            } else {
                attaches = !previousStandsAlone && (previousEndsInSokuon || (isHiragana(token) && !standalone.contains(token)))
            }
            words.append((readings[token] ?? kana, attaches))
            previousToken = token
        }

        var groups: [String] = []
        for word in words {
            if word.attaches, let last = groups.popLast() {
                groups.append(last + word.kana)
            } else {
                groups.append(word.kana)
            }
        }
        let result = groups.map { group in
            particles[group] ?? spell(group)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    /// The word in hiragana: kana as written (katakana turned into hiragana), and words with kanji
    /// from the tokenizer's reading.
    private static func reading(of token: String, latin: String?) -> String {
        if isKana(token) { return toHiragana(token) }
        // The tokenizer marks long vowels and っ with accents and "~" (mōmoku, i~): spell long
        // vowels out and drop the marks before turning the reading back into kana.
        let cleaned = latin.map { reading in
            // "~tsu" is how the reading marks a small っ (いっ → "i~tsu"); the っ is kept from the word itself.
            var text = reading.lowercased().replacingOccurrences(of: "~tsu", with: "")
            for (long, plain) in [("ō", "ou"), ("ū", "uu"), ("ā", "aa"), ("ē", "ee"), ("ī", "ii"),
                                  ("ô", "ou"), ("û", "uu"), ("â", "aa"), ("ê", "ee"), ("î", "ii")] {
                text = text.replacingOccurrences(of: long, with: plain)
            }
            return String(text.filter { $0.isLetter })
        }
        if let cleaned, !cleaned.isEmpty, let kana = cleaned.applyingTransform(.latinToHiragana, reverse: false), isKana(kana) {
            // Keep any kana the word was written with at its end (言っ: the reading may drop the っ).
            if let lastKana = token.last.map(String.init), isKana(lastKana), !kana.hasSuffix(toHiragana(lastKana)) {
                return kana + toHiragana(lastKana)
            }
            return kana
        }
        return token
    }

    /// Words whose usual reading in songs differs from the dictionary's first choice.
    private static let readings = ["私": "わたし", "僕": "ぼく", "貴方": "あなた", "今日": "きょう", "明日": "あした",
                                   "一人": "ひとり", "二人": "ふたり", "大人": "おとな", "何": "なに", "日": "ひ"]

    /// Kanji and kana suffixes written together with the word before them.
    private static let suffixes: Set<String> = ["的", "さん", "ちゃん", "くん", "様", "達", "たち", "性", "感"]

    /// Kana words that start a new word but can take endings themselves (だっ + た → datta).
    private static let startsWord: Set<String> = ["だっ", "じゃ", "です", "でし"]

    /// Particles read differently from how they're written.
    private static let particles = ["は": "wa", "へ": "e", "を": "wo"]

    /// Hiragana words that stand apart in romaji rather than joining the word before them.
    private static let standalone: Set<String> = ["は", "が", "を", "に", "で", "と", "の", "へ", "も", "や", "か",
                                                  "ね", "よ", "な", "わ", "ぞ", "さ", "から", "まで", "より", "けど", "こと", "もの", "とき", "ため", "よう",
                                                  "ほら", "あの", "その", "この", "あまり"]

    // MARK: Spelling

    private static let syllables: [Character: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "wi", "ゑ": "we", "を": "wo", "ん": "n",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "だ": "da", "ぢ": "ji", "づ": "dzu", "で": "de", "ど": "do",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ゔ": "vu",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ゎ": "wa",
    ]

    private static let smallY: [Character: String] = ["ゃ": "a", "ゅ": "u", "ょ": "o"]
    private static let smallVowel: [Character: String] = ["ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o"]

    /// Hiragana spelled out in Latin letters.
    static func spell(_ kana: String) -> String {
        let chars = Array(kana)
        var out = ""
        var doubleNext = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "っ" {
                doubleNext = true
                index += 1
                continue
            }
            if char == "ー" {
                if let vowel = out.last(where: { "aeiou".contains($0) }) { out.append(vowel) }
                index += 1
                continue
            }
            guard var syllable = syllables[char] else {
                out.append(char)
                index += 1
                continue
            }
            // きゃ → kya, しゃ → sha, ちゃ → cha, じゃ → ja; ふぁ → fa, てぃ → ti.
            if index + 1 < chars.count {
                let next = chars[index + 1]
                if let vowel = smallY[next], syllable.hasSuffix("i"), syllable.count > 1 {
                    let stem = String(syllable.dropLast())
                    syllable = ["sh", "ch", "j"].contains(stem) ? stem + vowel : stem + "y" + vowel
                    index += 1
                } else if let vowel = smallVowel[next], syllable.count > 1 {
                    syllable = String(syllable.dropLast()) + vowel
                    index += 1
                }
            }
            if doubleNext {
                syllable = (syllable.hasPrefix("ch") ? "t" : String(syllable.prefix(1))) + syllable
                doubleNext = false
            }
            out += syllable
            index += 1
        }
        return out
    }

    // MARK: Character checks

    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func isHiragana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }

    private static func isKana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
    }

    private static func toHiragana(_ text: String) -> String {
        text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
    }
}
