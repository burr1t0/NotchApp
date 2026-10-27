import Foundation

/// Turns code identifiers (`addElement`, `AddElement`, `add_element`,
/// `test_userCanLogin`, `MAX_RETRY_COUNT`) into plain spaced phrases so the
/// translator sees "add element" instead of one unknown word. Only the text
/// sent to the translator is rewritten; the input field is left as typed.
///
/// Ordinary words are never touched: a run of letters is only split when it
/// actually looks like an identifier (contains `_` or a lower→UPPER step).
enum IdentifierSplitter {
    private static let wordRun = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+")

    static func expand(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in wordRun.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += split(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func split(_ run: String) -> String {
        let chars = Array(run)
        let hasUnderscore = chars.contains("_")
        let hasCamel = zip(chars, chars.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        guard hasUnderscore || hasCamel else { return run }

        // Brand-style words (iPhone, eBay): one lowercase letter before a
        // capitalised word, with no further camel boundary, stay as they are.
        if !hasUnderscore, chars.count > 1, chars[0].isLowercase, chars[1].isUppercase {
            let tail = Array(chars.dropFirst())
            if !zip(tail, tail.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) {
                return run
            }
        }

        let isShouting = !chars.contains { $0.isLowercase }
        var words: [String] = []
        for part in run.split(separator: "_") {
            words.append(contentsOf: camelWords(Array(part)))
        }
        return words.map { word in
            // Keep acronyms (HTTP, API) inside camelCase; lowercase everything
            // else, and everything in SHOUTING_SNAKE constants.
            let isAcronym = word.count > 1 && !word.contains { $0.isLowercase } && !word.contains { $0.isNumber }
            return (isAcronym && !isShouting) ? word : word.lowercased()
        }.joined(separator: " ")
    }

    /// Splits at lower→Upper and at the end of an acronym (`HTTPServer` →
    /// `HTTP`, `Server`), and between letters and digits.
    private static func camelWords(_ chars: [Character]) -> [String] {
        var words: [String] = []
        var current = ""
        for (index, char) in chars.enumerated() {
            if let previous = current.last {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let lowerToUpper = previous.isLowercase && char.isUppercase
                let acronymEnd = previous.isUppercase && char.isUppercase && (next?.isLowercase ?? false)
                let letterDigit = previous.isLetter != char.isLetter && (previous.isNumber || char.isNumber)
                if lowerToUpper || acronymEnd || letterDigit {
                    words.append(current)
                    current = ""
                }
            }
            current.append(char)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
