import SwiftUI
import AVKit

struct StorageSetupView: View {
    @Bindable var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var page = "Locations"
    @State private var pendingTrash: StorageCacheItem?
    @State private var showTrash = false
    private var storage: StorageSetupController { store.storage }
    init(store: EditorStore,initialPage: String = "Locations") {
        self.store = store;_page = State(initialValue: initialPage)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading,spacing: 5) {
                    Text("Clauto Video storage").font(ClautoDesign.heading).accessibilityAddTraits(.isHeader)
                    Text("Choose where new work lives. Existing projects keep their current locations.").font(ClautoDesign.caption)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(storage.busy).keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker("Storage workspace",selection: $page) {
                ForEach(["Locations","Existing projects","Recoverable cache"],id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal,24).padding(.bottom,18).accessibilityIdentifier("storageWorkspaceTabs")
            ClautoRule()
            ScrollView {
                VStack(alignment: .leading,spacing: 22) {
                    if storage.busy {
                        HStack { ProgressView().controlSize(.small);Text("Storage operation in progress…");Spacer();Button("Cancel operation") { Task { await storage.cancel() } } }
                    }
                    if let error = storage.error { Text(error).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).accessibilityIdentifier("storageSetupError") }
                    if let message = storage.message { Text(message).font(ClautoDesign.caption).textSelection(.enabled).accessibilityIdentifier("storageSetupMessage") }
                    if page == "Locations" { locations }
                    else if page == "Existing projects" { migration }
                    else { cache }
                }.padding(24)
            }
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper)
            .frame(minWidth: 920,minHeight: 720).buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
            .interactiveDismissDisabled(storage.busy).task { await storage.refresh() }
            .confirmationDialog("Move this verified proxy to recoverable Trash?",isPresented: $showTrash,titleVisibility: .visible) {
                if let pendingTrash { Button("Move proxy to Trash",role: .destructive) { Task { await storage.trashCache(pendingTrash) } } }
                Button("Cancel",role: .cancel) { pendingTrash = nil }
            } message: { Text("Originals, saved cuts, active jobs and open/referenced proxies are excluded. Trash will not be emptied. APFS free-space recovery is not guaranteed.") }
    }
    private var locations: some View {
        VStack(alignment: .leading,spacing: 20) {
            GroupBox("Planning estimates") {
                VStack(alignment: .leading,spacing: 12) {
                    HStack { number("Originals (GiB)",\.originalsGiB);number("Footage (hours)",\.footageHours);number("Finished video (minutes)",\.finishedMinutes) }
                    HStack { number("Proxy bitrate (Mbps)",\.proxyMbps);number("Export bitrate (Mbps)",\.exportMbps);number("Minimum reserve (GiB)",\.minimumReserveGiB) }
                    HStack {
                        Text("Reserve percentage")
                        TextField("Reserve percentage",value: Binding(get: { storage.workload.reserveFraction*100 },set: { storage.workload.reserveFraction=$0/100 }),format: .number)
                            .frame(width: 85).textFieldStyle(.roundedBorder).accessibilityIdentifier("storageReservePercent")
                        Text("Capacity estimates include two export versions and proxy headroom. Authoritative run records and cuts remain with the edit project.").font(ClautoDesign.caption)
                    }
                }.padding(8)
            }.disabled(storage.busy)
            HStack {
                Button("Recommend locations") { Task { await storage.recommend() } }.accessibilityIdentifier("recommendStorage")
                Button("Use local rules") { Task { await storage.recommend(useConnectedAI: false) } }.accessibilityIdentifier("recommendLocalStorage")
                Spacer()
                Button("Refresh drive facts") { Task { await storage.refresh() } }.accessibilityIdentifier("refreshStorageVolumes")
            }.disabled(storage.busy)
            Text("Recommendations can use your existing connected Claude account for aggregate drive facts and footprint estimates. No names, paths or project files are sent. If unavailable, clearly labeled local rules provide the plan without a new service or sign-in.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            if let advice = storage.advice {
                VStack(alignment: .leading,spacing: 8) {
                    Text(advice.source == .connectedClaude ? "Connected Claude suggestion — review before applying":"Local recommendation rules").font(ClautoDesign.type(15,weight: .semibold)).accessibilityIdentifier("storageAdviceSource")
                    Text(advice.explanation).font(ClautoDesign.caption)
                    ForEach(advice.warnings,id: \.self) { Text($0).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
                }
            }
            ForEach(StorageRole.allCases) { role in StorageLocationRow(storage: storage,role: role) }
            HStack {
                Button("Review proposed locations") { Task { await storage.review() } }.disabled(storage.busy).accessibilityIdentifier("reviewStorageLocations")
                Spacer()
                if storage.reviewedProfile != nil {
                    Button("Confirm for future projects") { Task { if let root = await storage.confirmProfile() { store.setFolders(projects: root) } } }
                        .disabled(storage.busy).accessibilityIdentifier("confirmStorageLocations")
                }
            }
            if let reviewed = storage.reviewedProfile {
                GroupBox("Confirm these exact paths") {
                    VStack(alignment: .leading,spacing: 9) {
                        ForEach(StorageRole.allCases) { role in Text("\(role.label): \(reviewed.folders[role]?.displayPath ?? "Missing")").font(ClautoDesign.caption).textSelection(.enabled) }
                        Text("Creates app-owned folders for new projects, verified recording copies, source preview proxies, export delivery copies and backups. Existing media, current cuts and engine paths are unchanged. Originals outside a project are references in project backups and need their own independent backup.").font(ClautoDesign.caption)
                    }.padding(8)
                }.accessibilityIdentifier("storagePathReview")
            }
            if !storage.space.isEmpty {
                GroupBox("Live free-space monitoring") {
                    VStack(alignment: .leading,spacing: 8) {
                        ForEach(storage.space) { status in
                            Text("\(status.role.label): \(status.availableBytes.map(bytes) ?? "Offline") available · reserve \(bytes(status.reserveBytes))\(status.issue.map { " · "+$0 } ?? "")")
                                .font(ClautoDesign.caption).foregroundStyle(status.issue == nil ? ClautoDesign.ink:ClautoDesign.ember)
                        }
                        Text("Checked every 30 seconds while Clauto runs. New copies check current capacity again; a disconnected folder is retained and never replaced by a silent local fallback.").font(ClautoDesign.caption)
                    }.padding(8)
                }
            }
        }
    }
    private func number(_ label: String,_ key: WritableKeyPath<StorageWorkload,Double>) -> some View {
        VStack(alignment: .leading,spacing: 4) {
            Text(label).font(ClautoDesign.caption)
            TextField(label,value: Binding(get: { storage.workload[keyPath:key] },set: { storage.workload[keyPath:key]=$0 }),format: .number)
                .textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }.frame(maxWidth: .infinity)
    }
    private var migration: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Existing projects are never moved by a recommendation.").font(ClautoDesign.type(16,weight: .semibold))
            if let project = store.selected {
                Text(project.manifest.name).font(ClautoDesign.type(15,weight: .semibold))
                Text(project.folder.path).font(ClautoDesign.caption).textSelection(.enabled)
                if let layout = project.manifest.storageLayout {
                    ForEach(StorageRole.allCases) { role in Text("\(role.label): \(layout.folders[role] ?? "Not set")").font(ClautoDesign.caption).textSelection(.enabled) }
                } else { Text("Legacy project paths are retained. New global locations do not rewrite this project.").font(ClautoDesign.caption) }
                HStack {
                    Button("Plan project move…") { Task { if let folder = await FileDialogs.folder() { await storage.planCopy(project: project,destination: folder) } } }.accessibilityIdentifier("planStorageMigration")
                    Button("Plan project backup") { Task { if let folder = try? await storage.root(for: .backups,project: project) { await storage.planCopy(project: project,destination: folder,backup: true) } } }
                    if let version = store.currentCuts[project.id] {
                        Button("Copy current movie to Exports") { Task { await storage.copyMovie(project: project,version: version) } }
                    }
                }.disabled(storage.busy)
                Text("A move uses a new exclusive copy, SHA-256 readback, supported path relink, fresh disk reopen and user-checked playback before activation. Original and partial copies remain. Final Cut libraries and unresolved sealed legacy references are held for a dedicated supported workflow.").font(ClautoDesign.caption)
                if let plan = storage.copyPlan,plan.projectID == project.id,storage.journal == nil {
                    GroupBox("Review \(storage.copyPurpose) copy") {
                        VStack(alignment: .leading,spacing: 8) {
                            Text("From: "+plan.source.path).textSelection(.enabled)
                            Text("To: "+plan.destinationParent.appendingPathComponent("Clauto-copy-"+plan.id.uuidString+"/Project").path).textSelection(.enabled)
                            Text("\(plan.entries.count) entries · \(bytes(plan.totalBytes)) plus your reserve. External recording references are retained; this is not a full original-media backup.")
                            Button("Confirm copy to reviewed destination") { Task { await storage.confirmCopy(project: project) } }.disabled(storage.busy).accessibilityIdentifier("confirmStorageCopy")
                        }.font(ClautoDesign.caption).padding(8)
                    }
                }
                if let journal = storage.journal,journal.plan.projectID == project.id {
                    GroupBox("Copy status: \(journal.state.label)") {
                        VStack(alignment: .leading,spacing: 10) {
                            Text(journal.destination.path).textSelection(.enabled)
                            Text("Verified \(bytes(journal.copiedBytes)) · source retained")
                            if let failure = journal.failure { Text(failure).foregroundStyle(ClautoDesign.ember) }
                            ForEach(journal.unresolvedReferences,id: \.self) { Text($0).textSelection(.enabled) }
                            if journal.purpose == "migration" && journal.state == .copyVerified && journal.relinkedPathsSHA256 != nil {
                                Button("Reopen copied project from disk") { Task { await storage.reopenCopy() } }.disabled(storage.busy)
                            }
                            if journal.state == .reopened {
                                if let url = storage.playbackURL {
                                    StorageMoviePreview(url: url,onPlayed: { storage.observedPlaybackSeconds += $0 }).frame(height: 250)
                                    Text("Observed playback: \(storage.observedPlaybackSeconds,format: .number.precision(.fractionLength(1))) seconds")
                                } else { Text("No playable source or saved cut. Confirm that this is the expected empty project.") }
                                Toggle(journal.playbackSource == nil ? "I checked the reopened empty project":"I checked expected picture, audio, timing and content",isOn: Binding(get: { storage.humanCheckedPlayback },set: { storage.humanCheckedPlayback=$0 }))
                                Button("Confirm content check") { Task { await storage.confirmPlayback() } }.disabled(!storage.humanCheckedPlayback || (journal.playbackSource != nil && storage.observedPlaybackSeconds < 1) || storage.busy)
                            }
                            if journal.state == .playbackChecked { Button("Activate verified copy") { Task { await storage.activateCopy(original: project) } }.disabled(storage.busy).accessibilityIdentifier("activateStorageCopy") }
                            if journal.state != .rolledBack { Button(journal.state == .activated ? "Roll back to retained original":"Keep original / end this move") { Task { await storage.rollbackCopy(current: project) } }.disabled(storage.busy) }
                        }.font(ClautoDesign.caption).padding(8)
                    }
                }
                let history = storage.journalHistory.filter { $0.plan.projectID == project.id && $0.id != storage.journal?.id }
                ForEach(history) { record in Button("Review retained \(record.purpose) · \(record.state.label)") { storage.continueJournal(record) }.disabled(storage.busy) }
            } else { Text("Select an existing project to review its locations or prepare a copy.") }
        }
    }
    private var cache: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("Recoverable cache").font(ClautoDesign.type(16,weight: .semibold))
            Text("Only verified source preview proxies created by Clauto are listed. Originals, project state, saved cuts, engine/app files, active jobs and open or referenced proxies are excluded. Ordinary build/render folders are not treated as disposable cache.").font(ClautoDesign.caption)
            Button("Refresh managed proxies") { Task { await storage.refreshCache(project: store.selected) } }.disabled(storage.busy).accessibilityIdentifier("refreshManagedCache")
            if storage.cacheItems.isEmpty { Text("No verified managed proxies are available. Create a preview proxy from a recording in Files after confirming storage locations.").font(ClautoDesign.caption) }
            ForEach(storage.cacheItems) { item in
                HStack {
                    VStack(alignment: .leading,spacing: 5) {
                        Text(item.record.source.lastPathComponent).font(ClautoDesign.type(14,weight: .semibold))
                        Text(bytes(item.record.bytes)+(item.protectedReason.map { " · "+$0 } ?? " · Original verified again before cleanup")).font(ClautoDesign.caption)
                    }
                    Spacer()
                    Button("Preview") { storage.cachePreview = item.movie }.disabled(storage.busy)
                    Button("Move to Trash") { pendingTrash = item;showTrash = true }.disabled(item.protectedReason != nil || storage.cachePreview == item.movie || storage.busy)
                }
            }
            if let preview = storage.cachePreview {
                StorageMoviePreview(url: preview).id(preview).frame(height: 260)
                Button("Close proxy preview") { storage.cachePreview = nil }
            }
            ForEach(storage.trashReceipts) { receipt in
                VStack(alignment: .leading,spacing: 6) {
                    Text("Trashed proxy: "+receipt.record.source.lastPathComponent)
                    Text(receipt.warning).font(ClautoDesign.caption)
                    Text("Observed available capacity: \(bytes(receipt.observedFreeBefore)) → \(bytes(receipt.observedFreeAfter)). Other activity may affect this reading.").font(ClautoDesign.caption)
                    Button("Restore proxy from Trash") { Task { await storage.restoreCache(receipt) } }.disabled(storage.busy)
                }
            }
        }.onDisappear { storage.cachePreview = nil }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value,countStyle: .file) }
}

