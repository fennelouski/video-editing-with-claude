import Foundation
import CryptoKit

public struct SoundAsset: Codable, Identifiable, Hashable, Sendable {
    public let id, title, category: String
    public let tags: [String]
    public let relativePath, sha256: String
    public let bytes: Int
    public let duration: Double
    public let format: String
    public let sampleRate, channels: Int
    public let license, creator, sourceURL, licenseURL, providerID, packageID, auditionStatus, note: String
    public let redistributionAllowed: Bool
    public var uri: String { "sfx://asset/\(id)" }
    public var formatLabel: String { "\(format.uppercased()) · \(sampleRate / 1000) kHz · \(channels == 1 ? "mono" : "\(channels) ch")" }
}

public struct SoundCatalog: Codable, Sendable {
    public struct LicenseRecord: Codable, Sendable { public let path, sha256: String }
    public let schemaVersion: Int
    public let libraryID, version, sourceManifestSHA256: String
    public let assets: [SoundAsset]
    public let licenseRecords: [LicenseRecord]
    public var categories: [String] { Array(Set(assets.map(\.category))).sorted() }
    public func asset(_ id: String?) -> SoundAsset? { assets.first { $0.id == id } }

    public func verifyPackage(root: URL) throws -> Set<String> {
        let resource = Bundle.module.resourceURL!.appendingPathComponent("Resources/package-compatibility.json")
        let compatibility = try Data(contentsOf:resource)
        guard digest(compatibility) == "48c5baeacfe4dd0ba14c04cd5c4369b5028a4f00c32d99d200307e6eb3ab1fed",
              let record = try JSONSerialization.jsonObject(with:compatibility) as? [String:Any],
              record["canonical_reference_manifest_sha256"] as? String == sourceManifestSHA256,
              record["library_version"] as? String == version,
              let packages = record["packages"] as? [[String:Any]] else { throw SoundFailure.invalid("Restore this catalog's pinned package compatibility records.") }
        let bytes = try LibraryFiles.read(root:root,path:"asset-library.json",limit:8*1024*1024)
        guard let package = packages.first(where:{ $0["package_manifest_sha256"] as? String == digest(bytes) }),
              let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let assets = object["assets"] as? [[String:Any]], assets.count == package["asset_count"] as? Int else {
            throw SoundFailure.invalid("This folder has no compatible pinned package manifest. Choose the original package root containing audio/ and asset-library.json.")
        }
        var ids = Set<String>()
        for entry in assets {
            guard let id = entry["asset_id"] as? String, let asset = self.asset(id),
                  entry["sha256"] as? String == asset.sha256, entry["file_path"] as? String == asset.relativePath,
                  ids.insert(id).inserted else { throw SoundFailure.invalid("The selected package does not match this catalog's stable asset IDs and hashes.") }
        }
        return ids
    }

    public static func bundled() throws -> SoundCatalog {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Resources")
        let data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        guard digest(data) == "169d8a73d8464f3435806436e8707126120f08590b0182692ce82c80f8c18e00" else {
            throw SoundFailure.invalid("The bundled catalog changed. Restore its pinned release.")
        }
        let catalog = try decode(data)
        for record in catalog.licenseRecords {
            guard digest(try Data(contentsOf: root.appendingPathComponent(record.path))) == record.sha256 else {
                throw SoundFailure.invalid("The bundled license evidence changed. Restore this catalog release.")
            }
        }
        return catalog
    }

    public static func decode(_ data: Data) throws -> SoundCatalog {
        let c = try JSONDecoder().decode(Self.self, from: data)
        guard c.schemaVersion == 1, !c.version.isEmpty, !c.libraryID.isEmpty,
              Set(c.assets.map(\.id)).count == c.assets.count else { throw SoundFailure.invalid("Unsupported or duplicate catalog release.") }
        for a in c.assets {
            guard a.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
                  a.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  a.duration.isFinite, a.duration > 0, a.bytes > 0, a.bytes <= 64 * 1024 * 1024,
                  a.sampleRate > 0, a.channels > 0 else { throw SoundFailure.invalid("Invalid catalog record: \(a.id)") }
            _ = try LibraryFiles.components(a.relativePath)
        }
        return c
    }

    public func search(text: String = "", category: String? = nil, tag: String? = nil,
                       ids: Set<String>? = nil) -> [SoundAsset] {
        let words = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).split(whereSeparator: \.isWhitespace)
        return assets.filter { a in
            guard category == nil || a.category == category, tag == nil || a.tags.contains(tag!), ids == nil || ids!.contains(a.id) else { return false }
            let haystack = ([a.title, a.id, a.category, a.creator] + a.tags).joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return words.allSatisfy { haystack.contains($0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

public enum SoundFailure: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}
