import Foundation

actor ResultIndexer {
    private let catalog: CatalogStore

    init(catalog: CatalogStore) {
        self.catalog = catalog
    }

    func rebuild() async throws -> ResultIndexSummary {
        let features = try await catalog.committedFastFeatures()
        let result = try ResultIndexBuilder.build(features: features)
        try await catalog.replaceResultIndex(
            groups: result.groups,
            candidates: result.candidates
        )
        return ResultIndexSummary(
            duplicateGroupCount: result.groups.count,
            similarityCandidateCount: result.candidates.count
        )
    }
}
