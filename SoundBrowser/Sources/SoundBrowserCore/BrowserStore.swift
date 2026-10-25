import Foundation
import Observation

public struct SoundCollection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var assetIDs: Set<String>
    public init(name: String) { id = UUID(); self.name = name; assetIDs = [] }
}
public struct LibraryMount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let bookmark: Data
}
private struct BrowserPreferences: Codable {
    var schemaVersion = 1
    var favorites: Set<String> = []
    var collections: [SoundCollection] = []
    var mounts: [LibraryMount] = []
}

@Observable @MainActor public final class SoundBrowserStore {
    public let catalog: SoundCatalog
    public var query = ""
    public var category: String?
    public var tag: String?
    public var favoritesOnly = false
    public var collectionID: UUID?
    public var availableOnly = false
    public private(set) var selectedID: String?
    public private(set) var favorites: Set<String> = []
    public private(set) var collections: [SoundCollection] = []
    public private(set) var mounts: [LibraryMount] = []
    public private(set) var inspections: [String: AssetInspection] = [:]
    public private(set) var busy = false
    public private(set) var status = "Link a separate library folder to preview sounds."
    public private(set) var error: String?
    public private(set) var playingID: String?
    public private(set) var exportedReference: String?
    public var volume: Double = 0.15 { didSet { volume = min(1,max(0,volume.isFinite ? volume : 0)); player.setVolume(Float(volume)) } }
    @ObservationIgnored private let preferencesURL: URL
    @ObservationIgnored private let player: any SoundPlaying
    @ObservationIgnored private var roots: [UUID: URL] = [:]
    @ObservationIgnored private var assetMount: [String: UUID] = [:]
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playbackGeneration = UUID()

