import Foundation
import Darwin

struct StorageCacheRecord: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var rootID: UUID
    var kind = "source-preview-proxy"
    var source: URL
    var sourceSHA256: String
    var bytes: Int64
    var payloadSHA256: String
    var created: Date
    var filename = "proxy.mp4"
    static func == (a: Self,b: Self) -> Bool {
        a.schemaVersion == b.schemaVersion && a.id == b.id && a.rootID == b.rootID && a.kind == b.kind && a.source == b.source && a.sourceSHA256 == b.sourceSHA256 && a.bytes == b.bytes && a.payloadSHA256 == b.payloadSHA256 && a.filename == b.filename
    }
}
struct StorageCacheItem: Identifiable, Sendable {
    var record: StorageCacheRecord
    var folder: URL
    var protectedReason: String?
    var id: UUID { record.id }
    var movie: URL { folder.appendingPathComponent(record.filename) }
}
struct StorageCacheTrashReceipt: Codable, Identifiable, Sendable {
    var id: UUID
    var original: URL
    var trash: URL
    var record: StorageCacheRecord
    var observedFreeBefore: Int64
    var observedFreeAfter: Int64
    var warning = "Trash remains recoverable. APFS shared extents, snapshots and other activity mean this is not a guaranteed reclaim amount. Trash is never emptied by Clauto."
}

