import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SoundTimelineCue: Identifiable, Equatable, Sendable {
    public let id, name, assetResourceID: String
    public let timelineStartFrame, sourceStartFrame, durationFrames: Int64
    public let sourceURL: URL?
    public let gainAndFadeXML: [String]
    public var requiredSourceSeconds: Double { Double(sourceStartFrame+durationFrames)*1001/24000 }
}

/// Edits only explicitly chosen connected audio nodes. Original timing, trim,
/// gain and fade descendants stay byte-equivalent as XML nodes; browsing never
/// invokes mutation. Undo/redo snapshots include the portable reference map.
public final class SoundTimelineDocument {
    private struct Snapshot { let data:Data;let references:[String:SoundSelectionReference] }
    public private(set) var data: Data
    public private(set) var references: [String:SoundSelectionReference] = [:]
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public init(data:Data) throws { _ = try Self.inventory(Self.parse(data));self.data = data }
    public var cues: [SoundTimelineCue] { (try? Self.inventory(Self.parse(data))) ?? [] }
    public func undo() { guard let prior = undoStack.popLast() else { return };redoStack.append(.init(data:data,references:references));data=prior.data;references=prior.references }
    public func redo() { guard let next = redoStack.popLast() else { return };undoStack.append(.init(data:data,references:references));data=next.data;references=next.references }
    public func replace(cueID:String,reference:SoundSelectionReference,sourceURL:URL,catalog:SoundCatalog) throws {
        let asset = try reference.validate(catalog:catalog)
        guard sourceURL.isFileURL,let cue = cues.first(where:{ $0.id == cueID }) else { throw SoundFailure.invalid("Select a connected sound in this timeline first.") }
        guard asset.format == "wav",asset.duration+0.000001 >= cue.requiredSourceSeconds else {
            throw SoundFailure.invalid(String(format:"This sound is too short. The existing trim needs %.3f seconds. Timing, gain and fades are preserved.",cue.requiredSourceSeconds))
        }
        if references[cueID] == reference { return }
        let xml = try Self.parse(data),node = try Self.node(cueID,in:xml)
        let assetID = try Self.addAsset(asset,sourceURL:sourceURL,to:xml)
        node.attribute(forName:"ref")?.stringValue = assetID
        node.attribute(forName:"name")?.stringValue = asset.title
        let next = try Self.serialized(xml)
        guard let after = try Self.inventory(Self.parse(next)).first(where:{ $0.id == cueID }),
              after.timelineStartFrame==cue.timelineStartFrame,after.sourceStartFrame==cue.sourceStartFrame,
              after.durationFrames==cue.durationFrames,after.gainAndFadeXML==cue.gainAndFadeXML else { throw SoundFailure.invalid("Replacement changed the cue envelope or timing; it was refused.") }
        checkpoint();data = next;references[cueID] = reference
    }
    public func rewrittenMediaURLs(_ mapping:[String:URL]) throws -> Data {
        let xml = try Self.parse(data)
        for (cueID,url) in mapping {
            let node = try Self.node(cueID,in:xml)
            guard let ref = node.attribute(forName:"ref")?.stringValue,
                  let asset = xml.rootElement()?.elements(forName:"resources").first?.elements(forName:"asset").first(where:{ $0.attribute(forName:"id")?.stringValue==ref }),
                  let media = asset.elements(forName:"media-rep").first else { throw SoundFailure.invalid("The selected sound resource is missing.") }
            media.attribute(forName:"src")?.stringValue = url.absoluteString
        }
        let used=Set(try xml.nodes(forXPath:"//@ref").compactMap(\.stringValue))
        for asset in xml.rootElement()?.elements(forName:"resources").first?.elements(forName:"asset") ?? [] {
            if let id=asset.attribute(forName:"id")?.stringValue,id.hasPrefix("clautoSound"),!used.contains(id) { asset.detach() }
        }
        return try Self.serialized(xml)
    }
    public func verifyReplacement(of original:Data,references:[String:SoundSelectionReference],mediaURLs:[String:URL],catalog:SoundCatalog) throws {
        let before=try Self.parse(original),after=try Self.parse(data)
        let oldAssets=before.rootElement()?.elements(forName:"resources").first?.elements(forName:"asset") ?? []
        let oldIDs=Set(oldAssets.compactMap { $0.attribute(forName:"id")?.stringValue })
        let assets=after.rootElement()?.elements(forName:"resources").first?.elements(forName:"asset") ?? []
        guard !references.isEmpty,references.count<=100,Set(assets.compactMap { $0.attribute(forName:"id")?.stringValue }).count==assets.count else { throw SoundFailure.invalid("Invalid replacement resource identity.") }
        for (id,ref) in references {
            _ = try ref.validate(catalog:catalog)
            let old=try Self.node(id,in:before),new=try Self.node(id,in:after)
            guard let resourceID=new.attribute(forName:"ref")?.stringValue,
                  let asset=assets.first(where:{ $0.attribute(forName:"id")?.stringValue==resourceID }),
                  let uri=asset.elements(forName:"media-rep").first?.attribute(forName:"src")?.stringValue,
                  uri==mediaURLs[id]?.absoluteString else { throw SoundFailure.invalid("Replacement media does not match its verified snapshot.") }
            for name in ["ref","name"] {
                new.removeAttribute(forName:name)
                if let value=old.attribute(forName:name)?.stringValue { new.addAttribute(XMLNode.attribute(withName:name,stringValue:value) as! XMLNode) }
            }
        }
        for asset in assets where !oldIDs.contains(asset.attribute(forName:"id")?.stringValue ?? "") { asset.detach() }
        guard Self.canonical(before.rootElement()!)==Self.canonical(after.rootElement()!) else { throw SoundFailure.invalid("The sound edit changed unrelated picture, timing, gain, fades or timeline content.") }
    }
    private static func canonical(_ node:XMLNode) -> String {
        if let element=node as? XMLElement {
            let attributes=(element.attributes ?? []).map { ($0.name ?? "")+"="+($0.stringValue ?? "") }.sorted().joined(separator:"\u{1f}")
            let namespaces=(element.namespaces ?? []).map { ($0.name ?? "")+"="+($0.stringValue ?? "") }.sorted().joined(separator:"\u{1f}")
            return "<\(element.name ?? "")|\(attributes)|\(namespaces)>"+(element.children ?? []).map(canonical).joined()+"</>"
        }
        let text=node.stringValue ?? ""
        return text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "":"\(node.kind.rawValue):\(text)"
    }
    public func similarCandidates(cueID:String,catalog:SoundCatalog) -> [SoundAsset] {
        guard let cue = cues.first(where:{ $0.id==cueID }) else { return [] }
        let seed = references[cueID].flatMap { catalog.asset($0.assetID) } ?? catalog.assets.first(where:{ $0.title==cue.name })
        return catalog.assets.filter { $0.format=="wav" && $0.duration+0.000001>=cue.requiredSourceSeconds }.sorted { a,b in
            func rank(_ asset:SoundAsset) -> Double {
                Double(seed?.category==asset.category ? 10:0)+Double(Set(seed?.tags ?? []).intersection(asset.tags).count)*2-abs(asset.duration-cue.requiredSourceSeconds)
            }
            let first = rank(a),second = rank(b)
            return first==second ? a.id<b.id : first>second
        }
    }
    private func checkpoint() { undoStack.append(.init(data:data,references:references));if undoStack.count>50 { undoStack.removeFirst() };redoStack=[] }
    private static func serialized(_ xml:XMLDocument) throws -> Data {
        guard let root=xml.rootElement() else { throw SoundFailure.invalid("Timeline root is unavailable.") }
        // XMLDocument can serialize an empty DTD differently after repeated
        // edits. Write Clauto's fixed local declaration from the root element.
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n"+root.xmlString(options:[.nodePreserveAll])+"\n").utf8)
    }
    private static func parse(_ data:Data) throws -> XMLDocument {
        guard data.count<=8*1024*1024,let text=String(data:data,encoding:.utf8),!text.uppercased().contains("<!ENTITY"),
              !text.replacingOccurrences(of:"<!DOCTYPE\\s+fcpxml\\s*(?:\\[\\s*\\])?\\s*>",with:"",options:.regularExpression).uppercased().contains("<!DOCTYPE") else { throw SoundFailure.invalid("Unsupported or external-entity timeline XML.") }
        let xml = try XMLDocument(data:data,options:[.nodePreserveAll,.nodeLoadExternalEntitiesNever])
        guard xml.rootElement()?.name=="fcpxml" else { throw SoundFailure.invalid("Choose a Clauto FCPXML saved timeline.") }
        return xml
    }
    private static func spine(_ xml:XMLDocument) throws -> XMLElement {
        guard let value = try xml.nodes(forXPath:"/fcpxml/library/event/project/sequence/spine").first as? XMLElement else { throw SoundFailure.invalid("Timeline has no supported primary storyline.") };return value
    }
    private static func node(_ id:String,in xml:XMLDocument) throws -> XMLElement {
        let parts = id.split(separator:":").compactMap { Int($0) }
        guard parts.count==2,let primary=try spine(xml).children?.filter({ $0.kind == .element })[safe:parts[0]] as? XMLElement,
              let node=primary.children?.filter({ $0.kind == .element })[safe:parts[1]] as? XMLElement,
              ["asset-clip","audio"].contains(node.name ?? "") else { throw SoundFailure.invalid("The selected sound changed. Reopen this timeline.") };return node
    }
    private static func inventory(_ xml:XMLDocument) throws -> [SoundTimelineCue] {
        let resources=xml.rootElement()?.elements(forName:"resources").first?.elements(forName:"asset") ?? []
        var result: [SoundTimelineCue] = []
        for (pi,raw) in (try spine(xml).children?.filter({ $0.kind == .element }) ?? []).enumerated() {
            guard let primary=raw as? XMLElement else { continue }
            let offset=try frames(primary.attribute(forName:"offset")?.stringValue ?? "0s"),source=try frames(primary.attribute(forName:"start")?.stringValue ?? "0s")
            for (ci,child) in (primary.children?.filter({ $0.kind == .element }) ?? []).enumerated() {
                guard let node=child as? XMLElement,["asset-clip","audio"].contains(node.name ?? ""),
                      let lane=Int(node.attribute(forName:"lane")?.stringValue ?? "0"),lane<0,
                      let ref=node.attribute(forName:"ref")?.stringValue else { continue }
                let resource=resources.first { $0.attribute(forName:"id")?.stringValue==ref }
                let uri=resource?.elements(forName:"media-rep").first?.attribute(forName:"src")?.stringValue.flatMap(URL.init(string:))
                let at=try frames(node.attribute(forName:"offset")?.stringValue ?? "0s")+offset-source
                result.append(.init(id:"\(pi):\(ci)",name:node.attribute(forName:"name")?.stringValue ?? resource?.attribute(forName:"name")?.stringValue ?? "Connected sound",assetResourceID:ref,timelineStartFrame:at,sourceStartFrame:try frames(node.attribute(forName:"start")?.stringValue ?? "0s"),durationFrames:try frames(node.attribute(forName:"duration")?.stringValue ?? "0s"),sourceURL:uri,gainAndFadeXML:(node.children ?? []).map { $0.xmlString } ))
            }
        }
        return result
    }
    private static func addAsset(_ asset:SoundAsset,sourceURL:URL,to xml:XMLDocument) throws -> String {
        guard let resources=xml.rootElement()?.elements(forName:"resources").first else { throw SoundFailure.invalid("Timeline resources are missing.") }
        let id="clautoSound"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let node=XMLElement(name:"asset")
        for (key,value) in ["id":id,"name":asset.title,"start":"0s","duration":"\(Int64(floor(asset.duration*24000/1001))*1001)/24000s","hasAudio":"1","hasVideo":"0","audioSources":"1","audioChannels":String(asset.channels),"audioRate":String(asset.sampleRate)] { node.addAttribute(XMLNode.attribute(withName:key,stringValue:value) as! XMLNode) }
        let media=XMLElement(name:"media-rep");media.addAttribute(XMLNode.attribute(withName:"kind",stringValue:"original-media") as! XMLNode);media.addAttribute(XMLNode.attribute(withName:"src",stringValue:sourceURL.absoluteString) as! XMLNode);node.addChild(media);resources.addChild(node);return id
    }
    private static func frames(_ text:String) throws -> Int64 {
        let parts=text.dropLast().split(separator:"/")
        guard text.hasSuffix("s"),let numerator=Int64(parts.first ?? ""),numerator>=0,parts.count<=2,let denominator=parts.count==2 ? Int64(parts[1]):1,denominator>0 else { throw SoundFailure.invalid("Unsupported timeline time.") }
        let n=numerator.multipliedReportingOverflow(by:24000),d=denominator.multipliedReportingOverflow(by:1001)
        guard !n.overflow,!d.overflow,n.partialValue % d.partialValue==0 else { throw SoundFailure.invalid("Sound timing must use Clauto's integer frame grid.") };return n.partialValue/d.partialValue
    }
}
private extension Array { subscript(safe index:Int) -> Element? { indices.contains(index) ? self[index] : nil } }
