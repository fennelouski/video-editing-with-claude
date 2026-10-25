import Foundation
import AVFoundation

/// The existing editorial_workflow.py sections/segments contract is the boundary;
/// this workspace additionally requires whole catalog rows for reversible editing.
enum ScriptInterchange {
    private struct Input: Codable {
        let schema_version: Int?
        let title: String?
        let sections: [Section]
        let pickups: [Issue]?
        let fact_flags: [Issue]?
        let coverage_gaps: [Issue]?
    }
    private struct Section: Codable { let title: String?; let segments: [Segment] }
    private struct Segment: Codable {
        let source_id: String
        let source_sha256: String
        let transcript_sha256: String?
        let first_word: Int
        let last_word: Int
        let spoken_text: String?
    }
    private struct Issue: Codable { let id: String?; let description: String; let status: String? }

    static func importVersion(_ data: Data, catalog: TranscriptCatalog, provenance: ScriptProvenance) throws -> ScriptVersion {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw WorkflowFailure.invalid("Choose a source-bound script JSON file smaller than 8 MB.") }
        try TranscriptJSONKeys.validate(data)
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schema_version == nil || input.schema_version == 1, !input.sections.isEmpty else { throw ProjectFailure.invalidProject }
        let sources = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })
        var version = ScriptVersion(title: input.title ?? "Imported script", provenance: provenance, importedArtifact: data)
        version.provenance.importedSHA256 = TranscriptSourceMap.sha(data)
        version.provenance.identityVerified = false
        for section in input.sections {
            guard !section.segments.isEmpty else { throw WorkflowFailure.invalid("A script section has no recorded passages.") }
            for segment in section.segments {
                guard let source = sources[segment.source_id], source.sourceSHA256 == segment.source_sha256,
                      segment.transcript_sha256 == nil || segment.transcript_sha256 == source.transcriptSHA256,
                      let row = catalog.rows.first(where: { $0.sourceID == segment.source_id && $0.firstWord == segment.first_word && $0.lastWord == segment.last_word }),
                      segment.spoken_text == nil || segment.spoken_text == row.text else {
                    throw WorkflowFailure.invalid("A segment does not match an entire current transcript passage, its exact words or source hashes. Use catalog row boundaries and put new wording in pickups.")
                }
                version.beats.append(.init(kind: .passage, rowID: row.id, heading: section.title ?? ""))
            }
        }
        for issue in input.pickups ?? [] {
            version.beats.append(.init(kind: .pickup, heading: "Imported pickup", unrecordedText: issue.description))
        }
        // Preserve unresolved flags in visible editorial notes and original bytes.
        // They cannot disappear merely because a writer supplied a neat script.
        let flags = ((input.fact_flags ?? []) + (input.coverage_gaps ?? [])).map { $0.description }
        if !flags.isEmpty, !version.beats.isEmpty { version.beats[0].notes = flags.joined(separator: "\n") }
        return version
    }

    static func exportVersion(_ version: ScriptVersion, catalog: TranscriptCatalog) throws -> Data {
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, $0) })
        let sources = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })
        var sections: [[String: Any]] = [], pickups: [[String: Any]] = []
        for beat in version.beats {
            if beat.kind == .pickup {
                pickups.append(["id": beat.id.uuidString, "description": beat.unrecordedText]); continue
            }
            guard let id = beat.rowID, let row = rows[id], let source = sources[row.sourceID] else { throw ProjectFailure.invalidProject }
            sections.append(["title": beat.heading, "notes": beat.notes, "segments": [["source_id": source.id,
                "source_sha256": source.sourceSHA256,
                "first_word": row.firstWord, "last_word": row.lastWord, "spoken_text": row.text]]])
        }
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "title": version.title, "sections": sections, "pickups": pickups], options: [.prettyPrinted, .sortedKeys])
    }

    static func exportSources(_ catalog: TranscriptCatalog) throws -> Data {
        let sources: [[String: Any]] = catalog.sources.map { source in
            ["source_id": source.id, "source_sha256": source.sourceSHA256, "duration": source.duration,
             "words": source.words.map { ["word": $0.word, "start": $0.start, "end": $0.end] as [String: Any] }]
        }
        return try JSONSerialization.data(withJSONObject: sources, options: [.prettyPrinted, .sortedKeys])
    }
}

