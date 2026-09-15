import CryptoKit
import Foundation

struct EmbeddingIndexEntry: Codable, Equatable, Sendable {
    let assetID: String
    let sourceFingerprint: String
    let contentHash: String?
}

struct EmbeddingIndexBuildResult: Sendable {
    let candidates: [SimilarityCandidateRecord]
    let indexData: Data?
    let entries: [EmbeddingIndexEntry]
    let modelIdentifier: String?
    let algorithmVersion: String?
    let metric: String?
    let dimension: Int
}

enum EmbeddingIndexBuilder {
    static let ALGORITHM_VERSION = "vision-hnsw-v1"
    static let DISTANCE_THRESHOLD: Float = 0.28
    static let MAX_MATCHES_PER_PHOTO = 24
    static let SEARCH_EF = 96

    static func build(
        embeddings: [IndexedEmbedding]
    ) throws -> [SimilarityCandidateRecord] {
        try buildResult(embeddings: embeddings).candidates
    }

    static func buildResult(
        embeddings: [IndexedEmbedding]
    ) throws -> EmbeddingIndexBuildResult {
        let sortedEmbeddings = embeddings.sorted { $0.assetID < $1.assetID }
        guard let firstEmbedding = sortedEmbeddings.first(where: {
            $0.embedding.metric == "cosine"
                && $0.embedding.dimension > 0
        }) else {
            return EmbeddingIndexBuildResult(
                candidates: [],
                indexData: nil,
                entries: [],
                modelIdentifier: nil,
                algorithmVersion: nil,
                metric: nil,
                dimension: 0
            )
        }

        let dimension = firstEmbedding.embedding.dimension
        let modelIdentifier = firstEmbedding.embedding.modelIdentifier
        let algorithmVersion = firstEmbedding.embedding.algorithmVersion
        let compatibleEmbeddings = sortedEmbeddings.filter {
            $0.embedding.dimension == dimension
                && $0.embedding.metric == "cosine"
                && $0.embedding.modelIdentifier == modelIdentifier
                && $0.embedding.algorithmVersion == algorithmVersion
                && $0.embedding.values.allSatisfy(\.isFinite)
                && $0.embedding.values.contains(where: { $0 != 0 })
        }
        guard !compatibleEmbeddings.isEmpty else {
            return EmbeddingIndexBuildResult(
                candidates: [],
                indexData: nil,
                entries: [],
                modelIdentifier: modelIdentifier,
                algorithmVersion: algorithmVersion,
                metric: "cosine",
                dimension: dimension
            )
        }

        let index = try RustHnswIndex(
            dimension: dimension,
            maxNeighbors: 16,
            constructionEf: SEARCH_EF
        )
        for (label, item) in compatibleEmbeddings.enumerated() {
            try Task.checkCancellation()
            try index.insert(
                label: UInt64(label),
                vector: item.embedding.values
            )
        }

        var candidates: [String: SimilarityCandidateRecord] = [:]
        let encoder = JSONEncoder()
        for (label, item) in compatibleEmbeddings.enumerated() {
            try Task.checkCancellation()
            let matches = try index.search(
                vector: item.embedding.values,
                limit: MAX_MATCHES_PER_PHOTO + 1,
                searchEf: SEARCH_EF
            )
            for match in matches {
                guard match.label < UInt64(compatibleEmbeddings.count),
                      match.label != UInt64(label),
                      match.distance <= DISTANCE_THRESHOLD
                else {
                    continue
                }
                let matchedItem = compatibleEmbeddings[Int(match.label)]
                guard item.assetID < matchedItem.assetID else {
                    continue
                }
                if let leftHash = item.contentHash,
                   let rightHash = matchedItem.contentHash,
                   leftHash == rightHash
                {
                    continue
                }

                let assetIDs = [item.assetID, matchedItem.assetID].sorted()
                let evidence = EmbeddingEvidence(
                    modelIdentifier: item.embedding.modelIdentifier,
                    dimension: dimension,
                    distance: match.distance,
                    threshold: DISTANCE_THRESHOLD
                )
                let evidenceJSON = String(
                    decoding: try encoder.encode(evidence),
                    as: UTF8.self
                )
                let idSeed = [ALGORITHM_VERSION, assetIDs[0], assetIDs[1]]
                    .joined(separator: ":")
                let candidateID = HashEncoding.hex(
                    SHA256.hash(data: Data(idSeed.utf8))
                )
                candidates[candidateID] = SimilarityCandidateRecord(
                    id: candidateID,
                    assetAID: assetIDs[0],
                    assetBID: assetIDs[1],
                    relationKind: "edited_same_photo",
                    score: Double(
                        max(0, 1 - match.distance / DISTANCE_THRESHOLD)
                    ),
                    evidenceJSON: evidenceJSON,
                    algorithmVersion: ALGORITHM_VERSION
                )
            }
        }
        let entries = compatibleEmbeddings.map {
            EmbeddingIndexEntry(
                assetID: $0.assetID,
                sourceFingerprint: $0.sourceFingerprint,
                contentHash: $0.contentHash
            )
        }
        return EmbeddingIndexBuildResult(
            candidates: candidates.values.sorted { $0.id < $1.id },
            indexData: try index.serializedData(),
            entries: entries,
            modelIdentifier: modelIdentifier,
            algorithmVersion: algorithmVersion,
            metric: "cosine",
            dimension: dimension
        )
    }
}

private struct EmbeddingEvidence: Codable {
    let modelIdentifier: String
    let dimension: Int
    let distance: Float
    let threshold: Float
}
