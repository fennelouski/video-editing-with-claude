import Foundation

/// Portable handoff; no absolute path, account identifier, approval or playback gain.
/// The timeline adapter supplies integer placement frames and validates again.
public struct SoundSelectionReference: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID, libraryVersion, assetID, assetURI, expectedSHA256, license: String
    public let sourceDurationSeconds: Double
    public let auditionStatus: String
    public init(catalog: SoundCatalog, asset: SoundAsset) {
        schemaVersion = 1; libraryID = catalog.libraryID; libraryVersion = catalog.version
        assetID = asset.id; assetURI = asset.uri; expectedSHA256 = asset.sha256
        license = asset.license; sourceDurationSeconds = asset.duration; auditionStatus = asset.auditionStatus
    }
    public func validate(catalog: SoundCatalog) throws -> SoundAsset {
        guard schemaVersion == 1, libraryID == catalog.libraryID, libraryVersion == catalog.version,
              let asset = catalog.asset(assetID), assetURI == asset.uri,
              expectedSHA256 == asset.sha256, license == asset.license,
              sourceDurationSeconds == asset.duration, auditionStatus == asset.auditionStatus else {
            throw SoundFailure.invalid("Sound reference does not match this pinned catalog release. Relink its original version.")
        }
        return asset
    }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct SoundInsertionRequest: Codable, Equatable, Sendable {
    public let reference: SoundSelectionReference
    public let timelineStartFrame, sourceStartFrame, durationFrames: Int64
    public let gainDB: Double
    public let frameDurationNumerator: Int
    public let frameDurationDenominator: Int

    public init(reference: SoundSelectionReference, timelineStartFrame: Int64,
                sourceStartFrame: Int64, durationFrames: Int64, gainDB: Double) throws {
        let total = sourceStartFrame.addingReportingOverflow(durationFrames)
        let timelineEnd = timelineStartFrame.addingReportingOverflow(durationFrames)
        guard timelineStartFrame >= 0, sourceStartFrame >= 0, durationFrames > 0, !total.overflow,
              !timelineEnd.overflow,
              gainDB.isFinite, (-96...12).contains(gainDB), reference.sourceDurationSeconds.isFinite,
              Double(total.partialValue)*1001/24000 <= reference.sourceDurationSeconds else {
            throw SoundFailure.invalid("Choose a frame-aligned range within the original sound and a valid gain.")
        }
        self.reference = reference; self.timelineStartFrame = timelineStartFrame
        self.sourceStartFrame = sourceStartFrame; self.durationFrames = durationFrames; self.gainDB = gainDB
        frameDurationNumerator = 1001; frameDurationDenominator = 24000
    }

    private enum CodingKeys: String, CodingKey {
        case reference, timelineStartFrame, sourceStartFrame, durationFrames, gainDB, frameDurationNumerator, frameDurationDenominator
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self,forKey:.frameDurationNumerator) == 1001,
              try c.decode(Int.self,forKey:.frameDurationDenominator) == 24000 else {
            throw SoundFailure.invalid("The sound cue uses a different timeline timebase.")
        }
        try self.init(reference:c.decode(SoundSelectionReference.self,forKey:.reference),
                      timelineStartFrame:c.decode(Int64.self,forKey:.timelineStartFrame),
                      sourceStartFrame:c.decode(Int64.self,forKey:.sourceStartFrame),
                      durationFrames:c.decode(Int64.self,forKey:.durationFrames),gainDB:c.decode(Double.self,forKey:.gainDB))
    }
    public func validate(catalog: SoundCatalog) throws {
        _ = try reference.validate(catalog:catalog)
        _ = try Self(reference:reference,timelineStartFrame:timelineStartFrame,sourceStartFrame:sourceStartFrame,durationFrames:durationFrames,gainDB:gainDB)
    }
}
