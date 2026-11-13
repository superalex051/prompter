import Foundation

/// Test data for voice-follow.
enum VoiceFixtures {
    /// The first three paragraphs of the demo script "Channel intro: rig tour" (`DemoData`).
    static let rigTour = """
        Hey, welcome back. Today I'm showing you the setup I use to talk straight down the lens without memorizing a single line.

        It's simpler than it looks. My phone lies flat on the desk, screen up, in a little cradle I printed. Above it sits a sheet of clear acrylic at forty-five degrees. The camera films through the acrylic, and I read the reflection.

        Because the reflection flips everything, the app mirrors the text, so it reads the right way round on the glass.
        """

    /// The whole demo script, six paragraphs (about 190 words).
    static let rigTourFull = rigTour + """


        Plain acrylic does throw a faint second image, so I keep the text big, heavy and white on black. That makes the ghost easy to ignore.

        The best part is the remote. I start, pause and slow down the script from my watch, so I never walk back to the phone mid-take.

        By the end of this video you'll know exactly what to buy, what to print, and how to set it up in about ten minutes. Let's get into it.
        """

    /// Every result SpeechTranscriber (macOS 27, en_US, `.volatileResults`) reported, in order, for `say -v Samantha -r 150`
    /// reading `rigTour`, streamed in real time. "v|" volatile, "F|" final; each final ends a segment. Note the half-heard
    /// fragments ("show", "set", "l", "memo ra"), the rewrite of "memo raising" into "memories in" in the final, "45" for
    /// "forty-five", and punctuation coming and going.
    static let analyzerResults = """
        v|Hey
        v|Hey,
        v|Hey, welcome
        v|Hey, welcome back
        v|Hey, welcome back.
        F|Hey, welcome back.
        v|Today
        v|Today I
        v|Today I'
        v|Today I'm
        v|Today I'm show
        v|Today I'm showing
        v|Today I'm showing you
        v|Today I'm showing you the
        v|Today I'm showing you the set
        v|Today I'm showing you the setup
        v|Today I'm showing you the setup I
        v|Today I'm showing you the setup I use
        v|Today I'm showing you the setup I use to
        v|Today I'm showing you the setup I use to talk
        v|Today I'm showing you the setup I use to talk straight
        v|Today I'm showing you the setup I use to talk straight down
        v|Today I'm showing you the setup I use to talk straight down the
        v|Today I'm showing you the setup I use to talk straight down the l
        v|Today I'm showing you the setup I use to talk straight down the lens
        v|Today I'm showing you the setup I use to talk straight down the lens without
        v|Today I'm showing you the setup I use to talk straight down the lens without memo
        v|Today I'm showing you the setup I use to talk straight down the lens without memo ra
        v|Today I'm showing you the setup I use to talk straight down the lens without memo raising
        v|Today I'm showing you the setup I use to talk straight down the lens without memo raising a
        v|Today I'm showing you the setup I use to talk straight down the lens without memo raising a single
        v|Today I'm showing you the setup I use to talk straight down the lens without memo raising a single line
        v|Today I'm showing you the setup I use to talk straight down the lens without memo raising a single line.
        F|Today I'm showing you the setup I use to talk straight down the lens without memories in a single line.
        v|It
        v|It'
        v|It's
        v|It's sim
        v|It's simpl
        v|It's simpler
        v|It's simpler than
        v|It's simpler than it
        v|It's simpler than it looks
        v|It's simpler than it looks.
        F|It's simpler than it looks.
        v|My
        v|My phone
        v|My phone li
        v|My phone lies
        v|My phone lies fl
        v|My phone lies flat
        v|My phone lies flat on
        v|My phone lies flat on the
        v|My phone lies flat on the desk
        v|My phone lies flat on the desk,
        v|My phone lies flat on the desk, screen
        v|My phone lies flat on the desk, screen up
        v|My phone lies flat on the desk, screen up in
        v|My phone lies flat on the desk, screen up in a
        v|My phone lies flat on the desk, screen up in a little
        v|My phone lies flat on the desk, screen up in a little cr
        v|My phone lies flat on the desk, screen up in a little crad
        v|My phone lies flat on the desk, screen up in a little cradle
        v|My phone lies flat on the desk, screen up in a little cradle I
        v|My phone lies flat on the desk, screen up in a little cradle I print
        v|My phone lies flat on the desk, screen up in a little cradle I printed
        v|My phone lies flat on the desk, screen up in a little cradle I printed.
        F|My phone lies flat on the desk, screen up, in a little cradle I printed.
        v|Ab
        v|Above
        v|Above it
        v|Above it s
        v|Above it sits
        v|Above it sits a
        v|Above it sits a she
        v|Above it sits a sheet
        v|Above it sits a sheet of
        v|Above it sits a sheet of clear
        v|Above it sits a sheet of clear ac
        v|Above it sits a sheet of clear acry
        v|Above it sits a sheet of clear acrylic
        v|Above it sits a sheet of clear acrylic at
        v|Above it sits a sheet of clear acrylic at 45
        v|Above it sits a sheet of clear acrylic at 45 degrees
        v|Above it sits a sheet of clear acrylic at 45 degrees.
        F|Above it sits a sheet of clear acrylic at 45 degrees.
        v|The
        v|The camera
        v|The camera fil
        v|The camera films
        v|The camera films through
        v|The camera films through the
        v|The camera films through the ac
        v|The camera films through the acry
        v|The camera films through the acrylic
        v|The camera films through the acrylic, and
        v|The camera films through the acrylic, and I
        v|The camera films through the acrylic, and I read
        v|The camera films through the acrylic, and I read the
        v|The camera films through the acrylic, and I read the ref
        v|The camera films through the acrylic, and I read the refle
        v|The camera films through the acrylic, and I read the reflection
        v|The camera films through the acrylic, and I read the reflection,
        v|The camera films through the acrylic, and I read the reflection, because
        v|The camera films through the acrylic, and I read the reflection, because the
        v|The camera films through the acrylic, and I read the reflection, because the ref
        v|The camera films through the acrylic, and I read the reflection, because the refle
        v|The camera films through the acrylic, and I read the reflection, because the reflection
        v|The camera films through the acrylic, and I read the reflection, because the reflection fl
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything,
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mir
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirr
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirrors
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirrors the
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirrors the text
        v|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirrors the text.
        F|The camera films through the acrylic, and I read the reflection, because the reflection flips everything, the app mirrors the text.
        v|so
        v|so it
        v|so it read
        v|so it reads
        v|so it reads the
        v|so it reads the right
        v|so it reads the right way
        v|so it reads the right way round
        v|so it reads the right way round on
        v|so it reads the right way round on the
        v|so it reads the right way round on the glass
        v|so it reads the right way round on the glass.
        F|So it reads the right way round on the glass.
        """

    /// `analyzerResults` as (text, isFinal) pairs.
    static var analyzerUpdates: [(text: String, isFinal: Bool)] {
        analyzerResults.split(separator: "\n").map { line in
            let isFinal = line.hasPrefix("F|")
            return (String(line.dropFirst(2)), isFinal)
        }
    }
}
