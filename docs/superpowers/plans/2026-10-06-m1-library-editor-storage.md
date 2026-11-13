# M1: Library + Editor + Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the owner can create, edit, delete (with undo), duplicate, rename, paste and import (`.txt`/`.rtf`) scripts, see word count and
read time, and the first launch shows a sample script, all persisted on device.

**Architecture:** Value-type models (`Script`, `PrompterSettings`) plus pure helpers (`ReadingStats`, `ScriptImporter`, `TimeFormatting`)
hold all logic and are unit tested. Two `@MainActor @Observable` stores (`ScriptStore` = JSON file in Application Support,
`SettingsStore` = JSON blob in `UserDefaults`) are injected into SwiftUI with `.environment(...)`. Views are thin: `LibraryView`
(NavigationStack root) pushes `EditorView(scriptID:onPrompt:)` and presents a placeholder prompter (M2 replaces it).

**Tech Stack:** SwiftUI, Observation, Foundation, UIKit (RTF via `NSAttributedString`, `UIPasteboard`), UniformTypeIdentifiers,
Swift Testing. XcodeGen project. No third-party code.

**Spec:** `docs/superpowers/specs/2026-10-06-prompter-design.md` (§3.1 Library, §3.2 Editor, §3.4 Settings, §6 Core types, §7 M1).

## Global Constraints
- iOS 26.0+, Swift 6 language mode (strict concurrency), Apple frameworks only, no SPM/CocoaPods.
- Never hand-edit `Prompter.xcodeproj`; add files under `Prompter/`, `Shared/`, `PrompterTests/` and run `xcodegen generate` (the scripts do it).
- `Shared/` compiles into BOTH the iOS app and the watchOS app: code there must build for watchOS 10 (no UIKit).
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), `@testable import Prompter`. Tests run in parallel:
  every test uses its own temp directory / `UserDefaults(suiteName: "test-\(UUID())")`.
- `@MainActor` on stores and on tests that touch them.
- Persistence: scripts = JSON in Application Support (atomic writes); settings = `UserDefaults`.
- Copy is plain: "New script", "Paste as new script", "Import file…", "Prompt", "Delete", "Undo", "Duplicate", "Rename".
- Build: `scripts/build.sh` (generic iOS Simulator, also builds the embedded watch app). Tests: `scripts/test.sh`.

## Review Focus
1. **Corrupt or unreadable `scripts.json` at launch** → the app still opens, the bad file is moved aside (never overwritten), and
   a one-line error is available to show. *Test:* `ScriptStoreTests.corruptFileIsMovedAsideAndNotOverwritten`.
2. **Non-UTF-8 text files** (Windows-1252 or UTF-16 from Word "Save As Plain Text"), CRLF line endings, BOM → text imports
   correctly with no `\r`, BOM or mojibake. *Tests:* `ScriptImporterTests.decodesWindows1252`, `.decodesUTF16WithBOM`, `.normalizesCRLFAndBOM`.
3. **Blank input** (empty clipboard, whitespace-only file, RTF with only an image) → no empty script is created; the caller
   gets `nil` / `.empty`. *Tests:* `ScriptStoreTests.createFromBlankTextReturnsNil`, `ScriptImporterTests.whitespaceOnlyFileIsEmpty`.
4. **Junk and resurrection:** a new script left blank is removed when the editor closes; deleting the sample script does not
   bring it back on next launch (seed only when the file does not exist). *Tests:* `ScriptStoreTests.deleteIfBlankRemovesOnlyBlankScripts`,
   `.sampleIsSeededOnlyWhenNoFileExists`.
5. **Settings from an older/newer build** (missing keys, unknown keys, out-of-range numbers) → defaults fill in, values are clamped,
   nothing resets. *Tests:* `PrompterSettingsTests.decodesEmptyObjectToDefaults`, `.ignoresUnknownKeys`, `.clampsOutOfRangeValues`.

---

## File map