enum ScriptAssemblyXML {
    static func make(_ handoff: ScriptTimelineHandoff, title: String, project: Project) async throws -> String {
        let total = handoff.spans.reduce(0) { $0 + $1.frames }
        guard total > 0, total <= Int.max / 1001 else { throw ProjectFailure.invalidProject }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        func time(_ frame: Int) -> String { "\(frame * 1001)/24000s" }
        let dimensions = project.manifest.outputResolution.dimensions(aspect: project.manifest.aspect)
        let media = Dictionary(uniqueKeysWithValues: handoff.media.map { ($0.sourceID, $0) })
        let ids = Array(Set(handoff.sources.map(\.sourceID))).sorted()
        var resources = "<format id=\"r1\" frameDuration=\"1001/24000s\" width=\"\(dimensions.width)\" height=\"\(dimensions.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"
        var assetIDs: [String: String] = [:]
        for (index, id) in ids.enumerated() {
            guard let source = media[id] else { throw ProjectFailure.invalidProject }
            let asset = AVURLAsset(url: URL(fileURLWithPath: source.canonicalPath))
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let ref = "r\(index + 2)"; assetIDs[id] = ref
            let duration = source.durationSeconds * 24000 / 1001
            guard duration.isFinite, duration > 0, duration < Double(Int.max / 1001) else { throw ProjectFailure.invalidProject }
            var video = ""
            if let track = videoTracks.first {
                let size = try await track.load(.naturalSize), frameDuration = try await track.load(.minFrameDuration)
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      frameDuration.isNumeric, frameDuration.value > 0, frameDuration.timescale > 0 else {
                    throw WorkflowFailure.invalid("This source has no usable native picture format. Review it before exporting an assembly.")
                }
                let formatID = "sourceFormat\(index + 1)"
                resources += "<format id=\"\(formatID)\" name=\"FFVideoFormatRateUndefined\" width=\"\(Int(size.width))\" height=\"\(Int(size.height))\" frameDuration=\"\(frameDuration.value)/\(frameDuration.timescale)s\"/>\n"
                video = " hasVideo=\"1\" format=\"\(formatID)\""
            }
            var channels = 0
            for track in audioTracks {
                for description in try await track.load(.formatDescriptions) {
                    if let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                        channels += Int(format.pointee.mChannelsPerFrame); break
                    }
                }
            }
            guard channels > 0 else { throw WorkflowFailure.invalid("This source has no verified audio channel format for an assembly.") }
            resources += "<asset id=\"\(ref)\" name=\"\(escape(id))\" start=\"0s\" duration=\"\(time(Int(duration.rounded(.down))))\" hasAudio=\"1\" audioSources=\"\(audioTracks.count)\" audioChannels=\"\(channels)\"\(video)><media-rep kind=\"original-media\" src=\"\(escape(URL(fileURLWithPath: source.canonicalPath).absoluteString))\"/></asset>\n"
        }
        var clips = ""
        for span in handoff.spans {
            guard let ref = assetIDs[span.sourceID] else { throw ProjectFailure.invalidProject }
            clips += "<asset-clip ref=\"\(ref)\" name=\"\(escape(span.id))\" offset=\"\(time(span.timelineFrame))\" start=\"\(time(span.startFrame))\" duration=\"\(time(span.frames))\"/>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.13"><resources>\(resources)</resources><library><event name="Script assembly candidates"><project name="\(escape(title)) — script candidate"><sequence format="r1" duration="\(time(total))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k"><spine>\(clips)</spine></sequence></project></event></library></fcpxml>
        """
    }
}
