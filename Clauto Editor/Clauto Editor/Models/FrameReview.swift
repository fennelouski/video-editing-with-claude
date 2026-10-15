import Foundation
import CoreGraphics
import CryptoKit

struct ReviewClockTime: Codable, Equatable, Sendable {
    let value: Int64
    let timescale: Int32
}
struct ReviewFrameAnchor: Codable, Equatable, Sendable {
    let clock: ReviewClockTime
    let frameIndex: Int
    let frameCount: Int
    var presentationValue: Int64 { Int64(frameIndex)*1001 }
    var presentationTimescale: Int32 { 24000 }
    var seconds: Double { Double(presentationValue)/24000 }
    static func capture(_ clock: ReviewClockTime, duration: Double) throws -> Self {
        let count = duration*24000/1001
        guard clock.value >= 0, clock.timescale > 0, count.isFinite, count >= 1, count <= 86_400,
              abs(count-count.rounded()) < 0.002 else { throw WorkflowFailure.invalid("Choose a ready saved 24000/1001 version before adding a frame comment.") }
        let (numerator,overflow) = clock.value.multipliedReportingOverflow(by: 24000)
        guard !overflow else { throw ProjectFailure.invalidProject }
        let denominator = Int64(clock.timescale)*1001, frames = Int(count.rounded())
        let at = Double(clock.value)/Double(clock.timescale)
        guard at.isFinite, at <= duration+0.001 else { throw WorkflowFailure.invalid("The playback clock is outside the selected saved version.") }
        return .init(clock: clock,frameIndex: min(frames-1,Int(numerator/denominator)),frameCount: frames)
    }
    func validate(duration: Double) throws {
        guard try Self.capture(clock,duration: duration) == self else { throw ProjectFailure.invalidProject }
    }
}
struct FrameCommentRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let target: VoiceReviewTarget
    let frame: ReviewFrameAnchor
}
struct NormalizedVideoRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x+width <= 1.000000001, y+height <= 1.000000001 else { throw WorkflowFailure.invalid("Draw inside the video or enter finite bounds between zero and one.") }
    }
}
enum FrameAnnotationKind: String, Codable, CaseIterable, Sendable {
    case ellipse, circle, highlight, freehand
    var label: String { switch self { case .ellipse: "Ellipse"; case .circle: "Circle"; case .highlight: "Highlight"; case .freehand: "Draw" } }
}
struct NormalizedVideoPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw ProjectFailure.invalidProject }
    }
}
/// A closed drawing is still a drag. Final displacement alone loses loops.
struct FrameMarkGesture: Sendable {
    let start: CGPoint
    private(set) var moved = false
    mutating func observe(_ point: CGPoint) {
        if !point.x.isFinite || !point.y.isFinite || hypot(point.x-start.x,point.y-start.y) >= 3 { moved = true }
    }
    var isClick: Bool { !moved }
}
enum FrameMarkClickAction: Equatable, Sendable {
    case select(UUID?), acceptPerson(UUID), newPin
    static func resolve(existing: UUID?,proposal: UUID?,selecting: Bool) -> Self {
        if let existing { return .select(existing) }
        if selecting { return .select(nil) }
        if let proposal { return .acceptPerson(proposal) }
        return .newPin
    }
}
struct FrameEllipse: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: FrameAnnotationKind
    let bounds: NormalizedVideoRect
    var points: [NormalizedVideoPoint]? = nil
    var tag: String? = nil
    var note: String? = nil
    var person: ProjectPersonReference? = nil
    var mentions: [FramePersonMention]? = nil
    func validate(width: Int, height: Int) throws {
        try bounds.validate()
        guard width > 0, height > 0, bounds.width*Double(width) >= 1, bounds.height*Double(height) >= 1,
              kind != .circle || abs(bounds.width*Double(width)-bounds.height*Double(height)) <= 0.01 else { throw WorkflowFailure.invalid("A circle must have equal width and height in the captured video, with at least one pixel on each axis.") }
        if kind == .freehand {
            guard let points, (2...512).contains(points.count) else { throw WorkflowFailure.invalid("A drawing needs between two and 512 points.") }
            for point in points {
                try point.validate()
                guard point.x >= bounds.x-1e-9, point.y >= bounds.y-1e-9,
                      point.x <= bounds.x+bounds.width+1e-9, point.y <= bounds.y+bounds.height+1e-9 else { throw ProjectFailure.invalidProject }
            }
        } else if points != nil { throw ProjectFailure.invalidProject }
        if let tag { guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tag.utf8.count <= 160,
            !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WorkflowFailure.invalid("Use a short label for this region.") } }
        if let note { guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count <= 4096 else { throw WorkflowFailure.invalid("A region note must contain up to 4096 UTF-8 bytes.") } }
        if let mentions {
            guard !mentions.isEmpty, mentions.count <= 32, Set(mentions.map(\.id)).count == mentions.count, let note else { throw ProjectFailure.invalidProject }
            var end = 0
            for mention in mentions {
                try mention.validate(note: note)
                guard mention.utf16Start >= end else { throw ProjectFailure.invalidProject }
                end = mention.utf16Start + mention.utf16Length
            }
        }
    }
}
enum VideoAnnotationGeometry {
    static func normalize(_ point: CGPoint,video: CGRect) -> NormalizedVideoPoint? {
        guard point.x.isFinite, point.y.isFinite, [video.minX,video.minY,video.width,video.height].allSatisfy(\.isFinite), video.width > 0, video.height > 0 else { return nil }
        return .init(x: min(1,max(0,(point.x-video.minX)/video.width)),y: min(1,max(0,(point.y-video.minY)/video.height)))
    }
    static func stroke(_ points: [CGPoint],video: CGRect,image: CGSize,id: UUID = UUID()) -> FrameEllipse? {
        guard (2...512).contains(points.count), let first = points.first, video.contains(first),
              [image.width,image.height].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 7680 }) else { return nil }
        let normalized = points.compactMap { normalize($0,video: video) }
        guard normalized.count == points.count else { return nil }
        let minX = normalized.map(\.x).min()!, maxX = normalized.map(\.x).max()!, minY = normalized.map(\.y).min()!, maxY = normalized.map(\.y).max()!
        let w = max(1/image.width,maxX-minX), h = max(1/image.height,maxY-minY)
        let bounds = NormalizedVideoRect(x: min(minX,1-w),y: min(minY,1-h),width: w,height: h)
        let result = FrameEllipse(id: id,kind: .freehand,bounds: bounds,points: normalized)
        guard (try? result.validate(width: Int(image.width),height: Int(image.height))) != nil else { return nil }
        return result
    }
    static func pin(at point: CGPoint,video: CGRect) -> NormalizedVideoRect? {
        guard video.contains(point), let center = normalize(point,video: video) else { return nil }
        let diameter = min(video.width,video.height)*0.06, w = diameter/video.width, h = diameter/video.height
        return .init(x: min(1-w,max(0,center.x-w/2)),y: min(1-h,max(0,center.y-h/2)),width: w,height: h)
    }
    static func videoRect(image: CGSize, canvas: CGRect) -> CGRect? {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = min(canvas.width/image.width,canvas.height/image.height)
        let size = CGSize(width: image.width*scale,height: image.height*scale)
        return CGRect(x: canvas.midX-size.width/2,y: canvas.midY-size.height/2,width: size.width,height: size.height)
    }
    static func display(_ rect: NormalizedVideoRect, video: CGRect) -> CGRect {
        CGRect(x: video.minX+rect.x*video.width,y: video.minY+rect.y*video.height,width: rect.width*video.width,height: rect.height*video.height)
    }
    static func drawn(from start: CGPoint, to end: CGPoint, kind: FrameAnnotationKind, video: CGRect) -> NormalizedVideoRect? {
        guard video.width > 0, video.height > 0, video.contains(start), [start.x,start.y,end.x,end.y].allSatisfy(\.isFinite) else { return nil }
        var finish = CGPoint(x: min(video.maxX,max(video.minX,end.x)),y: min(video.maxY,max(video.minY,end.y)))
        if kind == .circle {
            let side = min(abs(finish.x-start.x),abs(finish.y-start.y))
            finish = CGPoint(x: start.x+(finish.x<start.x ? -side:side),y: start.y+(finish.y<start.y ? -side:side))
        }
        let rect = NormalizedVideoRect(x: (min(start.x,finish.x)-video.minX)/video.width,y: (min(start.y,finish.y)-video.minY)/video.height,width: abs(finish.x-start.x)/video.width,height: abs(finish.y-start.y)/video.height)
        guard (try? rect.validate()) != nil else { return nil }; return rect
    }
}
struct FrameAnnotationHistory: Sendable {
    private(set) var shapes: [FrameEllipse] = []
    private var undoStates: [[FrameEllipse]] = []
    private var redoStates: [[FrameEllipse]] = []
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    init(shapes: [FrameEllipse] = []) { self.shapes = shapes }
    mutating func replace(_ next: [FrameEllipse]) throws {
        guard next.count <= 32, Set(next.map(\.id)).count == next.count else { throw WorkflowFailure.invalid("A frame comment supports at most 32 unique marks.") }
        guard next != shapes else { return }
        undoStates.append(shapes); if undoStates.count > 100 { undoStates.removeFirst() }; redoStates = []; shapes = next
    }
    mutating func add(_ shape: FrameEllipse) throws { try replace(shapes+[shape]) }
    mutating func remove(_ id: UUID) throws { try replace(shapes.filter { $0.id != id }) }
    mutating func undo() { if let previous = undoStates.popLast() { redoStates.append(shapes); shapes = previous } }
    mutating func redo() { if let next = redoStates.popLast() { undoStates.append(shapes); shapes = next } }
}
struct FrozenReviewFrame: Sendable {
    let request: FrameCommentRequest
    let png: Data
    let pngSHA256: String
    let width: Int
    let height: Int
    let actualTime: ReviewClockTime
}
struct SavedFrameComment: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let supersedesID: UUID?
    let request: FrameCommentRequest
    let text: String
    let annotations: [FrameEllipse]
    let framePNG_SHA256: String
    let width: Int
    let height: Int
    let actualFrameTime: ReviewClockTime
    let created: Date
    let reviewOnly: Bool
    let productionAuthorized: Bool
    let appliedToVideo: Bool
    func validate() throws {
        try request.frame.validate(duration: request.target.duration)
        guard schemaVersion == 1, id != supersedesID, (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || annotations.contains { $0.note != nil }), text.utf8.count <= 16_384,
              annotations.count <= 32, Set(annotations.map(\.id)).count == annotations.count,
              width > 0, height > 0, width <= 7680, height <= 7680, width*height <= 33_177_600,
              actualFrameTime == ReviewClockTime(value: request.frame.presentationValue,timescale: 24000), TranscriptCatalog.isSHA(framePNG_SHA256), reviewOnly, !productionAuthorized, !appliedToVideo else { throw ProjectFailure.invalidProject }
        for shape in annotations {
            try shape.validate(width: width,height: height)
            try shape.person?.validate(project: request.target.projectID)
            for mention in shape.mentions ?? [] { try mention.person.validate(project: request.target.projectID) }
        }
    }
}