| File | Owner task | Responsibility |
|---|---|---|
| `Shared/TimeFormatting.swift` | 1 | `m:ss` / `h:mm:ss` clock strings (phone + watch) |
| `Prompter/Models/Script.swift` | 1 | `Script` value type |
| `Prompter/Models/ReadingStats.swift` | 1 | word count, read time |
| `Prompter/Models/PrompterSettings.swift` | 1 | all prompter/app settings, tolerant Codable, clamping |
| `Prompter/Models/SampleScript.swift` | 1 | first-launch sample script explaining the controls |
| `Prompter/Models/DemoData.swift` | 1 | demo scripts for screenshots (`-demoData`) |
| `Prompter/Services/ScriptImporter.swift` | 1 | `.txt`/`.rtf` decoding, normalisation, titles |
| `Prompter/Services/ScriptStore.swift` | 1 | @Observable store, JSON persistence, CRUD, import, undo |
| `Prompter/Services/SettingsStore.swift` | 1 | @Observable `UserDefaults` persistence of `PrompterSettings` |
| `Prompter/App/LaunchOptions.swift` | 1 | parse `-route <name>` and `-demoData` launch arguments |
| `Prompter/Features/Editor/EditorView.swift` | 1 creates stub, 3 implements | editor screen |
| `PrompterTests/*Tests.swift` | 1 | unit tests |
| `Prompter/App/PrompterApp.swift` | 2 | create stores, apply launch options, dark appearance |
| `Prompter/Features/Library/LibraryView.swift` | 2 | list, toolbar actions, delete-undo banner, routing |
| `Prompter/Features/Library/ScriptRow.swift` | 2 | one row |
| `Prompter/Features/Prompter/PrompterPlaceholderView.swift` | 2 | full-screen placeholder until M2 |
| `Prompter/Resources/Assets.xcassets/AccentColor.colorset` | 2 | amber accent |

Tasks 2 and 3 run in parallel (separate git worktrees, separate files). Task 4 merges them; Task 5 reviews and fixes.

---

### Task 1: Core models, stores, importer, launch options (+ tests)  · model: Opus

**Files:** everything owned by "1" in the file map. Delete `Prompter/Services/.gitkeep` once the folder has a real file.

**Interfaces (produce exactly these; later tasks compile against them):**