    public init(catalog: SoundCatalog, preferencesURL: URL, player: (any SoundPlaying)? = nil) {
        self.catalog = catalog; self.preferencesURL = preferencesURL; self.player = player ?? NativeSoundPlayer()
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(BrowserPreferences.self, from: Data(contentsOf: preferencesURL))
            guard saved.schemaVersion == 1 else { throw SoundFailure.invalid("Unsupported saved browser settings.") }
            favorites = saved.favorites; collections = saved.collections; mounts = saved.mounts
            for mount in mounts {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: mount.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale), !stale {
                    _ = url.startAccessingSecurityScopedResource(); roots[mount.id] = url
                }
            }
        } catch { self.error = "Saved browser settings could not be read. \(error.localizedDescription)" }
    }

    public var selected: SoundAsset? { catalog.asset(selectedID) }
    public var availableCount: Int { inspections.values.filter { $0.state == .available }.count }
    public var visible: [SoundAsset] {
        let ids: Set<String>?
        if let collectionID, let collection = collections.first(where: { $0.id == collectionID }) { ids = collection.assetIDs }
        else { ids = favoritesOnly ? favorites : nil }
        return catalog.search(text: query, category: category, tag: tag, ids: ids)
            .filter { !availableOnly || state($0.id).state == .available }
    }
    public func state(_ id: String) -> AssetInspection {
        inspections[id] ?? .init(mounts.isEmpty ? .notLinked : .missing)
    }
    public func select(_ id: String?) {
        guard id != selectedID else { return }
        stop(); selectedID = catalog.asset(id)?.id; exportedReference = nil
    }
    public func toggleFavorite(_ id: String) {
        guard catalog.asset(id) != nil else { return }
        if !favorites.insert(id).inserted { favorites.remove(id) }; persist()
    }
    @discardableResult public func createCollection(_ name: String) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { error = "Name the collection using 1–80 characters."; return nil }
        if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { return existing.id }
        let c = SoundCollection(name: clean); collections.append(c); persist(); return c.id
    }
    public func toggleMembership(assetID: String, collectionID: UUID) {
        guard catalog.asset(assetID) != nil, let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if !collections[index].assetIDs.insert(assetID).inserted { collections[index].assetIDs.remove(assetID) }; persist()
    }
    public func addToCollection(assetID: String, collectionID: UUID) {
        guard catalog.asset(assetID) != nil, let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[index].assetIDs.insert(assetID).inserted { persist() }
    }
    public func removeCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }; if collectionID == id { collectionID = nil }; persist()
    }
    public func dismissError() { error = nil }

    /// Each folder is explicitly selected. Known catalog paths only; no recursive
    /// discovery and no automatic downloads or writes to the chosen library.
    public func link(_ url: URL) async {
        guard url.isFileURL else { error = "Choose a local library folder."; return }
        stop(); cancelCheck()
        let canonical = url.standardizedFileURL
        if roots.values.contains(where: { $0.standardizedFileURL == canonical }) { await recheck(); return }
        do {
            let bookmark = try canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let mount = LibraryMount(id: UUID(), name: url.lastPathComponent, bookmark: bookmark)
            _ = canonical.startAccessingSecurityScopedResource(); roots[mount.id] = canonical
            mounts.append(mount); persist(); await recheck()
        } catch { self.error = "Could not link this folder. \(error.localizedDescription)" }
    }
    public func unlink(_ id: UUID) {
        stop(); cancelCheck(); roots.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        mounts.removeAll { $0.id == id }
        let removed = assetMount.filter { $0.value == id }.map(\.key)
        for assetID in removed { inspections.removeValue(forKey:assetID); assetMount.removeValue(forKey:assetID) }
        persist()
        status = "Folder disconnected. References and favorites are preserved."
    }
    public func cancelCheck() {
        generation = UUID(); work?.cancel(); work = nil; busy = false
        status = "Check cancelled. Check again to refresh offline availability."
    }
    public func recheck() async {
        stop(); cancelCheck()
        let token = UUID(); generation = token; busy = true; status = "Checking local hashes and WAV previews…"
        let assets = catalog.assets, mounts = self.mounts, roots = self.roots
        let task = Task.detached(priority: .utility) { () -> ([String:AssetInspection],[String:UUID]) in
            var found: [String:AssetInspection] = [:], owners: [String:UUID] = [:]
            for asset in assets {
                if Task.isCancelled { break }
                var best = AssetInspection(mounts.isEmpty ? .notLinked : .missing)
                for mount in mounts {
                    guard let root = roots[mount.id] else { continue }
                    let result = LibraryFiles.inspect(asset: asset, root: root)
                    if result.state == .available { best = result; owners[asset.id] = mount.id; break }
                    if result.state != .missing { best = result }
                }
                found[asset.id] = best
            }
            return (found,owners)
        }
        work = Task { [weak self] in
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.inspections = result.0; self.assetMount = result.1; self.busy = false
            self.status = "\(self.availableCount) available offline · \(self.catalog.assets.count) indexed · no downloads"
        }
        await work?.value
    }
    public func stop() { playbackGeneration = UUID(); player.stop(); playingID = nil }
    public func auditionSelected() {
        guard let asset = selected else { return }
        stop()
        do {
            let data = try checkedData(asset)
            let token = UUID(); playbackGeneration = token
            try player.start(data: data, volume: Float(volume)) { [weak self] in
                guard let self, self.playbackGeneration == token else { return }; self.playingID = nil
            }
            playingID = asset.id
        } catch { self.error = error.localizedDescription }
    }
    public func selectionReference() throws -> SoundSelectionReference {
        guard let asset = selected else { throw SoundFailure.invalid("Select a sound first.") }
        _ = try checkedData(asset)
        return .init(catalog: catalog, asset: asset)
    }
    @discardableResult public func prepareSelection() -> String? {
        do { let value = try selectionReference().json(); exportedReference = value; return value }
        catch { self.error = error.localizedDescription; return nil }
    }
    private func checkedData(_ asset: SoundAsset) throws -> Data {
        guard state(asset.id).state == .available, let mountID = assetMount[asset.id], let root = roots[mountID] else {
            throw SoundFailure.invalid("Sound unavailable. Link its library folder and check again.")
        }
        do {
            // Availability already decoded this exact catalog hash. Re-hashing
            // the immutable snapshot is sufficient and avoids decoding every
            // sample again on the main actor for selection or audition.
            let data = try LibraryFiles.verifiedData(asset: asset, root: root)
            return data
        } catch {
            inspections[asset.id] = .init(.unreadable, message: error.localizedDescription)
            assetMount.removeValue(forKey: asset.id)
            throw error
        }
    }
    private func persist() {
        do {
            let value = BrowserPreferences(favorites: favorites, collections: collections, mounts: mounts)
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
        } catch { self.error = "Browser settings were not saved. \(error.localizedDescription)" }
    }
}
