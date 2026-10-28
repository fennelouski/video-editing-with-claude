import Foundation

/// Reads an explicitly prepared PCM cache without changing asset identity or
/// enabling playback. Native availability remains gated until UI wiring lands.
public enum DecodedSoundCache {
    public struct Snapshot: Sendable {
        public let originalSHA256: String
        public let decodedSHA256: String
        public let pcm: Data
        public let envelope: WaveEnvelope
    }
    private struct Identity: Codable {
        let revision,assetID,originalSHA256,decoderSHA256: String
        let expectedDuration: Double
        let sampleRate,channels: Int
    }
    private struct PCM: Codable {
        let channels,sampleRate,frames: Int
        let duration: Double
    }
    private struct Receipt: Codable {
        let identity: Identity
        let decodedSHA256,humanAudition: String
        let pcm: PCM
    }
    public static func read(asset:SoundAsset,original:Data,cacheRoot:URL,cacheKey:String,expectedDecoderSHA256:String,expectedReceiptSHA256:String) throws -> Snapshot {
        func validHash(_ value:String) -> Bool { value.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil }
        guard asset.format=="ogg",asset.license=="CC0-1.0",asset.redistributionAllowed,
              validHash(cacheKey),validHash(expectedDecoderSHA256),validHash(expectedReceiptSHA256),original.count==asset.bytes,
              digest(original)==asset.sha256 else { throw SoundFailure.invalid("The original Ogg identity or decoder selection is invalid.") }
        let bytes=try LibraryFiles.read(root:cacheRoot,path:cacheKey+"/receipt.json",limit:65536)
        guard digest(bytes)==expectedReceiptSHA256 else { throw SoundFailure.invalid("The prepared decoded-cache receipt changed.") }
        let receipt=try JSONDecoder().decode(Receipt.self,from:bytes),identity=receipt.identity
        guard identity.revision=="ogg-pcm16-v1",identity.assetID==asset.id,
              identity.originalSHA256==asset.sha256,identity.decoderSHA256==expectedDecoderSHA256,
              identity.expectedDuration==asset.duration,identity.sampleRate==asset.sampleRate,identity.channels==asset.channels,
              receipt.humanAudition=="NOT_AUDITIONED",validHash(receipt.decodedSHA256) else {
            throw SoundFailure.invalid("The decoded cache belongs to another sound or decoder.")
        }
        let pcm=try LibraryFiles.read(root:cacheRoot,path:cacheKey+"/decoded.wav",limit:128*1024*1024)
        guard digest(pcm)==receipt.decodedSHA256 else { throw SoundFailure.invalid("Decoded audio changed. Prepare a new verified cache.") }
        let envelope=try WaveEnvelope.decode(pcm)
        guard envelope.sampleRate==asset.sampleRate,envelope.channels==asset.channels,
              abs(envelope.duration-asset.duration)<0.01,
              receipt.pcm.sampleRate==envelope.sampleRate,receipt.pcm.channels==envelope.channels,
              receipt.pcm.frames>0,abs(Double(receipt.pcm.frames)/Double(envelope.sampleRate)-envelope.duration)<0.000001,
              abs(receipt.pcm.duration-envelope.duration)<0.000001 else {
            throw SoundFailure.invalid("Decoded audio does not match the catalog sample range.")
        }
        return .init(originalSHA256:asset.sha256,decodedSHA256:receipt.decodedSHA256,pcm:pcm,envelope:envelope)
    }
}
