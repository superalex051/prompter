import Foundation

/// Realistic scripts for screenshots, used with the `-demoData` launch argument.
enum DemoData {
    /// Device names a `-demoData` launch shows and announces, so screenshots and checks never carry the real machine name.
    static let macName = "Studio Mac"
    static let phoneName = "Studio iPhone"

    /// The Markdown demo script's fixed id (`-script markdown` opens it).
    static let markdownScriptID = UUID(uuidString: "4D41524B-444F-574E-0000-000000000009")!

    /// SampleScript plus 3 realistic scripts with updatedAt spread over the last few days, for screenshots.
    /// `includeMarkdown` (`-demoData -script markdown`): plus `markdownScript`, the newest, for Markdown screenshots.
    static func scripts(now: Date, includeMarkdown: Bool = false) -> [Script] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        return (includeMarkdown ? [markdownScript(now: now - 0.5 * hour)] : []) + [
            Script(
                title: "Channel intro: rig tour",
                body: rigTour,
                createdAt: now - 2 * day,
                updatedAt: now - 2 * hour
            ),
            Script(
                title: "Client testimonial ask",
                body: testimonialAsk,
                createdAt: now - 3 * day,
                updatedAt: now - 1 * day
            ),
            Script(
                title: "Product review: camera",
                body: cameraReview,
                createdAt: now - 6 * day,
                updatedAt: now - 3 * day
            ),
            SampleScript.make(now: now - 8 * day),
        ]
    }

    /// A short script using every kind of Markdown the prompter shows, with a note and a pause cue among it.
    static func markdownScript(now: Date) -> Script {
        Script(id: markdownScriptID, title: "Markdown demo: talking to camera", body: markdownBody, createdAt: now,
               updatedAt: now)
    }

    static let markdownBody = """
        # Cold open
        Most people **freeze** the moment the red light comes on. Here's the *one* thing that fixed it for me.
        // smile, slow down
        ## Three things to try
        - Read from the **glass**, not from paper.
        - Keep each sentence ~~long and clever~~ short.
        - Look *through* the lens, not at it.
        [pause 2]
        ---
        ### Wrap up
        1. Print the cradle.
        2. Cut the acrylic.
        > The rest is **just practice**. See the build at [my site](https://example.com).
        """

    private static let rigTour = """
        Hey, welcome back. Today I'm showing you the setup I use to talk straight down the lens without memorizing a single line.

        It's simpler than it looks. My phone lies flat on the desk, screen up, in a little cradle I printed. Above it sits a sheet of clear acrylic at forty-five degrees. The camera films through the acrylic, and I read the reflection.

        Because the reflection flips everything, the app mirrors the text, so it reads the right way round on the glass.

        Plain acrylic does throw a faint second image, so I keep the text big, heavy and white on black. That makes the ghost easy to ignore.

        The best part is the remote. I start, pause and slow down the script from my watch, so I never walk back to the phone mid-take.

        By the end of this video you'll know exactly what to buy, what to print, and how to set it up in about ten minutes. Let's get into it.
        """

    private static let testimonialAsk = """
        Hi, it's been a real pleasure working with you on this project.

        I'd love to share what we built together with other people who might need the same thing. Would you be open to recording a short testimonial?

        It only needs to be thirty to sixty seconds. Just talk about where things were before we started, what changed, and how it feels now. Your phone camera is perfect. No need for anything fancy.

        If writing is easier, a few sentences by email work just as well, and I'll send you the final version to approve before anything goes live.

        Thanks again for trusting me with this. Speak soon.
        """

    private static let cameraReview = """
        I've shot with this camera every week for a year, so here's my honest take.

        The headline is simple: a full-frame sensor in a body about the size of a crop-sensor camera. It fits in a small bag, it sits nicely on a light tripod, and it doesn't draw attention in public.

        For video, the flip-out screen is the feature I use most. I can frame myself from the front, and the autofocus keeps my eyes sharp even when I move around.

        It isn't perfect. The viewfinder is small, there's only one control dial, and the menus take some getting used to. If you shoot fast-moving events, you'll feel those limits.

        Battery life is better than I expected. I get a full afternoon of talking-head recording from one battery.

        Who should buy it? If you film yourself, travel light, and want full-frame image quality, it's still one of the easiest recommendations I can make.
        """
}
