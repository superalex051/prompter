import Foundation

/// What a hardware key (keyboard or Bluetooth clicker) asks the prompter to do.
enum PrompterKeyAction: Equatable, Sendable {
    case togglePlay
    case stepLine(Int)
    case stepParagraph(Int)
    case speedStep(Int)
    case backToTop
    case exit
}