/// Names are supplied by the user and scoped to one project. No visual or
/// external identity is inferred by creating, matching or merging these IDs.
enum ProjectPersonNames {
    static func cleaned(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value == cleaned(value) && value.utf8.count <= 160 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func folded(_ value: String) -> String { cleaned(value).folding(options: [.caseInsensitive,.diacriticInsensitive],locale: Locale(identifier: "en_US_POSIX")) }
}
struct ProjectPerson: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var previousNames: [String] = []
    var revision = 1
    var archived = false
    var mergedIntoID: UUID? = nil
    var active: Bool { !archived && mergedIntoID == nil }
}
struct ProjectPeopleChange: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case create, rename, archive, restore, merge, split }
    let id: UUID
    let revision: Int
    let kind: Kind
    let people: [UUID]
    let previousName: String?
    let name: String?
    let created: Date
}
struct ProjectPeopleDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let projectID: UUID
    var revision = 0
    var people: [ProjectPerson] = []
    var changes: [ProjectPeopleChange] = []
    func validate(project: UUID) throws {
        guard schemaVersion == 1, projectID == project, people.count <= 512, changes.count <= 4096,
              revision == changes.count, Set(people.map(\.id)).count == people.count, Set(changes.map(\.id)).count == changes.count else { throw ProjectFailure.invalidProject }
        let ids = Set(people.map(\.id))
        for person in people {
            guard ProjectPersonNames.valid(person.name), person.revision > 0, person.revision <= max(1,revision),
                  person.previousNames.count <= 64, Set(person.previousNames).count == person.previousNames.count,
                  person.previousNames.allSatisfy(ProjectPersonNames.valid),
                  person.mergedIntoID == nil || (person.archived && person.mergedIntoID != person.id && ids.contains(person.mergedIntoID!)) else { throw ProjectFailure.invalidProject }
            var seen = Set<UUID>(), current: ProjectPerson? = person
            while let value = current {
                guard seen.insert(value.id).inserted else { throw ProjectFailure.invalidProject }
                current = value.mergedIntoID.flatMap { id in people.first { $0.id == id } }
            }
        }
        for (index,change) in changes.enumerated() {
            guard change.revision == index+1, (1...2).contains(change.people.count), Set(change.people).count == change.people.count,
                  change.people.allSatisfy(ids.contains), change.created.timeIntervalSince1970.isFinite,
                  change.name.map(ProjectPersonNames.valid) ?? true, change.previousName.map(ProjectPersonNames.valid) ?? true else { throw ProjectFailure.invalidProject }
        }
        // The checksummed payload must describe the exact roster produced by its
        // explicit history. A valid hash alone cannot authorize invented people,
        // silent reassignment, skipped revisions or a changed historical label.
        var replay: [ProjectPerson] = []
        for change in changes {
            let first = change.people[0]
            switch change.kind {
            case .create, .split:
                let newID: UUID
                if change.kind == .split {
                    guard change.people.count == 2, replay.contains(where: { $0.id == first && $0.active }) else { throw ProjectFailure.invalidProject }
                    newID = change.people[1]
                } else {
                    guard change.people.count == 1 else { throw ProjectFailure.invalidProject }
                    newID = first
                }
                guard let name = change.name, change.previousName == nil, !replay.contains(where: { $0.id == newID }) else { throw ProjectFailure.invalidProject }
                replay.append(.init(id: newID,name: name))
            case .rename:
                guard change.people.count == 1, let name = change.name,
                      let i = replay.firstIndex(where: { $0.id == first && $0.active }),
                      change.previousName == replay[i].name, name != replay[i].name else { throw ProjectFailure.invalidProject }
                if !replay[i].previousNames.contains(replay[i].name) { replay[i].previousNames.append(replay[i].name) }
                replay[i].name = name; replay[i].revision += 1
            case .archive, .restore:
                guard change.people.count == 1, change.name == nil, change.previousName == nil,
                      let i = replay.firstIndex(where: { $0.id == first && $0.mergedIntoID == nil }),
                      replay[i].archived == (change.kind == .restore) else { throw ProjectFailure.invalidProject }
                replay[i].archived = change.kind == .archive; replay[i].revision += 1
            case .merge:
                guard change.people.count == 2, change.name == nil, change.previousName == nil,
                      let i = replay.firstIndex(where: { $0.id == first && $0.active }),
                      replay.contains(where: { $0.id == change.people[1] && $0.active }) else { throw ProjectFailure.invalidProject }
                replay[i].archived = true; replay[i].mergedIntoID = change.people[1]; replay[i].revision += 1
            }
        }
        guard replay == people else { throw ProjectFailure.invalidProject }
    }
    /// New assignments use an active profile's current label. Historical notes
    /// retain their original ID and words through later renames or merges.
    func validateReference(_ reference: ProjectPersonReference,historical: Bool = false) throws {
        try reference.validate(project: projectID)
        guard let person = people.first(where: { $0.id == reference.personID }),
              historical ? ([person.name]+person.previousNames).contains(reference.nameSnapshot) : (person.active && reference.nameSnapshot == person.name) else { throw ProjectFailure.invalidProject }
    }
    func canonicalID(_ id: UUID) -> UUID? {
        var seen = Set<UUID>(), next = id
        while let person = people.first(where: { $0.id == next }), seen.insert(next).inserted {
            if let merged = person.mergedIntoID { next = merged }
            else { return person.active ? person.id:nil }
        }
        return nil
    }
    /// Return every candidate. Duplicate names always require explicit choice.
    func mentionMatches(_ query: String,exact: Bool = false) -> [ProjectPerson] {
        let wanted = ProjectPersonNames.folded(query)
        var matches = Set<UUID>()
        for person in people {
            let named = ([person.name]+person.previousNames).contains { name in
                let value = ProjectPersonNames.folded(name); return exact ? value == wanted:value.hasPrefix(wanted)
            }
            if named, let id = canonicalID(person.id) { matches.insert(id) }
        }
        return people.filter { matches.contains($0.id) }.sorted {
            let first = ProjectPersonNames.folded($0.name), second = ProjectPersonNames.folded($1.name)
            return first == second ? $0.id.uuidString < $1.id.uuidString:first < second
        }
    }
}
struct ProjectPersonReference: Codable, Equatable, Sendable {
    let projectID: UUID
    let personID: UUID
    let nameSnapshot: String
    let confirmedByUser: Bool
    func validate(project: UUID) throws {
        guard projectID == project, confirmedByUser, ProjectPersonNames.valid(nameSnapshot) else { throw ProjectFailure.invalidProject }
    }
}

