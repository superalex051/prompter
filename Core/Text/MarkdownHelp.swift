import Foundation

/// What Markdown formatting does, in plain words, for the settings footers and the How to use screens on both apps.
/// Shown verbatim (SwiftUI would otherwise render the `**` it explains).
enum MarkdownHelp {
    /// Settings footer, Markdown formatting on.
    static let summary = "Markdown formatting: **bold** shows in amber, # starts a heading, - starts a bullet, "
        + "and the symbols don't show on the teleprompter."
    /// Settings footer, Markdown formatting off.
    static let offSummary = "Markdown formatting is off, so symbols like ** and # show as you typed them."

    /// The How to use rows: what to type, what it does.
    static let rows: [(syntax: String, detail: String)] = [
        ("**bold** or __bold__", "Shows in amber, to stress a word."),
        ("*italic* or _italic_", "Shows in italics."),
        ("~~strike~~", "Struck through and dimmed."),
        ("# Heading", "A line starting with # (or ## or ###) is a section title in amber. It is not read or counted."),
        ("- item", "A line starting with -, * or + is a bullet. 1. keeps its number."),
        ("> quote", "Shows as plain text, without the >."),
        ("---", "A line of three dashes is a thin dividing line."),
        ("[text](link)", "Shows only the text. `code` shows as plain text, and \\* shows a real *."),
    ]

    /// The How to use section footer.
    static let footer = "Turn Markdown formatting off in Settings → Text to show every symbol as written. "
        + "Notes (//) and pauses ([pause 2]) work the same either way."
}
