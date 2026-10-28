import Foundation
import Darwin

public enum Availability: String, Codable, Sendable {
    case notLinked = "Not linked", missing = "Missing file", available = "Available offline"
    case hashMismatch = "Hash mismatch", licenseBlocked = "License blocked", unsupported = "Unsupported format", unreadable = "Cannot read"
}

public struct AssetInspection: Sendable {
    public let state: Availability
    public let envelope: [Float]
    public let message: String
    public init(_ state: Availability, envelope: [Float] = [], message: String = "") {
        self.state = state; self.envelope = envelope; self.message = message
    }
}

/// Reads from an explicitly selected root only. Every path component is opened
/// without following symlinks; verified Data is the playback snapshot as well.
public enum LibraryFiles {
    public static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SoundFailure.invalid("Unsafe library-relative path.")
        }
        return parts
    }

    public static func read(root: URL, path: String, limit: Int) throws -> Data {
        let parts = try components(path)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SoundFailure.invalid("Library folder unavailable. Reconnect or relink it.") }
        defer { close(fd) }
        for (index, component) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = openat(fd, component, flags)
            guard next >= 0 else { throw SoundFailure.invalid("File missing or inaccessible in the linked library.") }
            close(fd); fd = next
        }
        var stat = Darwin.stat()
        guard fstat(fd, &stat) == 0, (stat.st_mode & S_IFMT) == S_IFREG, stat.st_size <= limit, stat.st_size > 0 else {
            throw SoundFailure.invalid("Expected a bounded regular audio file.")
        }
        var data = Data(count: Int(stat.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if n <= 0 { return -1 }; total += n
            }
            return total
        }
        guard count == data.count else { throw SoundFailure.invalid("The file changed while reading. Check the library again.") }
        return data
    }

    public static func verifiedData(asset: SoundAsset, root: URL) throws -> Data {
        guard asset.license == "CC0-1.0", asset.redistributionAllowed else { throw SoundFailure.invalid("This release has no supported license evidence for this sound.") }
        let data = try read(root: root, path: asset.relativePath, limit: asset.bytes)
        guard data.count == asset.bytes, digest(data) == asset.sha256 else { throw SoundFailure.invalid("Sound hash differs from the pinned catalog. Relink the original file.") }
        return data
    }

    public static func inspect(asset: SoundAsset, root: URL) -> AssetInspection {
        guard asset.license == "CC0-1.0", asset.redistributionAllowed else { return .init(.licenseBlocked) }
        do {
            let data = try read(root: root, path: asset.relativePath, limit: asset.bytes)
            guard data.count == asset.bytes, digest(data) == asset.sha256 else { return .init(.hashMismatch) }
            guard asset.format == "wav" else {
                return .init(.unsupported, message: "This catalog format is not supported for local preview or selection. The original file has been verified and remains unchanged.")
            }
            let wav = try WaveEnvelope.decode(data)
            guard abs(wav.duration - asset.duration) < 0.01, wav.sampleRate == asset.sampleRate, wav.channels == asset.channels else {
                return .init(.unsupported, message: "Decoded format differs from the pinned catalog.")
            }
            return .init(.available, envelope: wav.peaks)
        } catch let error as WaveEnvelope.Failure {
            return .init(.unsupported, message: error.localizedDescription)
        } catch {
            return .init(.missing, message: error.localizedDescription)
        }
    }
}

/// PCM/IEEE-float WAV envelope from all real frames; no simulated waveforms.
/// Unsupported codecs remain explicit instead of installing codecs or proxies.
public struct WaveEnvelope: Sendable {
    public let peaks: [Float]
    public let duration: Double
    public let sampleRate, channels: Int
    public enum Failure: LocalizedError {
        case unsupported
        public var errorDescription: String? { "Preview supports PCM or float WAV. This file needs a supported local decoder." }
    }
    public static func decode(_ data: Data, bins: Int = 128) throws -> WaveEnvelope {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        func text(_ i: Int, _ n: Int) -> String { String(bytes: b[i..<i+n], encoding: .ascii) ?? "" }
        guard b.count >= 44, text(0,4) == "RIFF", text(8,4) == "WAVE", bins > 0 else { throw Failure.unsupported }
        var offset = 12, fmt: (Int,Int,Int,Int,Int)?, audio: Range<Int>?
        while offset + 8 <= b.count {
            let count = Int(u32(offset+4)), start = offset+8
            guard count <= b.count-start else { throw Failure.unsupported }
            if text(offset,4) == "fmt ", count >= 16 {
                var encoding = u16(start)
                if encoding == 0xfffe, count >= 40 { encoding = u16(start+24) }
                fmt = (encoding,u16(start+2),Int(u32(start+4)),u16(start+12),u16(start+14))
            }
            if text(offset,4) == "data" { audio = start..<start+count }
            offset = start+count+(count%2)
        }
        guard let (encoding,channels,rate,align,bits) = fmt, let audio,
              channels > 0, channels <= 32, rate > 0,
              (encoding == 1 && [8,16,24,32].contains(bits)) || (encoding == 3 && bits == 32),
              align == channels*(bits/8), audio.count > 0, audio.count % align == 0 else { throw Failure.unsupported }
        let frames = audio.count/align
        var peaks = [Float](repeating: 0, count: min(bins,frames))
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<channels {
                let i = audio.lowerBound + frame*align + channel*(bits/8)
                let sample: Float
                if encoding == 3 { sample = Float(bitPattern: u32(i)) }
                else if bits == 8 { sample = Float(Int(b[i])-128)/128 }
                else if bits == 16 { sample = Float(Int16(bitPattern: UInt16(u16(i))))/32768 }
                else if bits == 24 {
                    let raw = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
                    sample = Float((raw << 8) >> 8)/8388608
                } else { sample = Float(Int32(bitPattern:u32(i)))/2147483648 }
                guard sample.isFinite else { throw Failure.unsupported }
                peak = max(peak, min(1,abs(sample)))
            }
            let bucket = min(peaks.count-1,frame*peaks.count/frames)
            peaks[bucket] = max(peaks[bucket],peak)
        }
        return .init(peaks: peaks, duration: Double(frames)/Double(rate), sampleRate: rate, channels: channels)
    }
}