actor StorageCacheService {
    private var active = Set<UUID>()
    private let storage = StorageWorkspaceService()
    private let runner: any CommandRunning
    private let defaults: UserDefaults?
    private var trusted: [UUID:StorageCacheRecord] = [:]
    init(runner: any CommandRunning = ProcessRunner(),defaults: UserDefaults? = .standard,trustedRecords: [StorageCacheRecord]? = nil) {
        self.runner = runner;self.defaults = defaults
        let records = trustedRecords ?? defaults?.data(forKey: "ClautoManagedCacheRecords").flatMap { try? JSONDecoder().decode([StorageCacheRecord].self,from: $0) } ?? []
        for record in records { trusted[record.id] = record }
    }
    func createProxy(source: URL,rootURL: URL,reserve: Int64,bitrateMbps: Double = 12) async throws -> StorageCacheItem {
        let root = try SourceRenderDirectory.open(rootURL)
        let marker = try await storage.managedRoot(root,role: .cache)
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        guard ["mov","mp4","m4v"].contains(source.pathExtension.lowercased()),let ffmpeg = ProcessRunner.executable("ffmpeg") else { throw WorkflowFailure.invalid("Source preview proxies need an available movie and the installed ffmpeg tool.") }
        guard bitrateMbps.isFinite,(1...500).contains(bitrateMbps),reserve >= 0,let probe = ProcessRunner.executable("ffprobe") else { throw WorkflowFailure.invalid("Proxy verification needs a valid bitrate and installed ffprobe.") }
        let durationResult = try await runner.run(.init(executable: probe,arguments: ["-v","error","-show_entries","format=duration","-of","json",source.path],timeout: .seconds(30)),onLine: nil)
        let metadata = try JSONSerialization.jsonObject(with: Data(durationResult.output.utf8)) as? [String:Any]
        guard durationResult.succeeded,let format = metadata?["format"] as? [String:Any],let raw = format["duration"] as? String,let duration = Double(raw),duration.isFinite,duration > 0,duration < 36_000_000 else { throw WorkflowFailure.invalid("Source duration could not be checked before proxy creation.") }
        let estimate = Int64(min(Double(Int64.max / 4),duration*(bitrateMbps+0.128)*1_000_000/8*1.25+Double(StorageWorkload.gib)))
        let volume = try StorageVolumeProbe.observe(root.url)
        guard volume.availableBytes - estimate >= reserve else { throw WorkflowFailure.invalid("Keep at least the reserve plus 1 GiB free before creating a proxy.") }
        let id = UUID(), parent = try root.child("items",create: true), folder = try parent.child(id.uuidString,create: true,exclusive: true)
        active.insert(id); defer { active.remove(id) }
        let input = try SourceRenderDirectory.open(source.deletingLastPathComponent())
        let before = try input.voiceHash(source.lastPathComponent,limit: Int64.max / 4)
        let output = folder.url.appendingPathComponent("proxy.mp4")
        let reserveWatch = Task { [runner] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5));try Task.checkCancellation()
                    let remaining = try StorageVolumeProbe.observe(root.url).availableBytes
                    try Task.checkCancellation()
                    guard remaining >= reserve else { await runner.cancel();return }
                } catch is CancellationError { return }
                catch { if !Task.isCancelled { await runner.cancel() };return }
            }
        }
        defer { reserveWatch.cancel() }
        let result = try await runner.run(.init(executable: ffmpeg,arguments: ["-nostdin","-hide_banner","-v","error","-n","-threads","2","-filter_threads","1","-i",source.path,
            "-map","0:v:0","-map","0:a:0?","-vf","scale=1280:-2:force_original_aspect_ratio=decrease","-c:v","libx264","-preset","veryfast","-crf","24","-maxrate",String(bitrateMbps)+"M","-bufsize",String(bitrateMbps*2)+"M","-c:a","aac","-b:a","128k","-movflags","+faststart",output.path],timeout: .seconds(1800)),onLine: nil)
        try Task.checkCancellation()
        guard result.succeeded,!result.cancelled,try input.voiceHash(source.lastPathComponent,limit: Int64.max / 4) == before else { throw WorkflowFailure.invalid("Proxy creation stopped or source bytes changed. Partial output is retained outside the recoverable cache list.") }
        reserveWatch.cancel();await reserveWatch.value
        let checked = try await runner.run(.init(executable: probe,arguments: ["-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","json",output.path],timeout: .seconds(30)),onLine: nil)
        guard checked.succeeded, let object = try JSONSerialization.jsonObject(with: Data(checked.output.utf8)) as? [String:Any],let streams = object["streams"] as? [[String:Any]],streams.count == 1,
              let width = streams[0]["width"] as? Int,width > 0,width <= 1280 else { throw WorkflowFailure.invalid("Proxy decode metadata could not be verified.") }
        let sha = try folder.voiceHash("proxy.mp4",limit: Int64.max / 4)
        var info = stat(); guard fstatat(folder.descriptor,"proxy.mp4",&info,AT_SYMLINK_NOFOLLOW) == 0,info.st_size > 0 else { throw ProjectFailure.invalidProject }
        let record = StorageCacheRecord(id: id,rootID: marker.id,source: source,sourceSHA256: before,bytes: info.st_size,payloadSHA256: sha,created: Date())
        try folder.writeNew(CreativeAssetFiles.encoder().encode(record),name: "cache-record.json")
        trusted[id] = record
        defaults?.set(try JSONEncoder().encode(Array(trusted.values)),forKey: "ClautoManagedCacheRecords")
        try root.checkPath();try folder.checkPath()
        return .init(record: record,folder: folder.url)
    }
    func cancel() async { await runner.cancel() }
    private func checked(_ folder: SourceRenderDirectory,marker: StorageManagedRoot,expectedID: UUID? = nil) throws -> StorageCacheRecord {
        let record = try CreativeAssetFiles.decode(folder.read("cache-record.json",limit: 16_384),as: StorageCacheRecord.self)
        guard record.schemaVersion == 1,trusted[record.id] == record,record.rootID == marker.id,(expectedID.map { $0 == record.id } ?? (record.id.uuidString == folder.url.lastPathComponent)),
              record.kind == "source-preview-proxy",record.filename == "proxy.mp4",record.bytes > 0,
              Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path)) == ["proxy.mp4","cache-record.json"],
              try folder.voiceHash(record.filename,limit: record.bytes) == record.payloadSHA256 else { throw WorkflowFailure.invalid("This cache item changed or is not an owned, verified proxy. It is excluded from cleanup.") }
        return record
    }
    func scan(rootURL: URL,protected: [URL]) async throws -> [StorageCacheItem] {
        let root = try SourceRenderDirectory.open(rootURL),marker = try await storage.managedRoot(root,role: .cache)
        guard try CreativeAssetFiles.exists("items",in: root) else { return [] }
        let parent = try root.child("items")
        var result: [StorageCacheItem] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.url.path).sorted() {
            try Task.checkCancellation()
            guard UUID(uuidString: name) != nil,let folder = try? parent.child(name),let record = try? checked(folder,marker: marker) else { continue }
            let payload = folder.url.appendingPathComponent(record.filename).path
            let used = protected.contains { url in
                let p = url.resolvingSymlinksInPath().standardizedFileURL.path
                return p == payload || payload.hasPrefix(p+"/") || p.hasPrefix(folder.url.path+"/")
            }
            result.append(.init(record: record,folder: folder.url,protectedReason: active.contains(record.id) ? "Active cache job" : used ? "Open preview or referenced project input" : nil))
        }
        return result
    }
    func trash(_ item: StorageCacheItem,rootURL: URL,protected: [URL],
               move: @Sendable (URL) throws -> URL = { url in
                   var result: NSURL?; try FileManager.default.trashItem(at: url,resultingItemURL: &result)
                   guard let result else { throw ProjectFailure.invalidProject }; return result as URL
               }) async throws -> StorageCacheTrashReceipt {
        let root = try SourceRenderDirectory.open(rootURL),marker = try await storage.managedRoot(root,role: .cache)
        let volume = try StorageVolumeProbe.observe(root.url)
        guard volume.local else { throw WorkflowFailure.invalid("Recoverable Trash cleanup is enabled only for local managed cache. No permanent-delete fallback exists.") }
        let current = try await scan(rootURL: rootURL,protected: protected)
        guard let entry = current.first(where: { $0.id == item.id }),entry.protectedReason == nil,!active.contains(item.id),entry.record == item.record else { throw WorkflowFailure.invalid("This proxy is active, referenced or changed. It was excluded from cleanup.") }
        let original = item.record.source.resolvingSymlinksInPath().standardizedFileURL
        guard let source = try? SourceRenderDirectory.open(original.deletingLastPathComponent()),
              (try? source.voiceHash(original.lastPathComponent,limit: Int64.max / 4)) == item.record.sourceSHA256 else {
            throw WorkflowFailure.invalid("The original is unavailable or changed. This proxy cannot currently be regenerated, so it was retained.")
        }
        let parent = try root.child("items"),folder = try parent.child(item.id.uuidString)
        _ = try checked(folder,marker: marker)
        active.insert(item.id);defer { active.remove(item.id) }
        try folder.checkPath();try parent.checkPath()
        let result = try move(folder.url)
        return .init(id: UUID(),original: folder.url,trash: result,record: item.record,observedFreeBefore: volume.availableBytes,observedFreeAfter: (try? StorageVolumeProbe.observe(root.url).availableBytes) ?? volume.availableBytes)
    }
    func restore(_ receipt: StorageCacheTrashReceipt,rootURL: URL) async throws {
        let root = try SourceRenderDirectory.open(rootURL),marker = try await storage.managedRoot(root,role: .cache),parent = try root.child("items")
        guard receipt.original.standardizedFileURL.path == parent.url.appendingPathComponent(receipt.record.id.uuidString).path,!(try CreativeAssetFiles.exists(receipt.record.id.uuidString,in: parent)) else { throw WorkflowFailure.invalid("The original proxy location is occupied or changed. Both items were retained.") }
        let trashed = try SourceRenderDirectory.open(receipt.trash)
        guard try checked(trashed,marker: marker,expectedID: receipt.record.id) == receipt.record else { throw ProjectFailure.invalidProject }
        try FileManager.default.moveItem(at: receipt.trash,to: receipt.original)
    }
}
