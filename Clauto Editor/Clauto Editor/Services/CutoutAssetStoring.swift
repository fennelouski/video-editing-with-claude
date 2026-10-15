import Foundation

/// Persistence boundary also permits deterministic latency/failure fixtures.
/// Production always uses the descriptor-pinned, project-local repository.
protocol CutoutAssetStoring: Sendable {
    func readImageFile(_ url: URL) async throws -> Data
    func list(_ project: Project) async throws -> [CutoutSourceInfo]
    func create(_ project: Project,id: UUID,createdMilliseconds: Int64,name: String,bytes: Data) async throws -> CutoutDraftSnapshot
    func load(_ project: Project,id: UUID) async throws -> CutoutDraftSnapshot
    func source(_ project: Project,id: UUID) async throws -> CutoutDecodedSource
    func masks(_ project: Project,snapshot: CutoutDraftSnapshot) async throws -> CutoutBasisPixels?
    func storeDetection(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,detection: CutoutDetection) async throws -> CutoutMaskBasis
    func storeManualMask(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,encodedMask: Data) async throws -> CutoutMaskBasis
    func save(_ project: Project,base: CutoutDraftSnapshot,draft: CutoutDraft) async throws -> CutoutDraftSnapshot
    func copyDraft(_ project: Project,snapshot: CutoutDraftSnapshot,draft: CutoutDraft,newID: UUID,createdMilliseconds: Int64) async throws -> CutoutDraftSnapshot
    func preview(_ project: Project,snapshot: CutoutDraftSnapshot) async throws -> CutoutPixels
    func export(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,created: Date) async throws -> CutoutExport
}
