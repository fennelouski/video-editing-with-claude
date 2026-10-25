import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SoundBrowserCore

/// Inject a project-owned store and an onSelection adapter when the main editor
/// is ready to admit cues. The standalone host only exposes the JSON handoff.
public struct SoundBrowserView: View {
    @Bindable private var store: SoundBrowserStore
    private let onSelection: ((SoundSelectionReference) -> Void)?
    private let selectionActionTitle: String?
    @State private var showLibrary = false
    @State private var showCollection = false
    @State private var collectionName = ""
    @State private var folderPicker = SoundLibraryPicker()
    @Environment(\.colorScheme) private var colorScheme

    public init(store: SoundBrowserStore, selectionActionTitle:String? = nil, onSelection: ((SoundSelectionReference) -> Void)? = nil) {
        self.store = store; self.onSelection = onSelection;self.selectionActionTitle=selectionActionTitle
    }
    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 195, idealWidth: 220, maxWidth: 245)
            VStack(spacing: 0) {
                header
                Divider()
                HSplitView {
                    results.frame(minWidth: 310, idealWidth: 520, maxHeight: .infinity, alignment: .top)
                    inspector.frame(minWidth: 280, idealWidth: 340, maxWidth: 380, maxHeight: .infinity, alignment: .top)
                }
                Divider()
                HStack {
                    Text(store.status).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel check") { store.cancelCheck() }
                    }
                }.padding(12)
            }
        }
        .tint(accent).background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 570)
        .sheet(isPresented: $showLibrary) { librarySheet }
        .sheet(isPresented: $showCollection) { collectionSheet }
        .alert("Sound browser", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } })) {
            Button("OK") { store.dismissError() }
        } message: { Text(store.error ?? "") }
        .onDisappear { store.stop() }
    }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.81, blue: 0.55) : Color(red: 0.24, green: 0.35, blue: 0.19) }
    private var sidebar: some View {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Label("CLAUTO", systemImage: "waveform").font(.system(.headline, design: .monospaced)).tracking(2).padding(.bottom, 16)
                Text("Sound library").font(.title2.weight(.semibold)).padding(.bottom, 12)
                nav("All sounds", symbol: "square.stack", count: store.catalog.assets.count,
                    selected: store.category == nil && !store.favoritesOnly && store.collectionID == nil && !store.availableOnly) { resetBrowse() }
                nav("Available offline", symbol: "externaldrive", count: store.availableCount, selected: store.availableOnly) { resetBrowse(); store.availableOnly = true }
                nav("Favorites", symbol: "star", count: store.favorites.count, selected: store.favoritesOnly) { resetBrowse(); store.favoritesOnly = true }
                sectionLabel("CATEGORIES")
                ForEach(store.catalog.categories, id: \.self) { category in
                    nav(category, symbol: "", count: nil, selected: store.category == category) { resetBrowse(); store.category = category }
                }
                HStack {
                    sectionLabel("COLLECTIONS")
                    Spacer()
                    Button { collectionName = ""; showCollection = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New collection").accessibilityLabel("New collection")
                }
                ForEach(store.collections) { collection in
                    nav(collection.name, symbol: "folder", count: collection.assetIDs.count, selected: store.collectionID == collection.id) { resetBrowse(); store.collectionID = collection.id }
                        .contextMenu { Button("Delete collection", role: .destructive) { store.removeCollection(collection.id) } }
                }
                if store.collections.isEmpty { Text("Gather sounds for a scene.").font(.caption).foregroundStyle(.secondary) }
            }.padding(18)
          }
          Divider()
          VStack(alignment: .leading,spacing: 7) {
                Button("Library setup…", systemImage: "externaldrive.badge.plus") { store.stop(); showLibrary = true }.accessibilityIdentifier("librarySetup")
                Text("Catalog \(store.catalog.version) · CC0\nAudio stored separately").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
          }.padding(18).frame(maxWidth: .infinity,alignment: .leading)
        }.background(colorScheme == .dark ? Color(red:0.14,green:0.16,blue:0.13) : Color(red:0.93,green:0.93,blue:0.90))
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 19).padding(.bottom, 3)
    }
    private func nav(_ title: String, symbol: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !symbol.isEmpty { Image(systemName: symbol).frame(width: 16).accessibilityHidden(true) }
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let count { Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? accent.opacity(0.16) : .clear, in: .rect(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func resetBrowse() { store.category = nil; store.tag = nil; store.collectionID = nil; store.favoritesOnly = false; store.availableOnly = false }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.category ?? (store.favoritesOnly ? "Favorites" : store.availableOnly ? "Available offline" : store.collections.first(where: { $0.id == store.collectionID })?.name ?? "All sounds")).font(.title2.weight(.semibold))
                    Text("\(store.visible.count) sounds · select visually, audition when ready").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { store.stop() }.disabled(store.playingID == nil).keyboardShortcut(".", modifiers: .command)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search titles, tags, creators or IDs", text: $store.query).textFieldStyle(.plain).accessibilityIdentifier("soundSearch")
                if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search") }
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if let tag = store.tag { Button("Tag: \(tag)  ×") { store.tag = nil }.controlSize(.small) }
        }.padding(18)
    }
    private var results: some View {
        VStack(spacing: 0) {
            HStack { Text("SOUND"); Spacer(); Text("ENVELOPE / DURATION") }.font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            if store.visible.isEmpty {
                ContentUnavailableView("No matching sounds", systemImage: "magnifyingglass", description: Text("Try a different search or category."))
                Button("Clear filters") { resetBrowse(); store.query = "" }.padding()
                Spacer()
            } else {
                SoundResultTable(rows:store.visible.map { asset in
                    .init(id:asset.id,title:asset.title+(store.favorites.contains(asset.id) ? "  ★" : ""),
                          subtitle:store.state(asset.id).state.rawValue,duration:String(format:"%.2f s",asset.duration),peaks:store.state(asset.id).envelope)
                },selection:store.selectedID,select:{ store.select($0) }).frame(maxHeight:.infinity).accessibilityIdentifier("soundResults")
            }
        }
    }
    private func drag(_ asset: SoundAsset) -> NSItemProvider {
        store.select(asset.id)
        guard let json = store.prepareSelection() else { return NSItemProvider() }
        let provider = NSItemProvider()
        let data = Data(json.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: "com.clauto.sound-reference", visibility: .all) { completion in completion(data,nil); return nil }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in completion(data,nil); return nil }
        provider.suggestedName = "\(asset.id).clauto-sound.json"
        return provider
    }
    @ViewBuilder private var inspector: some View {
        if let asset = store.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("SELECTED SOUND").font(.system(size: 10,weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.toggleFavorite(asset.id) } label: { Image(systemName: store.favorites.contains(asset.id) ? "star.fill" : "star") }
                            .help("Toggle favorite").accessibilityLabel(store.favorites.contains(asset.id) ? "Remove favorite" : "Favorite sound")
                    }
                    Text(asset.title).font(.title.weight(.semibold)).textSelection(.enabled)
                    Text(asset.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    SoundEnvelopeView(peaks: store.state(asset.id).envelope, color: accent).frame(height: 100)
                    HStack { Text(asset.duration, format: .number.precision(.fractionLength(2))) + Text(" s"); Spacer(); Text(asset.format.uppercased()) }.font(.headline.monospacedDigit())
                    Label(store.state(asset.id).state.rawValue, systemImage: store.state(asset.id).state == .available ? "checkmark.circle" : "externaldrive.badge.questionmark").font(.callout)
                    if !store.state(asset.id).message.isEmpty { Text(store.state(asset.id).message).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(store.playingID == asset.id ? "Restart audition" : "Audition", systemImage: "play.fill") { store.auditionSelected() }
                            .disabled(store.state(asset.id).state != .available || store.busy).accessibilityIdentifier("auditionSound")
                        Button("Stop", systemImage: "stop.fill") { store.stop() }.disabled(store.playingID == nil)
                    }
                    HStack {
                        Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                        Slider(value: $store.volume, in: 0...1) { Text("Audition volume") }.accessibilityIdentifier("auditionVolume")
                        Text("\(Int(store.volume*100))%").font(.caption.monospacedDigit()).frame(width: 34)
                    }
                    Text("Not auditioned or approved by a person").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button(selectionActionTitle ?? (onSelection == nil ? "Prepare selection" : "Use selection"), systemImage: "arrow.down.to.line") {
                        guard store.prepareSelection() != nil else { return }
                        if let onSelection, let ref = try? store.selectionReference() { onSelection(ref) }
                    }.buttonStyle(.borderedProminent).disabled(store.state(asset.id).state != .available || store.busy).accessibilityIdentifier("prepareSelection")
                    Text(onSelection == nil ? "Drag a sound or prepare its portable reference." : "Apply this sound to the selected timeline cue.").font(.caption).foregroundStyle(.secondary)
                    if store.state(asset.id).state == .available {
                        Label("Drag selected sound",systemImage:"hand.draw")
                            .font(.caption).padding(7)
                            .background(Color(nsColor:.controlBackgroundColor),in:.rect(cornerRadius:5))
                            .onDrag { drag(asset) }
                            .help("Drag this verified sound reference to a compatible timeline")
                    }
                    if let json = store.exportedReference {
                        DisclosureGroup("Selection reference ready") {
                            Text(json).font(.system(size: 10,design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Button("Copy reference") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(json, forType: .string) }
                                Button("Save…") { saveReference(json, asset: asset) }
                            }
                        }
                    }
                    Menu("Add to collection") {
                        ForEach(store.collections) { collection in
                            Button((collection.assetIDs.contains(asset.id) ? "✓ " : "") + collection.name) { store.toggleMembership(assetID: asset.id, collectionID: collection.id) }
                        }
                        Button("New collection…") { collectionName = ""; showCollection = true }
                    }
                    Divider()
                    Text("TAGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    FlowTags(tags: asset.tags) { store.tag = $0 }
                    Text(asset.formatLabel).font(.caption)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(asset.bytes), countStyle: .file)).font(.caption)
                    Text("\(asset.license) · \(asset.creator)").font(.caption).textSelection(.enabled)
                    HStack { Link("Source", destination: URL(string: asset.sourceURL)!); Link("License", destination: URL(string: asset.licenseURL)!) }.font(.caption)
                    if !asset.note.isEmpty { Text(asset.note).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Original hash") { Text(asset.sha256).font(.caption2.monospaced()).textSelection(.enabled) }
                    if store.state(asset.id).state != .available {
                        Button("Link or relink library…") { showLibrary = true }
                    }
                }.padding(20)
            }.background(Color(nsColor: .textBackgroundColor))
        } else { ContentUnavailableView("Choose a sound", systemImage: "waveform", description: Text("Select a row to inspect its envelope, source and availability.")).frame(maxWidth:.infinity,maxHeight:.infinity) }
    }
    private var librarySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Separate sound library").font(.title2.weight(.semibold)); Spacer(); Button("Done") { showLibrary = false } }
            Text("Link a package root containing its audio folder. Clauto reads and verifies known files; originals stay in your chosen folder.").foregroundStyle(.secondary)
            Button("Link library folder…", systemImage: "folder.badge.plus") { chooseFolder() }.disabled(folderPicker.isPresented).accessibilityIdentifier("linkLibraryFolder")
            if store.mounts.isEmpty { Text("No folders linked. All \(store.catalog.assets.count.formatted()) references remain searchable.").font(.callout) }
            ForEach(store.mounts) { mount in
                HStack { Image(systemName: "externaldrive"); Text(mount.name).lineLimit(2); Spacer(); Button("Disconnect") { store.unlink(mount.id) } }
            }
            HStack {
                Button("Check again") { Task { await store.recheck() } }.disabled(store.busy || store.mounts.isEmpty)
                if store.busy { ProgressView().controlSize(.small); Button("Cancel check") { store.cancelCheck() } }
            }
            Divider()
            Text("Optional collections").font(.headline)
            Text("Acquire only the collections you choose from their original providers, then link the extracted folder. This build has no network downloader.").font(.callout).foregroundStyle(.secondary)
            Text("No automatic downloads · No bundled audio · Offline after linking").font(.caption)
        }.padding(26).frame(width: 560).fixedSize(horizontal: false, vertical: true)
    }
    private func chooseFolder() {
        Task { await folderPicker.choose(store:store) }
    }
    private var collectionSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New collection").font(.title2.weight(.semibold))
            TextField("Collection name", text: $collectionName).onSubmit { addCollection() }
            HStack { Button("Cancel") { showCollection = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Create") { addCollection() }.disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 380)
    }
    private func addCollection() {
        if let id = store.createCollection(collectionName) {
            if let asset = store.selected { store.addToCollection(assetID: asset.id, collectionID: id) }
            showCollection = false
        }
    }
    private func saveReference(_ json: String, asset: SoundAsset) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(asset.id).clauto-sound.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(json.utf8).write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

private struct SoundResultRow: View {
    let asset: SoundAsset
    let inspection: AssetInspection
    let favorite: Bool
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(asset.title).font(.body.weight(.medium)); if favorite { Image(systemName: "star.fill").font(.caption).accessibilityLabel("Favorite") } }
                Text(inspection.state.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            SoundEnvelopeView(peaks: inspection.envelope, color: .primary).frame(width: 86, height: 30)
            Text(String(format: "%.2f s",asset.duration)).font(.caption.monospacedDigit()).frame(width: 59,alignment: .trailing)
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
            .accessibilityLabel("\(asset.title), \(String(format: "%.2f",asset.duration)) seconds, \(inspection.state.rawValue)")
    }
}

