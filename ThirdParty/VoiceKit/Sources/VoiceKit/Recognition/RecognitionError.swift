//
//  RecognitionError.swift
//  VoiceKit
//
//  Errors from the speech recognition pipeline.
//

import Foundation

/// Errors from the speech recognition service.
public enum RecognitionError: LocalizedError, Sendable {
    /// User denied speech recognition or microphone permission.
    case notAuthorized
    /// Speech recognizer is unavailable on this device.
    case recognitionUnavailable
    /// Audio engine failed to start.
    case engineStartFailed(Error)
    /// Recognition pipeline encountered an error.
    case recognitionFailed(Error)
    /// On-device model download failed.
    case modelDownloadFailed(Error)
    /// Requested locale is not supported for on-device recognition.
    case localeNotSupported

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or Speech Recognition access is off. Enable both permissions in Settings to use voice recognition."
        case .recognitionUnavailable:
            return "Speech recognition is unavailable on this device right now. Try again later."
        case .engineStartFailed(let error):
            return Self.message("The microphone could not start. Check microphone access and your selected audio input, then try again.", cause: error)
        case .recognitionFailed(let error):
            return Self.message("Speech recognition stopped. Try again.", cause: error)
        case .modelDownloadFailed(let error):
            return Self.message("The speech model could not download. Check your connection and available storage, then try again.", cause: error)
        case .localeNotSupported:
            return "On-device speech recognition is unavailable for the selected language on this device. Choose another speech language."
        }
    }

    private static func message(_ explanation: String, cause: Error) -> String {
        let detail = (cause as? LocalizedError)?.errorDescription
            ?? (cause as NSError).userInfo[NSLocalizedDescriptionKey] as? String
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return explanation }
        return "\(explanation) \(detail)"
    }
}
