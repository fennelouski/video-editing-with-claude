import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// Verification is local and at check time. AVPlayer later reopens a URL; it does
/// not consume a frozen copy. Recheck signatures before play and while playing.
actor SourceMediaVerifier {
    static func asset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
                                      AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    func verify(_ source: TranscriptSource, progress: (@Sendable (Int64, Int64) async throws -> Void)? = nil) async throws -> VerifiedSourceMedia {
        let url = try Self.localFile(source.path)
        let file = try await Self.hashFile(url, expected: source.sourceSHA256, progress: progress)
        let asset = Self.asset(at: file.url)
        guard try await asset.load(.isPlayable) else { throw WorkflowFailure.invalid("This source cannot be played locally.") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw WorkflowFailure.invalid("This source has no readable duration.") }
        var ranges: [SourceAudioRange] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let trackRange = try await track.load(.timeRange)
            // Empty edit segments are silence, even inside a track's timeRange.
            let segments = try await track.load(.segments)
            var contiguous: [SourceAudioRange] = []
            for segment in segments where !segment.isEmpty {
                let target = segment.timeMapping.target
                let start = max(trackRange.start.seconds, target.start.seconds)
                let end = min(CMTimeRangeGetEnd(trackRange).seconds, CMTimeRangeGetEnd(target).seconds)
                guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
                if let last = contiguous.last, start <= last.end {
                    contiguous[contiguous.count - 1] = .init(start: last.start, end: max(end, last.end))
                } else { contiguous.append(.init(start: start, end: end)) }
            }
            ranges += contiguous
        }
        guard !ranges.isEmpty else { throw WorkflowFailure.invalid("This source has no covered recorded-audio ranges.") }
        var transcriptPath: String?, transcriptSignature: SourceFileSignature?
        if let path = source.originalTranscriptPath {
            let snapshot = try await Self.hashFile(try Self.localFile(path), expected: source.transcriptSHA256, capture: true)
            guard let data = snapshot.data else { throw ProjectFailure.invalidProject }
            try TranscriptJSONKeys.validate(data)
            struct Snapshot: Decodable { let words: [TranscriptWord] }
            let words = try JSONDecoder().decode(Snapshot.self, from: data).words
            guard words == source.words else { throw WorkflowFailure.invalid("The original transcript words differ from the source catalog.") }
            transcriptPath = snapshot.url.path; transcriptSignature = snapshot.signature
        }
        let result = VerifiedSourceMedia(sourceID: source.id, requestedPath: source.path, canonicalPath: file.url.path,
            sourceSHA256: source.sourceSHA256, transcriptSHA256: source.transcriptSHA256, transcriptRequestedPath: source.originalTranscriptPath, transcriptPath: transcriptPath,
            transcriptSignature: transcriptSignature, signature: file.signature, durationSeconds: duration,
            audioRanges: ranges, checkedAt: Date())
        try Self.checkCurrent(result)
        try Task.checkCancellation()
        return result
    }

    /// Metadata drift invalidates the check; this is not an immutable-byte guarantee.
    static func checkCurrent(_ media: VerifiedSourceMedia) throws {
        let url = try localFile(media.requestedPath)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == media.canonicalPath,
              try signature(at: url) == media.signature else { throw WorkflowFailure.invalid("Source media changed or disconnected. Verify it again before playing or acknowledging this review.") }
        if let path = media.transcriptPath, let requested = media.transcriptRequestedPath, let signature = media.transcriptSignature {
            guard try localFile(requested).resolvingSymlinksInPath().standardizedFileURL.path == path,
                  try Self.signature(at: localFile(path)) == signature else { throw WorkflowFailure.invalid("The original transcript snapshot changed. Verify the source again.") }
        }
    }

    private static func localFile(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw WorkflowFailure.invalid("A source requires an absolute local file path.") }
        return URL(fileURLWithPath: path)
    }
    private static func signature(_ value: stat) -> SourceFileSignature {
        .init(device: value.st_dev, inode: value.st_ino, size: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    private static func signature(at url: URL) throws -> SourceFileSignature {
        var info = stat()
        guard Darwin.lstat(url.resolvingSymlinksInPath().standardizedFileURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw WorkflowFailure.invalid("Source file is missing, disconnected or not a regular file.")
        }
        return signature(info)
    }
    private static func hashFile(_ requested: URL, expected: String, capture: Bool = false, progress: (@Sendable (Int64, Int64) async throws -> Void)? = nil) async throws -> (url: URL, signature: SourceFileSignature, data: Data?) {
        guard TranscriptCatalog.isSHA(expected) else { throw ProjectFailure.invalidProject }
        let url = requested.resolvingSymlinksInPath().standardizedFileURL
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkflowFailure.invalid("Source file is missing or cannot be read locally.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !capture || info.st_size <= 64 * 1024 * 1024 else {
            throw WorkflowFailure.invalid("The transcript snapshot must be a regular file no larger than 64 MB.")
        }
        let before = signature(info)
        var bytesRead: Int64 = 0
        var sha = SHA256(), data = Data(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw WorkflowFailure.invalid("The source could not be read completely.") }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count)); sha.update(data: chunk)
            bytesRead += Int64(count)
            try await progress?(bytesRead, before.size)
            if capture {
                guard data.count + count <= 64 * 1024 * 1024 else { throw WorkflowFailure.invalid("The transcript snapshot grew beyond 64 MB.") }
                data.append(chunk)
            }
        }
        guard fstat(fd, &info) == 0, signature(info) == before,
              requested.resolvingSymlinksInPath().standardizedFileURL == url,
              try signature(at: url) == before else { throw WorkflowFailure.invalid("Source bytes changed during verification. Retry when the file is stable.") }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw WorkflowFailure.invalid("Source SHA-256 does not match the saved catalog. Relinking cannot silently substitute different bytes.") }
        return (url, before, capture ? data : nil)
    }
}