```swift
// Shared/TimeFormatting.swift  (Foundation only; compiled for iOS and watchOS)
enum TimeFormatting {
    /// "0:00"-style clock. Rounds to the nearest second. Negative, NaN or infinite → "0:00". ≥ 1 h → "h:mm:ss".
    static func clock(_ seconds: Double) -> String
}

// Prompter/Models/Script.swift
struct Script: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now, updatedAt: Date? = nil) // updatedAt defaults to createdAt
    var displayTitle: String { get }   // trimmed title, or "Untitled" when blank
    var firstLine: String { get }      // first non-blank line of body, trimmed ("" if none)
    var isBlank: Bool { get }          // title and body both whitespace-only
}

// Prompter/Models/ReadingStats.swift
struct ReadingStats: Equatable, Sendable {
    let wordCount: Int
    init(text: String)
    /// A word = a whitespace-separated token containing at least one letter or digit ("—", "-", "•" don't count).
    static func wordCount(of text: String) -> Int
    /// wordCount / wpm * 60. wpm <= 0 or non-finite → 0.
    func readingSeconds(atWPM wpm: Double) -> Double
}

// Prompter/Models/PrompterSettings.swift
struct PrompterSettings: Codable, Equatable, Sendable {
    enum Rotation: Int, Codable, CaseIterable, Sendable { case none = 0, quarter = 90, half = 180, threeQuarters = 270 }
    enum Weight: String, Codable, CaseIterable, Sendable { case regular, medium, semibold, bold, heavy, black }
    enum Scheme: String, Codable, CaseIterable, Sendable { case whiteOnBlack, yellowOnBlack, blackOnWhite }
    enum ScrollMode: String, Codable, CaseIterable, Sendable { case speed, finishIn, wpm }

    // Geometry
    var mirrorHorizontal: Bool = true
    var flipVertical: Bool = false
    var rotation: Rotation = .none
    // Typography (ghost-friendly defaults)
    var fontSize: Double = 72            // points on iPhone
    var fontWeight: Weight = .heavy
    var lineSpacing: Double = 1.6        // multiple of the font's line height
    var sideMargin: Double = 0.06        // fraction of the canvas width, each side
    var scheme: Scheme = .whiteOnBlack
    // Reading line
    var readingLinePosition: Double = 1.0 / 3.0   // fraction of canvas height from the top
    var dimmedOpacity: Double = 0.35              // opacity of text above the reading line
    // Countdown
    var countdownSeconds: Int = 5        // one of countdownOptions
    var countdownBeep: Bool = true
    // Scrolling
    var scrollMode: ScrollMode = .wpm
    var speedLevel: Double = 3.0         // 1.0...10.0, step 0.1
    var finishInSeconds: Double = 300
    var wordsPerMinute: Double = 140

    static let countdownOptions: [Int] = [0, 3, 5, 10, 15]
    static let fontSizeRange: ClosedRange<Double> = 24...200
    static let lineSpacingRange: ClosedRange<Double> = 1.0...3.0
    static let sideMarginRange: ClosedRange<Double> = 0.0...0.3
    static let readingLineRange: ClosedRange<Double> = 0.1...0.9
    static let dimmedOpacityRange: ClosedRange<Double> = 0.0...1.0
    static let speedLevelRange: ClosedRange<Double> = 1.0...10.0
    static let finishInRange: ClosedRange<Double> = 10...7200
    static let wpmRange: ClosedRange<Double> = 60...300

    init()                                  // all defaults
    init(from decoder: Decoder) throws      // decodeIfPresent for EVERY key (missing → default), then clamped
    func clamped() -> PrompterSettings      // clamp numbers to ranges; countdownSeconds → nearest option; NaN → default
}

// Prompter/Models/SampleScript.swift
enum SampleScript {
    static let id: UUID                      // fixed UUID, e.g. UUID(uuidString: "5A3F1E2C-0000-4000-8000-000000000001")!
    static let title = "Welcome to Prompter"
    static let body: String                  // ~200 plain words: tap to pause, drag to scrub, pinch for size, long-press for
                                             // settings, keyboard/clicker keys, the watch remote, mirror for the glass rig.
    static func make(now: Date) -> Script
}

// Prompter/Models/DemoData.swift
enum DemoData {
    /// SampleScript plus 3 realistic scripts (e.g. "YouTube intro: rig tour", "Client testimonial ask", "Product review: a7C")
    /// with updatedAt spread over the last few days, for screenshots.
    static func scripts(now: Date) -> [Script]
}

// Prompter/Services/ScriptImporter.swift  (import UIKit for NSAttributedString RTF)
struct ImportedScript: Equatable, Sendable { var title: String; var body: String }
enum ScriptImportError: Error, Equatable, Sendable {
    case unsupportedType(String)   // file extension
    case unreadable
    case empty
    var message: String { get }    // "Prompter can import .txt and .rtf files." / "The file couldn't be read." / "The file has no text."
}
enum ScriptImporter {
    /// .rtf → NSAttributedString(.rtf).string (drop U+FFFC attachments); any type conforming to public.plain-text → decodeText.
    /// Title = file name without extension (trimmed); falls back to title(fromFirstLineOf:) if that is blank.
    static func importFile(at url: URL) throws(ScriptImportError) -> ImportedScript
    /// For paste: title from the first non-blank line; body = the whole normalised text (first line kept).
    static func fromPlainText(_ text: String) throws(ScriptImportError) -> ImportedScript
    /// UTF-8 (with or without BOM) → UTF-16 with BOM → Windows-1252 → Mac Roman. nil if nothing decodes.
    static func decodeText(_ data: Data) -> String?
    /// Strip BOM; CRLF/CR/U+2028/U+2029 → "\n"; NBSP → space; trim trailing spaces on each line; collapse 3+ consecutive
    /// newlines to 2; trim leading/trailing blank lines.
    static func normalize(_ text: String) -> String
    /// First non-blank line, trimmed, cut at a word boundary to ≤ maxLength chars with "…" appended when cut. "" if none.
    static func title(fromFirstLineOf text: String, maxLength: Int = 60) -> String
}

// Prompter/Services/ScriptStore.swift
struct ImportFailure: Equatable, Sendable { var filename: String; var message: String }
struct ImportSummary: Sendable { var imported: [Script]; var failures: [ImportFailure] }

@MainActor @Observable
final class ScriptStore {
    private(set) var scripts: [Script]        // always sorted: updatedAt desc, then createdAt desc, then id
    private(set) var lastError: String?       // user-facing; set on load/save failure; a successful save clears a save failure
    let fileURL: URL                          // <directory>/scripts.json
    static var defaultDirectory: URL { get }  // Application Support/Prompter (created on demand)

    /// Loads synchronously. No file → scripts = initialScripts(now) and save. Undecodable file → move it to
    /// "scripts-corrupt-<unix time>.json" in the same directory, scripts = [], lastError = "Couldn't read your scripts. A copy was kept as <name>."
    init(directory: URL = ScriptStore.defaultDirectory,
         now: @escaping @Sendable () -> Date = { Date() },
         initialScripts: @Sendable (Date) -> [Script] = { [SampleScript.make(now: $0)] })

    func script(id: Script.ID) -> Script?
    /// The UI calls this when it dismisses the lastError alert, so the next failure is reported again. (Added in review.)
    func clearError()
    @discardableResult func create(title: String = "", body: String = "") -> Script
    /// nil when the text has no words. Uses ScriptImporter.fromPlainText.
    @discardableResult func createFromText(_ text: String) -> Script?
    /// Starts/stops security-scoped access per URL. One script per readable file; failures carry the file name + message.
    func importFiles(at urls: [URL]) -> ImportSummary
    /// No-op (no updatedAt bump, no save) when nothing actually changes.
    func update(_ id: Script.ID, title: String? = nil, body: String? = nil)
    func rename(_ id: Script.ID, to title: String)
    /// New id, title "<displayTitle> copy", same body, createdAt = updatedAt = now.
    @discardableResult func duplicate(_ id: Script.ID) -> Script?
    /// Returns the removed script so the UI can offer Undo.
    @discardableResult func delete(_ id: Script.ID) -> Script?
    /// Undo for delete: re-inserts with its original id and timestamps (no-op if the id already exists).
    func restore(_ script: Script)
    /// Removes the script if `isBlank`; returns true if removed. The editor calls this when it closes.
    @discardableResult func deleteIfBlank(_ id: Script.ID) -> Bool
    /// Re-adds the sample script (fresh timestamps) if no script has SampleScript.id. Used by M2 app settings.
    func restoreSampleScript()
}
// File format: {"version":1,"scripts":[...]}, JSONEncoder dates .iso8601, sortedKeys; Data.write(options: .atomic).

// Prompter/Services/SettingsStore.swift
@MainActor @Observable
final class SettingsStore {
    var settings: PrompterSettings            // didSet: clamp + save when changed
    init(defaults: UserDefaults = .standard, key: String = "prompterSettings")
    func reset()                              // back to PrompterSettings()
}

// Prompter/App/LaunchOptions.swift
struct LaunchOptions: Equatable, Sendable {
    enum Route: String, Sendable, CaseIterable { case library, editor, prompter, settings }
    var route: Route = .library               // "-route editor"
    var demoData: Bool = false                // "-demoData" (bare flag) or "-demoData YES|1|true"
    init(arguments: [String] = ProcessInfo.processInfo.arguments)
}

// Prompter/Features/Editor/EditorView.swift  — STUB ONLY in Task 1 (Task 3 replaces the body)
struct EditorView: View {
    let scriptID: Script.ID
    var onPrompt: (Script.ID) -> Void
    var body: some View { Text("Editor") }
}
```