private struct StorageLocationRow: View {
    @Bindable var storage: StorageSetupController
    let role: StorageRole
    var body: some View {
        GroupBox(role.label) {
            VStack(alignment: .leading,spacing: 9) {
                HStack {
                    Picker("Drive for "+role.label,selection: Binding(get: { storage.advice?.choices[role] ?? "" },set: { storage.selectVolume($0,role: role) })) {
                        Text("Choose a drive").tag("")
                        if let selected = storage.advice?.choices[role],!storage.volumes.contains(where: { $0.id == selected }) { Text("Offline — reconnect saved folder").tag(selected) }
                        ForEach(storage.volumes) { volume in Text(volume.name+" · "+volume.filesystem+(volume.local ? " · local":" · network")+(volume.writable ? "":" · read-only")).tag(volume.id) }
                    }.accessibilityIdentifier("storageDrive-"+role.rawValue)
                    Button("Choose base folder…") { Task {
                        let volume = storage.volumes.first { $0.id == storage.advice?.choices[role] }
                        let initial = volume?.local == true && volume?.internalDevice == true ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies") : volume.map { URL(fileURLWithPath: $0.path) }
                        if let folder = await FileDialogs.folder(initial: initial) { await storage.choose(role: role,folder: folder) }
                    } }.accessibilityIdentifier("chooseStorageFolder-"+role.rawValue)
                }
                if let volume = storage.volumes.first(where: { $0.id == storage.advice?.choices[role] }) {
                    Text("\(ByteCountFormatter.string(fromByteCount: volume.availableBytes,countStyle: .file)) currently available · footprint estimate \(ByteCountFormatter.string(fromByteCount: storage.workload.bytes(for: role),countStyle: .file)) · reserve \(ByteCountFormatter.string(fromByteCount: storage.workload.reserve(on: volume),countStyle: .file))").font(ClautoDesign.caption)
                    Text(volume.performance.label+". "+volume.performance.explanation).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }
                Text(storage.folders[role]?.displayPath ?? "Choose an accessible base folder. Proposed child folders are created only after confirmation.").font(ClautoDesign.caption).textSelection(.enabled)
                if storage.folders[role] != nil { Button("Use this base for the other roles on this drive") { storage.reuseBase(from: role) }.font(ClautoDesign.caption) }
            }.padding(8)
        }.disabled(storage.busy)
    }
}

private struct StorageMoviePreview: View {
    let url: URL
    var onPlayed: (Double)->Void = { _ in }
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var lastClock = 0.0
    @State private var lastWall = Date()
    var body: some View {
        VideoPlayer(player: player).onAppear {
            let next = AVPlayer(url: url);player = next;lastClock = 0;lastWall = Date()
            observer = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25,preferredTimescale: 600),queue: .main) { clock in
                let wall = Date(),seconds = clock.seconds
                if next.rate > 0,seconds.isFinite {
                    let elapsed = max(0,min(seconds-lastClock,wall.timeIntervalSince(lastWall),1))
                    if elapsed > 0 { onPlayed(elapsed) }
                }
                lastClock = seconds;lastWall = wall
            }
        }.onDisappear { player?.pause();if let observer { player?.removeTimeObserver(observer) };observer = nil;player = nil }
    }
}
