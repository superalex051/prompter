import Foundation

/// The script seeded on first launch. It doubles as a quick guide to the prompter controls.
enum SampleScript {
    static let id = UUID(uuidString: "5A3F1E2C-0000-4000-8000-000000000001")!
    static let title = "Welcome to Prompter"
    static let body = """
        This sample script shows how the prompter works. Edit it, or delete it once you know your way around.

        Tap Prompt to open the prompter, then tap the screen to start. After a short countdown the text scrolls up past the reading line, about a third of the way down the screen. Keep your eyes on that line.

        Tap the screen to pause. Tap again to resume.

        Drag up or down to scrub through the script. Scrolling pauses while you drag.

        Pinch to make the text bigger or smaller. Prompter keeps your place.

        Long-press, or tap with two fingers, to open the settings. There you can change the speed, the countdown, the text size and the colors.

        Using a glass rig? The text is mirrored by default, so it reads correctly in the reflection. Turn the mirror off to read straight from the screen.

        Got a Bluetooth clicker or a keyboard? Space or Return starts and pauses. The arrow keys step a line at a time. Plus and minus change the speed, zero goes back to the top, and Escape closes the prompter.

        Wearing an Apple Watch? With the prompter open on your iPhone, open Prompter on your wrist to start, pause and change the speed from across the room. Turn the Digital Crown to change the speed.

        Start a line with // to leave yourself a note. A line with just [pause 2] holds the text for two seconds.

        // Notes like this one are for you: dimmed and not counted.

        [pause 2]

        That's it. Good luck with your take.
        """

    static func make(now: Date) -> Script {
        Script(id: id, title: title, body: body, createdAt: now)
    }
}
