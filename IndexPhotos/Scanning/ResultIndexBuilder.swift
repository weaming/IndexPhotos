import CryptoKit
import Foundation

enum ResultIndexBuilder {
    static let EXACT_ALGORITHM_VERSION = "exact-v1"
    static let PHASH_ALGORITHM_VERSION = "fast-phash-v1"
    static let PHASH_DISTANCE_THRESHOLD = 10
    static let MAX_MATCHES_PER_PHOTO = 32

    static func build(
        features: [IndexedFastFeature]
    ) throws -> (groups: [DuplicateGroupRecord], candidates: [SimilarityCandidateRecord]) {
        let sortedFeatures = features.sorted { $0.assetID < $1.assetID }
        let groups = makeDuplicateGroups(features: sortedFeatures)
        let candidates = try makeSimilarityCandidates(features: sortedFeatures)
        return (groups, candidates)
    }

    private static func makeDuplicateGroups(
        features: [IndexedFastFeature]
    ) -> [DuplicateGroupRecord] {
        let groupedFeatures = Dictionary(grouping: features, by: \.contentHash)
        return groupedFeatures.compactMap { contentHash, group in
            guard group.count > 1 else {
                return nil
            }

            let id = stableID(seed: "\(EXACT_ALGORITHM_VERSION):\(contentHash)")
            return DuplicateGroupRecord(
                id: id,
                assetIDs: group.map(\.assetID),
                confidence: 1,
                algorithmVersion: EXACT_ALGORITHM_VERSION
            )
        }
        .sorted { $0.id < $1.id }
    }

    private static func makeSimilarityCandidates(
        features: [IndexedFastFeature]
    ) throws -> [SimilarityCandidateRecord] {
        var index = PHashBKTree(capacity: features.count)
        var candidates: [SimilarityCandidateRecord] = []
        candidates.reserveCapacity(features.count)
        let encoder = JSONEncoder()
        let evidenceByDistance = try (0 ... PHASH_DISTANCE_THRESHOLD).map { distance in
            let evidence = PHashEvidence(perceptualHashDistance: distance, threshold: PHASH_DISTANCE_THRESHOLD)
            return try String(decoding: encoder.encode(evidence), as: UTF8.self)
        }

        for feature in features {
            try Task.checkCancellation()
            let matches = index.query(
                hash: feature.perceptualHash,
                maximumDistance: PHASH_DISTANCE_THRESHOLD,
                limit: MAX_MATCHES_PER_PHOTO,
                excludingContentHash: feature.contentHash
            )

            for match in matches {
                candidates.append(
                    SimilarityCandidateRecord(
                        id: stableID(
                            seed: "\(PHASH_ALGORITHM_VERSION):\(match.assetID):\(feature.assetID)"
                        ),
                        assetAID: match.assetID,
                        assetBID: feature.assetID,
                        relationKind: "edited_same_photo",
                        score: 1 - Double(match.distance) / Double(PHASH_DISTANCE_THRESHOLD + 1),
                        evidenceJSON: evidenceByDistance[match.distance],
                        algorithmVersion: PHASH_ALGORITHM_VERSION
                    )
                )
            }

            index.insert(feature)
        }

        return candidates.sorted { $0.id < $1.id }
    }

    private static func stableID(seed: String) -> String {
        HashEncoding.hex(SHA256.hash(data: Data(seed.utf8)))
    }
}

private struct PHashEvidence: Codable {
    let perceptualHashDistance: Int
    let threshold: Int
}

struct PHashMatch: Equatable {
    let assetID: String
    let contentHash: String
    let distance: Int
}

struct PHashBKTree {
    private struct Bucket {
        let contentHash: String
        var assetIDs: [String]
    }

    private struct Node {
        let hash: UInt64
        var buckets: [Bucket]
        var children: [Int: Int] = [:]
    }

    private var nodes: [Node] = []
    private var rootIndex: Int?
    private var hashIndices: [UInt64: Int] = [:]
    var nodeCount: Int {
        nodes.count
    }

    init(capacity: Int = 0) {
        nodes.reserveCapacity(min(capacity, 4096))
        hashIndices.reserveCapacity(min(capacity, 4096))
    }

    /// 按 assetID 升序插入，使每个哈希桶可直接返回最小的有效 assetID。
    mutating func insert(_ feature: IndexedFastFeature) {
        if let nodeIndex = hashIndices[feature.perceptualHash] {
            let bucketIndex = nodes[nodeIndex].buckets.count - 1
            if nodes[nodeIndex].buckets[bucketIndex].contentHash == feature.contentHash {
                nodes[nodeIndex].buckets[bucketIndex].assetIDs.append(feature.assetID)
            } else {
                nodes[nodeIndex].buckets.append(Bucket(contentHash: feature.contentHash, assetIDs: [feature.assetID]))
            }
            return
        }

        let newIndex = nodes.count
        nodes.append(Node(
            hash: feature.perceptualHash,
            buckets: [Bucket(contentHash: feature.contentHash, assetIDs: [feature.assetID])]
        ))
        hashIndices[feature.perceptualHash] = newIndex
        guard let rootIndex else {
            rootIndex = newIndex
            return
        }

        var nodeIndex = rootIndex
        while true {
            let distance = hammingDistance(
                nodes[nodeIndex].hash,
                feature.perceptualHash
            )
            if let childIndex = nodes[nodeIndex].children[distance] {
                nodeIndex = childIndex
                continue
            }

            nodes[nodeIndex].children[distance] = newIndex
            return
        }
    }

    func query(
        hash: UInt64,
        maximumDistance: Int,
        limit: Int,
        excludingContentHash: String
    ) -> [PHashMatch] {
        guard let rootIndex, limit > 0, maximumDistance >= 0 else {
            return []
        }

        var matches: [PHashMatch] = []
        matches.reserveCapacity(limit + 1)
        var pendingNodes = [rootIndex]

        while let nodeIndex = pendingNodes.popLast() {
            let node = nodes[nodeIndex]
            let distance = hammingDistance(node.hash, hash)
            if distance <= maximumDistance {
                var bucketMatchCount = 0
                for bucket in node.buckets where bucket.contentHash != excludingContentHash {
                    for assetID in bucket.assetIDs.prefix(limit - bucketMatchCount) {
                        let match = PHashMatch(assetID: assetID, contentHash: bucket.contentHash, distance: distance)
                        insertMatch(match, limit: limit, matches: &matches)
                        bucketMatchCount += 1
                    }
                    if bucketMatchCount == limit {
                        break
                    }
                }
            }

            let radius = matches.count == limit ? min(maximumDistance, matches[limit - 1].distance) : maximumDistance
            let lowerBound = max(0, distance - radius)
            let upperBound = distance + radius
            let children = node.children.filter { $0.key >= lowerBound && $0.key <= upperBound }
            for child in children.sorted(by: { abs($0.key - distance) > abs($1.key - distance) }) {
                pendingNodes.append(child.value)
            }
        }
        return matches
    }

    private func insertMatch(_ match: PHashMatch, limit: Int, matches: inout [PHashMatch]) {
        var lowerBound = 0
        var upperBound = matches.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let current = matches[middle]
            let isBefore = current.distance < match.distance
                || (current.distance == match.distance && current.assetID < match.assetID)
            if isBefore {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < limit else { return }
        matches.insert(match, at: lowerBound)
        if matches.count > limit {
            matches.removeLast()
        }
    }

    private func hammingDistance(_ left: UInt64, _ right: UInt64) -> Int {
        (left ^ right).nonzeroBitCount
    }
}
