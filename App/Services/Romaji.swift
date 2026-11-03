import Foundation

/// Japanese lyrics in Latin letters, made on the phone. The system's Japanese tokenizer splits the
/// line into words and gives each word's reading (kanji included); the reading is turned back into
/// kana and spelled out here with Hepburn-style rules, the way Apple Music shows lyrics: っ doubles
/// the next consonant (itte), long vowels are written as spelled (moumokuteki), particles read as
/// spoken (wa, e, wo). Readings of unusual kanji can be off; nothing goes over the network.
enum Romaji {
    /// One romaji word and the stretch of the original line (in UTF-16 units) it reads.
    struct Piece: Hashable {
        let text: String
        let location: Int
        let length: Int
    }

    /// nil when the text has no Japanese in it.
    static func of(_ text: String) -> String? {
        pieces(text).map { $0.map(\.text).joined(separator: " ") }
    }

    /// Romaji written by people for a line, tied to the line's characters so it can still light up
    /// in time: word for word onto the words found here when there are as many, otherwise spread
    /// over the line in proportion to each word's length.
    static func pieces(written: String, for text: String) -> [Piece]? {
        let words = written.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        if let found = pieces(text), found.count == words.count {
            return zip(found, words).map { Piece(text: $1, location: $0.location, length: $0.length) }
        }
        let total = (text as NSString).length
        let weights = words.map { Double(max($0.count, 1)) }
        let sum = weights.reduce(0, +)
        var done = 0.0
        return zip(words, weights).map { word, weight in
            let start = Int((done / sum * Double(total)).rounded())
            done += weight
            let end = Int((done / sum * Double(total)).rounded())
            return Piece(text: word, location: start, length: max(end - start, 1))
        }
    }

    /// The line's romaji, word by word, each tied to the characters it reads, so it can be lit in
    /// time with them. nil when the text has no Japanese in it.
    static func pieces(_ text: String) -> [Piece]? {
        guard containsJapanese(text) else { return nil }
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWord,
                                                      Locale(identifier: "ja") as CFLocale) else { return nil }

        // Each word's reading in hiragana, and whether it stands on its own in romaji.
        var words: [(kana: String, attaches: Bool, range: CFRange)] = []
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
            words.append((readings[token] ?? kana, attaches, tokenRange))
            previousToken = token
        }

        var groups: [(kana: String, start: Int, end: Int)] = []
        for word in words {
            let end = word.range.location + word.range.length
            if word.attaches, let last = groups.popLast() {
                groups.append((last.kana + word.kana, last.start, end))
            } else {
                groups.append((word.kana, word.range.location, end))
            }
        }
        let result = groups.compactMap { group -> Piece? in
            let text = particles[group.kana] ?? spell(group.kana)
            return text.isEmpty ? nil : Piece(text: text, location: group.start, length: group.end - group.start)
        }
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

    /// Words whose usual reading in songs differs from the dictionary's first choice. Songs use
    /// the everyday reading where the dictionary often picks another: 身体 is sung "karada", not
    /// "shintai"; a single 君 is "kimi" (the reader took it for the "-kun" after a name), 空 "sora",
    /// 月 "tsuki", 心 "kokoro". Only whole words are replaced, so compounds (月曜, 空港) keep theirs.
    private static let readings: [String: String] = [
        // People and pronouns.
        "私": "わたし", "僕": "ぼく", "君": "きみ", "貴方": "あなた", "貴女": "あなた", "俺": "おれ", "誰": "だれ",
        "僕ら": "ぼくら", "君ら": "きみら", "僕達": "ぼくたち", "君達": "きみたち", "私達": "わたしたち", "人": "ひと",
        "一人": "ひとり", "二人": "ふたり", "大人": "おとな", "皆": "みんな", "自分": "じぶん",
        // Time.
        "今日": "きょう", "明日": "あした", "昨日": "きのう", "今": "いま", "日": "ひ", "日々": "ひび", "時": "とき",
        "朝": "あさ", "夜": "よる", "夕": "ゆう", "昔": "むかし", "未来": "みらい", "永遠": "えいえん", "季節": "きせつ",
        // Places and things.
        "空": "そら", "月": "つき", "星": "ほし", "海": "うみ", "風": "かぜ", "雨": "あめ", "雪": "ゆき", "花": "はな",
        "光": "ひかり", "影": "かげ", "色": "いろ", "道": "みち", "街": "まち", "町": "まち", "世界": "せかい", "景色": "けしき",
        "故郷": "ふるさと", "此処": "ここ", "其処": "そこ", "何処": "どこ", "場所": "ばしょ", "窓": "まど", "扉": "とびら",
        // The body and the heart.
        "身体": "からだ", "体": "からだ", "心": "こころ", "胸": "むね", "手": "て", "目": "め", "眼": "め", "瞳": "ひとみ",
        "声": "こえ", "涙": "なみだ", "夢": "ゆめ", "愛": "あい", "恋": "こい", "命": "いのち", "息": "いき", "笑顔": "えがお",
        "想い": "おもい", "思い": "おもい", "思い出": "おもいで", "言葉": "ことば", "唄": "うた", "詩": "うた", "歌": "うた",
        "音": "おと", "名前": "なまえ",
        // Positions and the like, read as words rather than in compounds.
        "上": "うえ", "下": "した", "前": "まえ", "後": "あと", "側": "そば", "隣": "となり", "先": "さき",
        "間": "あいだ", "外": "そと", "奥": "おく", "端": "はし", "何": "なに", "事": "こと", "物": "もの", "所": "ところ",
        "全て": "すべて", "一つ": "ひとつ", "二つ": "ふたつ", "一緒": "いっしょ", "大切": "たいせつ", "本当": "ほんとう",
        "上手": "うま", "下手": "へた",
    ]

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
