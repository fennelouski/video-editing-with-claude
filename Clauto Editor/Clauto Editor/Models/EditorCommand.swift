import Foundation

/// Stable identifiers shared by menu, palette and the focused video surface.
/// The original four values remain unchanged for saved/native menu dispatch.
enum EditorCommand: Int, CaseIterable, Identifiable, Sendable {
    case toggle = 0, back, forward, comment
    case palette, brief, files, transcript, review, reverse, stop, play
    case previousFrame, nextFrame, timecode, previousVersion, nextVersion
    case assetsPane, feedbackPane, focusAssets, focusVideo, focusFeedback
    case detach, fullScreen, pictureInPicture
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .toggle: "Play / Pause"
        case .back: "Skip Backward"
        case .forward: "Skip Forward"
        case .comment: "Pause and Add Frame Comment…"
        case .palette: "Commands…"
        case .brief: "Show Brief"
        case .files: "Show Files"
        case .transcript: "Show Transcript"
        case .review: "Show Review"
        case .reverse: "Shuttle Reverse"
        case .stop: "Pause"
        case .play: "Shuttle Forward"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .timecode: "Go to Timecode…"
        case .previousVersion: "Previous Version"
        case .nextVersion: "Next Version"
        case .assetsPane: "Toggle Assets and Versions"
        case .feedbackPane: "Toggle Feedback"
        case .focusAssets: "Focus Assets and Versions"
        case .focusVideo: "Focus Video"
        case .focusFeedback: "Focus Feedback"
        case .detach: "Detach / Re-embed Video"
        case .fullScreen: "Toggle Video Full Screen"
        case .pictureInPicture: "Show Native Picture in Picture Controls"
        }
    }
    var shortcut: String {
        switch self {
        case .toggle: "⌥⌘P · Space on video"
        case .back: "⌥⌘←"
        case .forward: "⌥⌘→"
        case .comment: "⌃⌥⌘M"
        case .palette: "⇧⌘P"
        case .reverse: "J on video"
        case .stop: "K on video"
        case .play: "L on video"
        case .previousFrame: ", on video"
        case .nextFrame: ". on video"
        case .timecode: "⌥⌘T"
        case .brief: "⌥⌘1"
        case .files: "⌥⌘2"
        case .transcript: "⌥⌘3"
        case .review: "⌥⌘4"
        case .focusAssets: "⌃⌥⌘1"
        case .focusVideo: "⌃⌥⌘2"
        case .focusFeedback: "⌃⌥⌘3"
        default: ""
        }
    }
    var needsPlayer: Bool {
        ![.palette,.brief,.files,.transcript,.review,.assetsPane,.feedbackPane,.focusAssets,.focusVideo,.focusFeedback,.previousVersion,.nextVersion].contains(self)
    }
    func matches(_ query: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) || shortcut.localizedCaseInsensitiveContains(query) }
}

/// Saved previews use 24000/1001 fps. Display is 24-frame NON-DROP timecode;
/// timecode seconds are labels, not exact SI seconds. Semicolons are refused.
enum ReviewTimecode {
    static func label(frame: Int) -> String {
        let value = max(0,frame)
        return String(format: "%02d:%02d:%02d:%02d",value/86400,(value/1440)%60,(value/24)%60,value%24)
    }
    static func frame(_ input: String) throws -> Int {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":",omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]), let f = Int(parts[3]),
              h < 24, m < 60, s < 60, f < 24 else {
            throw WorkflowFailure.invalid("Use HH:MM:SS:FF, with 00–23 frames (23.976 fps, non-drop).")
        }
        return ((h*60+m)*60+s)*24+f
    }
    static func seconds(frame: Int) -> Double { Double(frame)*1001/24000 }
}