**Tests to write first (TDD), one file per type in `PrompterTests/`:**
- `TimeFormattingTests`: 0 → "0:00"; 59.4 → "0:59"; 59.5 → "1:00"; 176 → "2:56"; 3600 → "1:00:00"; 3725 → "1:02:05"; -5, .nan, .infinity → "0:00".
- `ScriptTests`: displayTitle trims and falls back to "Untitled"; firstLine skips leading blank lines; isBlank; updatedAt defaults to createdAt; Codable round trip.
- `ReadingStatsTests`: "" → 0; "Hello,   world!\n\nAgain" → 3; "— - •" → 0; "e-mail 2026 rock'n'roll" → 3; 140 words at 140 wpm → 60 s; wpm 0 / negative / NaN → 0.
- `PrompterSettingsTests`: defaults match the spec (mirror on, flip off, heavy, 72 pt, 1.6×, 6 %, white on black, countdown 5, wpm 140, reading line 1/3);
  round trip; `decodesEmptyObjectToDefaults` (`{}` → `PrompterSettings()`); `ignoresUnknownKeys`; `clampsOutOfRangeValues`
  (fontSize 999 → 200, countdownSeconds 7 → 5, speedLevel 0 → 1, wpm NaN → 140); unknown enum raw value (e.g. `"scheme":"purple"`) → default, not a throw.
- `ScriptImporterTests` (write fixture files into a temp dir): txt UTF-8; `decodesWindows1252` ("café — “quoted”" bytes); `decodesUTF16WithBOM`;
  `normalizesCRLFAndBOM`; rtf (build the RTF data with `NSAttributedString(string:).data(from:documentAttributes: [.documentType: .rtf])`) → plain text;
  title from file name ("My Talk.txt" → "My Talk"); `whitespaceOnlyFileIsEmpty` → throws `.empty`; ".pdf" → `.unsupportedType("pdf")`;
  fromPlainText title = first line, body keeps the first line; long first line cut at a word boundary with "…" and ≤ 61 chars.
