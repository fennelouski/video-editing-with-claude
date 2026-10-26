import Foundation

/// A library project may retain several original editing roots as versions.
/// Grouping changes presentation only; it never moves media, merges manifests,
/// changes a cut pointer, or substitutes a copied project identity.
struct ProjectLibraryGroup: Codable,Identifiable,Equatable,Sendable {
    var id: UUID
    var name: String
    var members: [UUID]
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),members.count >= 2,members.count <= 100,
              Set(members).count == members.count else { throw ProjectFailure.invalidProject }
    }
    static func validate(_ groups: [Self]) throws {
        guard Set(groups.map(\.id)).count == groups.count else { throw ProjectFailure.invalidProject }
        var used = Set<UUID>()
        for group in groups {
            try group.validate()
            for member in group.members { guard used.insert(member).inserted else { throw ProjectFailure.invalidProject } }
        }
    }
}
struct ProjectLibraryEntry: Identifiable,Sendable {
    var id: UUID
    var name: String
    var memberIDs: [UUID]
    var groupID: UUID?
    static func entries(projects: [Project],bookmarks: [ProjectCatalogBookmark],groups: [ProjectLibraryGroup]) -> [Self] {
        var seen = Set<UUID>(),result: [Self] = []
        for item in projects.map(ProjectCatalogBookmark.init)+bookmarks {
            guard seen.insert(item.projectID).inserted else { continue }
            if let group = groups.first(where: { $0.members.contains(item.projectID) }) {
                if !result.contains(where: { $0.id == group.id }) { result.append(.init(id: group.id,name: group.name,memberIDs: group.members,groupID: group.id)) }
            } else { result.append(.init(id: item.projectID,name: item.name,memberIDs: [item.projectID],groupID: nil)) }
        }
        return result
    }
}
