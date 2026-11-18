import Foundation

/// What the New project sheet collects (D-14).
enum NewProjectInput {
    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. A whole-string match, because the ICU `$` also accepts a trailing newline.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/#) != nil
    }
}

/// Where the new project goes on GitHub. The raw value is the word the launcher's `--github` takes.
enum GithubChoice: String, CaseIterable, Identifiable {
    case privateRepo = "private"
    case publicRepo = "public"
    /// The sheet starts here: nothing leaves the machine unless the user picks it.
    case skip

    var id: String { rawValue }
    /// The shown label is the raw word in title case. The raw value stays lower-case for the launcher.
    var label: String { rawValue.capitalized }
}