public struct SoundEnvelopeView: View {
    public let peaks: [Float]
    public let color: Color
    public init(peaks: [Float], color: Color) { self.peaks = peaks; self.color = color }
    public var body: some View {
        GeometryReader { geometry in
            if peaks.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "waveform.slash").font(.caption)
                    if geometry.size.height > 50 { Text("Preview after linking").font(.caption) }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    var p = Path()
                    for (index, value) in peaks.enumerated() {
                        let x = (CGFloat(index)+0.5)*size.width/CGFloat(peaks.count)
                        let height = max(1,CGFloat(value)*size.height*0.9)
                        p.move(to: CGPoint(x:x,y:(size.height-height)/2)); p.addLine(to: CGPoint(x:x,y:(size.height+height)/2))
                    }
                    context.stroke(p,with: .color(color),lineWidth: max(1,size.width/CGFloat(peaks.count)*0.65))
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(peaks.isEmpty ? "Envelope unavailable until linked" : "Measured peak envelope from original WAV samples")
    }
}
private struct FlowTags: View {
    let tags: [String]
    let select: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82),alignment: .leading)],alignment: .leading,spacing: 6) {
            ForEach(tags,id: \.self) { tag in Button(tag) { select(tag) }.buttonStyle(.bordered).controlSize(.small) }
        }
    }
}
