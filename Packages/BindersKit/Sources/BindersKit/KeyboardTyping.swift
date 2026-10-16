import Foundation

/// The rules behind the Binders keyboard's typing: deleting while the key is held, the word being typed, and when a
/// misspelling is corrected. The keyboard asks iOS's spell checker for the guesses; these decide what to do with them.
public enum KeyboardTyping {
    /// What one step of a held delete key takes away.
    public enum DeleteUnit: Equatable, Sendable { case character, word }

    /// How long after touching the delete key it starts repeating.
    public static let repeatDelay: TimeInterval = 0.45
    /// Held this long, it deletes whole words, as the system keyboard does.
    public static let wordsAfter: TimeInterval = 1.6

    /// The next step of a held delete key, `held` seconds after it was touched: what it deletes, and how long until the
    /// step after. Characters come faster the longer it's held, then whole words.
    public static func deleteStep(held: TimeInterval) -> (unit: DeleteUnit, next: TimeInterval) {
        guard held < wordsAfter else { return (.word, 0.18) }
        let progress = min(1, max(0, (held - repeatDelay) / (wordsAfter - repeatDelay)))
        return (.character, 0.1 - 0.05 * progress)
    }

    /// How many characters deleting a word takes from the end of `before`: the spaces after the word and the word, or a
    /// run of punctuation. At least one, unless there's nothing.
    public static func wordDeletionCount(before: String) -> Int {
        var count = 0
        var index = before.endIndex
        while index > before.startIndex, before[before.index(before: index)] == " " || before[before.index(before: index)] == "\t" {
            index = before.index(before: index)
            count += 1
        }
        guard index > before.startIndex else { return count }
        let last = before[before.index(before: index)]
        if last.isNewline { return count == 0 ? 1 : count }
        let inWord = isWordCharacter(last)
        while index > before.startIndex {
            let character = before[before.index(before: index)]
            guard !character.isWhitespace, isWordCharacter(character) == inWord else { break }
            index = before.index(before: index)
            count += 1
        }
        return max(count, 1)
    }

    /// The word being typed: the letters right before the cursor, apostrophes inside it included ("don't"). Empty when the
    /// cursor isn't after a word.
    public static func currentWord(before: String) -> String {
        var index = before.endIndex
        while index > before.startIndex, isWordCharacter(before[before.index(before: index)]) {
            index = before.index(before: index)
        }
        var word = before[index...]
        while let first = word.first, first == "'" || first == "’" { word = word.dropFirst() }
        return String(word)
    }

    /// Whether `word` should be checked for spelling at all: letters only, two or more, and not shouting an acronym.
    public static func isCheckable(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        return !(letters.count > 1 && letters.allSatisfy(\.isUppercase))
    }

    /// Whether `guess` is near enough to what was typed to put in its place without asking: one slip in a short word,
    /// two in a longer one. Never a name for a word typed in lower case ("revi" isn't "Levi").
    public static func isSafeCorrection(of typed: String, to guess: String) -> Bool {
        if let first = guess.first, first.isUppercase, typed.first?.isLowercase == true { return false }
        let typed = typed.lowercased(), guess = guess.lowercased()
        guard typed != guess, !guess.isEmpty else { return false }
        let allowed = typed.count <= 4 ? 1 : 2
        return editDistance(typed, guess) <= allowed
    }

    /// `guess` written the way `typed` was: capitalised, or in capitals.
    public static func matchingCase(_ guess: String, like typed: String) -> String {
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return guess.uppercased() }
        if let first = letters.first, first.isUppercase, let head = guess.first { return head.uppercased() + guess.dropFirst() }
        return guess
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    /// Edits (a letter added, dropped, changed, or two swapped) between two words.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1) }
            }
        }
        return table[a.count][b.count]
    }
}
