import AVFoundation
import Speech

/// Microphone and speech-recognition permission, asked only when voice-follow is picked or a voice take is about to run.
enum VoicePermissions {
    enum Status: Equatable, Sendable { case notAsked, granted, denied }

    static var microphone: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .notAsked
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// Shows the system prompt the first time; afterwards answers at once.
    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Only the SFSpeechRecognizer fallback needs this; SpeechAnalyzer runs without it.
    static var speechRecognition: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// What the settings footer says when Voice is picked: nil when voice can listen as far as permissions go (asking
    /// for any that haven't been asked if `requesting`). The script's language is checked when a prompter opens.
    @MainActor
    static func problem(requesting: Bool) async -> VoiceProblem? {
        switch microphone {
        case .denied:
            return .microphoneDenied
        case .notAsked:
            guard requesting else { return nil }
            guard await requestMicrophone() else { return .microphoneDenied }
        case .granted:
            break
        }
        // SpeechAnalyzer needs no speech permission; only the older recogniser it falls back to does.
        guard !SpeechRecognizerChoice.analyzerIsAvailable else { return nil }
        guard SpeechRecognizerChoice.taskRecognizerIsAvailable else { return .unsupported }
        switch speechRecognition {
        case .denied:
            return .speechDenied
        case .notAsked:
            guard requesting else { return nil }
            return await requestSpeechRecognition() ? nil : .speechDenied
        case .granted:
            return nil
        }
    }
}