/// A typed mention is an explicit person choice, bound to exact note words.
/// Plain @text never becomes an identity reference without that choice.
struct FramePersonMention: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let person: ProjectPersonReference
    var utf16Start: Int
    let utf16Length: Int
    var noteSHA256: String
    static func hash(_ note: String) -> String { SHA256.hash(data: Data(note.utf8)).map { String(format: "%02x",$0) }.joined() }
    func validate(note: String) throws {
        guard note.utf8.count <= 4096 else { throw ProjectFailure.invalidProject }
        let length = note.utf16.count
        guard ProjectPersonNames.valid(person.nameSnapshot), person.confirmedByUser,
              utf16Start >= 0, utf16Start <= length, utf16Length > 0, utf16Length <= length-utf16Start,
              noteSHA256 == Self.hash(note) else { throw ProjectFailure.invalidProject }
        // NSRange conversion can admit a UTF16 offset inside a surrogate pair
        // or grapheme. Only indexes obtained by walking Characters may reach
        // Character subscripting/index(before:), including malformed files.
        var boundaries: [Int:String.Index] = [:], offset = 0
        for index in note.indices {
            boundaries[offset] = index; offset += String(note[index]).utf16.count
        }
        boundaries[offset] = note.endIndex
        guard offset == length, let start = boundaries[utf16Start], let end = boundaries[utf16Start+utf16Length],
              start == note.startIndex || note[note.index(before: start)].isWhitespace,
              end == note.endIndex || note[end].isWhitespace,
              String(note[start..<end]).utf8.elementsEqual(("@"+person.nameSnapshot).utf8) else { throw ProjectFailure.invalidProject }
    }
    /// Preserve only untouched prefix/suffix tokens. An intersecting edit or an
    /// ambiguous repeated-text alignment drops the link, retaining every word.
    static func rebased(_ mentions: [Self]?,from old: String,to new: String) -> [Self]? {
        guard !old.utf8.elementsEqual(new.utf8) else { return mentions }
        guard let mentions else { return nil }
        guard old.utf8.count <= 4096, new.utf8.count <= 4096 else { return nil }
        let before = Array(old), after = Array(new)
        var prefix = 0, suffix = 0
        while prefix < min(before.count,after.count), String(before[prefix]).utf8.elementsEqual(String(after[prefix]).utf8) { prefix += 1 }
        while suffix < min(before.count,after.count), String(before[before.count-1-suffix]).utf8.elementsEqual(String(after[after.count-1-suffix]).utf8) { suffix += 1 }
        // Repeated words can admit several equally short edits. Keep only
        // tokens outside the union of every possible changed range.
        let ambiguous = prefix+suffix > min(before.count,after.count)
        let startCount = ambiguous ? min(before.count,after.count)-suffix:prefix
        let endCount = ambiguous ? prefix+max(0,before.count-after.count):before.count-suffix
        let start = String(before.prefix(startCount)).utf16.count
        let end = String(before.prefix(endCount)).utf16.count
        let delta = new.utf16.count-old.utf16.count, hash = Self.hash(new)
        let kept = mentions.compactMap { mention -> Self? in
            guard (try? mention.validate(note: old)) != nil else { return nil }
            var next = mention
            if mention.utf16Start+mention.utf16Length <= start {} // Edit after token.
            else if mention.utf16Start >= end { next.utf16Start += delta }
            else { return nil }
            next.noteSHA256 = hash
            return (try? next.validate(note: new)) != nil ? next:nil
        }
        return kept.isEmpty ? nil:kept
    }
}

