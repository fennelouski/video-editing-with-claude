import Foundation
import Darwin

/// Descriptor-relative asset publication. UUID output folders are immutable;
/// interrupted SMB copies may resume only with an exact persisted file claim.
/// Every caller must hold the project mutation lease until publication finishes.
enum CreativeAssetFiles {
    private struct Claim: Codable { let schemaVersion: Int; let destination: String; let files: [String:String] }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970; return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
    static func decode<Value: Decodable>(_ bytes: Data,as: Value.Type) throws -> Value {
        try TranscriptJSONKeys.validate(bytes); return try decoder().decode(Value.self,from: bytes)
    }
    static func exists(_ leaf: String,in parent: SourceRenderDirectory) throws -> Bool {
        guard validLeaf(leaf) else { throw ProjectFailure.invalidProject }
        var info = stat()
        if fstatat(parent.descriptor,leaf,&info,AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw failure() }; return false
    }
    static func publish(_ files: [String:Data],to destination: UUID,in parent: SourceRenderDirectory) throws -> SourceRenderDirectory {
        guard !files.isEmpty, files.count <= 40, files["creative-claim.json"] == nil, files.keys.allSatisfy(validLeaf),
              files.values.allSatisfy({ !$0.isEmpty && $0.count <= 256*1024*1024 }),
              files.values.reduce(0,{ $0+$1.count }) <= 512*1024*1024 else { throw ProjectFailure.invalidProject }
        let name = destination.uuidString
        let claim = try encoder().encode(Claim(schemaVersion: 1,destination: name,files: files.mapValues(TranscriptSourceMap.sha)))
        try Task.checkCancellation(); try parent.checkPath()
        if try exists(name,in: parent) {
            let existing = try parent.child(name)
            guard try existing.read("creative-claim.json",limit: 16_384) == claim else { throw CutoutFailure.storageConflict }
            try finishCopy(files,into: existing)
            try parent.checkPath(); try existing.checkPath(); return existing
        }
        let pendingName = "pending-"+UUID().uuidString
        let pending = try parent.child(pendingName,create: true,exclusive: true)
        try pending.writeNew(claim,name: "creative-claim.json")
        for name in files.keys.sorted() { try Task.checkCancellation(); try pending.writeNew(files[name]!,name: name) }
        try pending.checkPath(); try parent.checkPath(); try Task.checkCancellation()
        if renameatx_np(parent.descriptor,pendingName,parent.descriptor,name,UInt32(RENAME_EXCL)) == 0 {
            let final = try parent.child(name)
            guard final.identity == pending.identity else { throw ProjectFailure.invalidProject }
            _ = fsync(parent.descriptor); try parent.checkPath(); try final.checkPath(); return final
        }
        guard errno == ENOTSUP else { throw failure() }
        // SMB does not support exclusive rename on every server. Reserve a new
        // folder and write its exact claim before copying any output bytes.
        let final = try parent.child(name,create: true,exclusive: true)
        try final.writeNew(claim,name: "creative-claim.json")
        try finishCopy(files,into: final)
        _ = fsync(parent.descriptor); try parent.checkPath(); try final.checkPath(); return final
    }
    private static func finishCopy(_ files: [String:Data],into directory: SourceRenderDirectory) throws {
        for name in files.keys.sorted() {
            try Task.checkCancellation(); try directory.checkPath()
            let bytes = files[name]!
            if try exists(name,in: directory) {
                guard try directory.read(name,limit: bytes.count) == bytes else { throw CutoutFailure.storageConflict }
            } else { try directory.writeNew(bytes,name: name) }
        }
        guard fsync(directory.descriptor) == 0 else { throw failure() }
    }
    static func validLeaf(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 100 && name != "." && name != ".." &&
        name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) })
    }
    private static func failure() -> WorkflowFailure {
        .invalid("The new asset could not be saved (storage error \(errno)). Its previous revisions are preserved; retry saving.")
    }
}