- `ScriptStoreTests` (`@MainActor`, fresh temp dir each, injected clock you can advance):
  `sampleIsSeededOnlyWhenNoFileExists` (first init has the sample; delete it; second init on the same dir has 0 scripts);
  create/update/rename/duplicate/delete/restore each persist (re-open a new store on the same dir and compare);
  ordering by updatedAt desc; `updateWithSameValuesDoesNotBumpUpdatedAt`; `createFromBlankTextReturnsNil`;
  `deleteIfBlankRemovesOnlyBlankScripts`; `restoreSampleScriptIsIdempotent`;
  `corruptFileIsMovedAsideAndNotOverwritten` (write "not json"; init; scripts empty; lastError non-nil; a `scripts-corrupt-*.json` exists with the original bytes; an empty `scripts.json` replaces it so the next launch doesn't re-seed). Review fixes added: a file that can't be *read* (I/O or permission error) is left in place with saving blocked (`unreadableFileIsLeftInPlaceAndNeverOverwritten`); blank scripts are dropped on load (`blankScriptsLeftBehindAreDroppedOnLoad`); `saveErrorsAreReportedEachTimeAndClearedBySuccess`;
  `importFilesReportsFailuresByName` (one good .txt + one .pdf → 1 imported, 1 failure named "x.pdf").
- `SettingsStoreTests` (`@MainActor`, unique suite): defaults when empty; change persists to a new store on the same suite; reset; corrupt data in the key → defaults.
- `LaunchOptionsTests`: [] → library/false; ["-route","editor"] → editor; ["-demoData"] → true; ["-demoData","NO"] → false; unknown route → library.

**Steps:**
- [ ] Write the tests above; run `scripts/test.sh`; they fail to compile (types missing).
- [ ] Implement the types; delete `PrompterTests/SkeletonTests.swift` only if `PrompterShared` is removed (keep it otherwise).
- [ ] `scripts/build.sh` and `scripts/test.sh` green.
- [ ] Commit: `git add -A && git commit -m "M1: core models, script store, importer, settings, launch options"`.

---

### Task 2: Library screen + app wiring  · model: Sonnet · runs in parallel with Task 3 (own worktree)

**Files:** create `Prompter/Features/Library/LibraryView.swift`, `Prompter/Features/Library/ScriptRow.swift`,
`Prompter/Features/Prompter/PrompterPlaceholderView.swift`; modify `Prompter/App/PrompterApp.swift`,
`Prompter/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`. Do NOT touch `EditorView.swift` or any Task 1 file.

**Interfaces:** consumes Task 1 (`ScriptStore`, `SettingsStore`, `ReadingStats`, `TimeFormatting`, `LaunchOptions`, `DemoData`,
`EditorView(scriptID:onPrompt:)`). Produces `LibraryView()` (reads stores from the environment) and
`PrompterPlaceholderView(scriptID: Script.ID)` (M2 replaces it with the real prompter).

**Behaviour:**
- `PrompterApp`: parse `LaunchOptions()`. Store directory = `ScriptStore.defaultDirectory`, or with `demoData` a fresh
  `FileManager.default.temporaryDirectory/PrompterDemo-<UUID>` seeded with `DemoData.scripts(now:)`. Inject `ScriptStore` and
  `SettingsStore` via `.environment(...)`. `.preferredColorScheme(.dark)` on the root. Pass the initial route to `LibraryView`
  (e.g. `LibraryView(initialRoute: options.route)`): `.editor` pushes the newest script's editor on appear; `.prompter` opens the placeholder
  for the newest script; `.settings` is ignored until M2.
- `LibraryView`: `NavigationStack(path:)` of `Script.ID`, large title "Scripts". `List` of `ScriptRow` in store order.
  Tap a row → push `EditorView(scriptID:onPrompt:)`. Toolbar (trailing): a `Menu` with label `plus` containing **New script**
  (creates a blank script and pushes its editor), **Paste as new script** (`UIPasteboard.general.string` → `store.createFromText`;
  nil → alert "The clipboard has no text to paste."), **Import file…** (`.fileImporter`, `[.plainText, .rtf]`,
  multiple selection → `store.importFiles`; any failures → one alert listing "name: message" lines).
- Row: title (headline, 1 line), first line (subheadline, secondary, 1 line), meta line (caption, secondary):
  `"412 words · 2:56 · " + Text(updatedAt, format: .relative(presentation: .named))`, read time at `settings.wordsPerMinute`.
  Trailing **Prompt** button (`.borderedProminent`, capsule, `play.fill`) → presents `PrompterPlaceholderView` via
  `.fullScreenCover(item:)` on the library.
- Swipe trailing: **Delete** (destructive) → `store.delete` → bottom banner "Deleted “Title”" with **Undo** (`store.restore`), auto-hides after 6 s,
  replaced if another delete happens. Context menu: Prompt, Duplicate, Rename (alert with a TextField, Save/Cancel), Delete.
- Empty state (`ContentUnavailableView`): "No scripts yet", description "Write one, paste from the clipboard, or import a .txt or .rtf file.",
  actions New script / Paste as new script / Import file….
- `store.lastError` → one alert on appear ("OK" dismisses; it is fine to keep it local state).
- `PrompterPlaceholderView`: black background, white heavy title of the script, "The prompter arrives in Milestone 2.", a Close button
  (`xmark`, top leading). `.statusBarHidden()`.
- Accent colour: amber `#FFB020` (sRGB) for any appearance.
- iPad: must not break (NavigationStack is fine).

**Steps:**
- [ ] Implement; `scripts/build.sh` green (do NOT run `scripts/test.sh` — Task 3 runs in parallel and tests share a simulator).
- [ ] Commit on your worktree branch and also create branch `m1/library` pointing at it.

---

### Task 3: Editor screen  · model: Sonnet · runs in parallel with Task 2 (own worktree)

**Files:** modify `Prompter/Features/Editor/EditorView.swift` only (you may add `Prompter/Features/Editor/*` helpers).

**Interfaces:** consumes `ScriptStore` (environment), `SettingsStore` (environment), `ReadingStats`, `TimeFormatting`.
Keep the exact signature `EditorView(scriptID: Script.ID, onPrompt: (Script.ID) -> Void)`.

**Behaviour:**
- Title `TextField("Title", …)` (title2, bold), then a full-height `TextEditor` for the body with a placeholder overlay
  "Start typing your script…" when empty. `.scrollDismissesKeyboard(.interactively)`.
- Local `@State` drafts initialised from the store on appear; every change calls `store.update(scriptID, title:/body:)` (autosave;
  the store ignores no-op updates). New blank scripts focus the body.
- Footer (safe-area inset at the bottom, secondary caption): `"412 words · 2:56 at 140 wpm"` using `settings.wordsPerMinute`.
- Toolbar: **Prompt** button (`play.fill`, `.borderedProminent`) → `onPrompt(scriptID)`. `.navigationBarTitleDisplayMode(.inline)`.
- On disappear: `store.deleteIfBlank(scriptID)`.
- If the script no longer exists: `ContentUnavailableView("Script deleted", systemImage: "doc")`.

**Steps:**
- [ ] Implement; `scripts/build.sh` green (do NOT run `scripts/test.sh`).
- [ ] Commit on your worktree branch and also create branch `m1/editor` pointing at it.

---

### Task 4: Integrate  · model: Sonnet
- [ ] On `main`, `git merge --no-ff m1/library` then `m1/editor`. Resolve conflicts (there should be none: disjoint files).
- [ ] `scripts/build.sh` + `scripts/test.sh` green; fix integration errors; commit.

### Task 5: Review and fix  · reviewers Opus/Sonnet, fixer Opus
- [ ] Independent reviewers (spec compliance; correctness of store/importer/stats against the Review Focus; SwiftUI/Swift 6/UX quality).
- [ ] Each finding is adversarially verified; confirmed ones are fixed with a regression test where the code is testable.
- [ ] `scripts/build.sh` + `scripts/test.sh` green; commit.

### Task 6: Milestone close (orchestrator)
- [ ] Own review of the diff against spec §3.1, §3.2, §6, §7-M1.
- [ ] Screenshots on the iPhone 17 Pro simulator with `-demoData`: `docs/screenshots/m1-library.png` (`-route library`),
      `docs/screenshots/m1-editor.png` (`-route editor`).
- [ ] `docs/PROGRESS.md` M1 entry; shut down simulators; milestone commit.