struct FramePersonMentionQuery: Equatable, Sendable {
    let note: String
    let query: String
    let utf16Start: Int
    static func trailing(in note: String) -> Self? {
        guard note.utf8.count <= 4096, let at = note.lastIndex(of: "@"),
              at == note.startIndex || note[note.index(before: at)].isWhitespace else { return nil }
        let query = String(note[note.index(after: at)...])
        guard query.utf8.count <= 160, !query.contains("@"), !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return .init(note: note,query: query,utf16Start: note[..<at].utf16.count)
    }
}

/// Field callbacks retain their original project/person even after selection
/// changes. Delayed acknowledgements clear only the submitted wording.
struct ProjectPersonNameDrafts: Sendable {
    private struct Key: Hashable, Sendable { let project: UUID; let person: UUID }
    private var values: [Key:String] = [:]
    func text(for person: ProjectPerson,project: UUID) -> String { values[.init(project: project,person: person.id)] ?? person.name }
    mutating func update(_ text: String,person: UUID,project: UUID) { values[.init(project: project,person: person)] = text }
    mutating func acknowledge(_ submitted: String,person: UUID,project: UUID) {
        let key = Key(project: project,person: person)
        if values[key] == submitted { values[key] = nil }
    }
}

/// Anonymous, frame-bound suggestions are not identities or tracking results.
struct FramePersonProposal: Equatable, Identifiable, Sendable {
    let id: UUID
    let requestID: UUID
    let frameSHA256: String
    let bounds: NormalizedVideoRect
    let confidence: Double
    func validate(frame: FrozenReviewFrame) throws {
        guard requestID == frame.request.id, frameSHA256 == frame.pngSHA256,
              confidence.isFinite, (0.5...1).contains(confidence) else { throw ProjectFailure.invalidProject }
        try FrameEllipse(id: id,kind: .highlight,bounds: bounds).validate(width: frame.width,height: frame.height)
    }
    static func fromVision(_ rect: CGRect,confidence: Double,frame: FrozenReviewFrame) -> Self? {
        let value = Self(id: UUID(),requestID: frame.request.id,frameSHA256: frame.pngSHA256,
                         bounds: .init(x: rect.minX,y: 1-rect.maxY,width: rect.width,height: rect.height),confidence: confidence)
        guard rect.width > 0, rect.height > 0, (try? value.validate(frame: frame)) != nil else { return nil }
        return value
    }
}
