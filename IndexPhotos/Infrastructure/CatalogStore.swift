import Foundation
import SQLite3

actor CatalogStore {
    private var database: OpaquePointer?
    private let dateFormatter = ISO8601DateFormatter()

    init(databaseURL: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database {
                sqlite3_close(database)
            }
            throw IndexPhotosError.database(message)
        }

        self.database = database

        do {
            try Self.execute(database, "PRAGMA journal_mode = WAL;")
            try Self.execute(database, "PRAGMA synchronous = NORMAL;")
            try Self.execute(database, "PRAGMA foreign_keys = ON;")
            try Self.execute(database, "PRAGMA busy_timeout = 5000;")
            try Self.createSchema(database)
        } catch {
            sqlite3_close(database)
            self.database = nil
            throw error
        }
    }

    func recoverInterruptedSessions() throws {
        let sessionStatement = try prepare(
            """
            UPDATE scan_sessions
            SET status = 'recovering', updated_at = ?, heartbeat_at = NULL
            WHERE status IN ('running', 'pausing');
            """
        )
        defer { sqlite3_finalize(sessionStatement) }
        try bind(timestamp(.now), at: 1, to: sessionStatement)
        try step(sessionStatement)

        let itemStatement = try prepare(
            """
            UPDATE scan_items
            SET status = 'pending', heartbeat_at = NULL, updated_at = ?
            WHERE status = 'processing';
            """
        )
        defer { sqlite3_finalize(itemStatement) }
        try bind(timestamp(.now), at: 1, to: itemStatement)
        try step(itemStatement)
    }

    func close() throws {
        guard let database else {
            return
        }

        guard sqlite3_close(database) == SQLITE_OK else {
            throw IndexPhotosError.database("关闭数据库失败：\(String(cString: sqlite3_errmsg(database)))")
        }
        self.database = nil
    }

    func upsertRoot(
        id: UUID,
        displayName: String,
        url: URL,
        bookmarkData: Data?
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO roots (id, display_name, path, bookmark_data, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                path = excluded.path,
                bookmark_data = excluded.bookmark_data,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(id.uuidString, at: 1, to: statement)
        try bind(displayName, at: 2, to: statement)
        try bind(url.path, at: 3, to: statement)
        try bind(bookmarkData, at: 4, to: statement)
        try bind(timestamp(.now), at: 5, to: statement)
        try bind(timestamp(.now), at: 6, to: statement)
        try step(statement)
    }

    func createScanSession(rootID: UUID) throws -> UUID {
        let id = UUID()
        let statement = try prepare(
            """
            INSERT INTO scan_sessions (
                id, root_id, status, phase, phase_version,
                created_at, updated_at, last_checkpoint_at, heartbeat_at
            ) VALUES (?, ?, 'queued', 'prepare', 1, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(id.uuidString, at: 1, to: statement)
        try bind(rootID.uuidString, at: 2, to: statement)
        try bind(now, at: 3, to: statement)
        try bind(now, at: 4, to: statement)
        try bind(now, at: 5, to: statement)
        try bind(now, at: 6, to: statement)
        try step(statement)
        return id
    }

    func markSessionRunning(_ sessionID: UUID, phase: ScanPhase? = nil) throws {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET status = 'running', phase = COALESCE(?, phase), updated_at = ?, heartbeat_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(phase?.rawValue, at: 1, to: statement)
        try bind(now, at: 2, to: statement)
        try bind(now, at: 3, to: statement)
        try bind(sessionID.uuidString, at: 4, to: statement)
        try step(statement)

        if phase == .fastFeatures {
            try reconcileFastFeatureProgress(sessionID)
        }
    }

    func registerDiscovered(
        _ item: DiscoveredPhoto,
        sessionID: UUID
    ) throws -> ScanProgressSnapshot {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try upsertAsset(item)
            try upsertFastFeatureTask(item, sessionID: sessionID)
            try updateFastFeatureProgress(
                sessionID: sessionID,
                lastPath: item.path
            )
            try execute("COMMIT;")
            return try progress(for: sessionID)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func validFastFeature(
        assetID: String,
        sourceFingerprint: String,
        algorithmVersion: String
    ) throws -> FastFeatureRecord? {
        let statement = try prepare(
            """
            SELECT value
            FROM asset_features
            WHERE asset_id = ? AND feature_kind = 'fast_features'
              AND algorithm_version = ?
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(assetID, at: 1, to: statement)
        try bind(algorithmVersion, at: 2, to: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw IndexPhotosError.database("读取快速特征缓存失败")
        }
        guard let data = columnData(statement, index: 0),
              let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: data)
        else {
            return nil
        }
        guard record.sourceFingerprint == sourceFingerprint else {
            return nil
        }
        guard record.quickFingerprint != nil else {
            return nil
        }
        return record
    }

    func quickFingerprintCandidates(
        sizeBytes: Int64,
        quickFingerprint: String,
        excluding assetID: String
    ) throws -> [ContentHashCandidate] {
        let statement = try prepare(
            """
            SELECT a.id, a.path, a.source_fingerprint, a.size_bytes, a.content_hash, f.value
            FROM assets AS a
            JOIN asset_features AS f ON f.asset_id = a.id
            WHERE a.state = 'active' AND a.size_bytes = ? AND a.id != ?
              AND f.feature_kind = 'fast_features'
              AND f.algorithm_version = 'fast-v1';
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(sizeBytes, at: 1, to: statement)
        try bind(assetID, at: 2, to: statement)

        var candidates: [ContentHashCandidate] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw IndexPhotosError.database("读取快速指纹候选失败")
            }
            guard let candidateID = columnText(statement, index: 0),
                  let path = columnText(statement, index: 1),
                  let sourceFingerprint = columnText(statement, index: 2),
                  let value = columnData(statement, index: 5),
                  let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: value),
                  record.quickFingerprint == quickFingerprint
            else {
                continue
            }
            candidates.append(ContentHashCandidate(
                assetID: candidateID,
                path: path,
                sourceFingerprint: sourceFingerprint,
                contentHash: columnText(statement, index: 4),
                fileSize: sqlite3_column_int64(statement, 3)
            ))
        }
        return candidates
    }

    func completeContentHash(
        assetID: String,
        sourceFingerprint: String,
        contentHash: String
    ) throws {
        let statement = try prepare(
            """
            SELECT value
            FROM asset_features
            WHERE asset_id = ? AND feature_kind = 'fast_features'
              AND algorithm_version = 'fast-v1'
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(assetID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = columnData(statement, index: 0),
              var record = try? JSONDecoder().decode(FastFeatureRecord.self, from: value),
              record.sourceFingerprint == sourceFingerprint
        else {
            throw IndexPhotosError.invalidState("无法更新快速特征的完整哈希：\(assetID)")
        }

        record = FastFeatureRecord(
            sourceFingerprint: record.sourceFingerprint,
            contentHash: contentHash,
            quickFingerprint: record.quickFingerprint,
            perceptualHash: record.perceptualHash,
            thumbnailRelativePath: record.thumbnailRelativePath,
            width: record.width,
            height: record.height
        )
        let encodedRecord = try JSONEncoder().encode(record)

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try updateAssetContentHash(
                assetID: assetID,
                sourceFingerprint: sourceFingerprint,
                contentHash: contentHash
            )
            try upsertFeature(
                assetID: assetID,
                algorithmVersion: "fast-v1",
                value: encodedRecord
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func committedFastFeatures() throws -> [IndexedFastFeature] {
        let statement = try prepare(
            """
            SELECT a.id, a.content_hash, f.value, a.source_fingerprint
            FROM assets AS a
            JOIN asset_features AS f ON f.asset_id = a.id
            WHERE a.state = 'active'
              AND a.content_hash IS NOT NULL
              AND f.feature_kind = 'fast_features'
              AND f.algorithm_version = 'fast-v1';
            """
        )
        defer { sqlite3_finalize(statement) }

        var features: [IndexedFastFeature] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw IndexPhotosError.database("读取已提交快速特征失败")
            }
            guard let assetID = columnText(statement, index: 0),
                  let contentHash = columnText(statement, index: 1),
                  let value = columnData(statement, index: 2),
                  let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: value),
                  record.sourceFingerprint == columnText(statement, index: 3),
                  record.contentHash == contentHash
            else {
                continue
            }
            features.append(
                IndexedFastFeature(
                    assetID: assetID,
                    contentHash: contentHash,
                    perceptualHash: record.perceptualHash
                )
            )
        }
        return features
    }

    func embeddingInputs() throws -> [EmbeddingInput] {
        let statement = try prepare(
            """
            SELECT a.id, a.source_fingerprint, f.value
            FROM assets AS a
            JOIN asset_features AS f ON f.asset_id = a.id
            WHERE a.state = 'active'
              AND f.feature_kind = 'fast_features'
              AND f.algorithm_version = 'fast-v1';
            """
        )
        defer { sqlite3_finalize(statement) }

        var inputs: [EmbeddingInput] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw IndexPhotosError.database("读取向量输入失败")
            }
            guard let assetID = columnText(statement, index: 0),
                  let sourceFingerprint = columnText(statement, index: 1),
                  let value = columnData(statement, index: 2),
                  let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: value),
                  record.sourceFingerprint == sourceFingerprint,
                  !record.thumbnailRelativePath.isEmpty
            else {
                continue
            }
            inputs.append(
                EmbeddingInput(
                    assetID: assetID,
                    sourceFingerprint: sourceFingerprint,
                    thumbnailRelativePath: record.thumbnailRelativePath
                )
            )
        }
        return inputs.sorted { $0.assetID < $1.assetID }
    }

    func validEmbedding(
        assetID: String,
        sourceFingerprint: String,
        algorithmVersion: String
    ) throws -> ImageEmbedding? {
        let statement = try prepare(
            """
            SELECT value
            FROM asset_features
            WHERE asset_id = ? AND feature_kind = 'embedding'
              AND algorithm_version = ?
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(assetID, at: 1, to: statement)
        try bind(algorithmVersion, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = columnData(statement, index: 0),
              let record = try? JSONDecoder().decode(EmbeddingFeatureRecord.self, from: value),
              record.sourceFingerprint == sourceFingerprint,
              record.algorithmVersion == algorithmVersion
        else {
            return nil
        }
        return record.embedding
    }

    func commitEmbedding(
        assetID: String,
        sourceFingerprint: String,
        embedding: ImageEmbedding
    ) throws {
        let record = EmbeddingFeatureRecord(
            sourceFingerprint: sourceFingerprint,
            embedding: embedding
        )
        let encodedRecord = try JSONEncoder().encode(record)

        let assetStatement = try prepare(
            """
            SELECT source_fingerprint
            FROM assets
            WHERE id = ? AND state = 'active'
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(assetStatement) }
        try bind(assetID, at: 1, to: assetStatement)
        guard sqlite3_step(assetStatement) == SQLITE_ROW,
              columnText(assetStatement, index: 0) == sourceFingerprint
        else {
            throw IndexPhotosError.invalidState("无法提交过期图片向量：\(assetID)")
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try upsertFeature(
                assetID: assetID,
                featureKind: "embedding",
                algorithmVersion: embedding.algorithmVersion,
                value: encodedRecord
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func committedEmbeddings(algorithmVersion: String) throws -> [IndexedEmbedding] {
        let statement = try prepare(
            """
            SELECT a.id, a.source_fingerprint, a.content_hash, f.value
            FROM assets AS a
            JOIN asset_features AS f ON f.asset_id = a.id
            WHERE a.state = 'active'
              AND f.feature_kind = 'embedding'
              AND f.algorithm_version = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(algorithmVersion, at: 1, to: statement)

        var embeddings: [IndexedEmbedding] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw IndexPhotosError.database("读取已提交图片向量失败")
            }
            guard let assetID = columnText(statement, index: 0),
                  let sourceFingerprint = columnText(statement, index: 1),
                  let value = columnData(statement, index: 3),
                  let record = try? JSONDecoder().decode(EmbeddingFeatureRecord.self, from: value),
                  record.sourceFingerprint == sourceFingerprint,
                  record.algorithmVersion == algorithmVersion
            else {
                continue
            }
            embeddings.append(
                IndexedEmbedding(
                    assetID: assetID,
                    sourceFingerprint: sourceFingerprint,
                    contentHash: columnText(statement, index: 2),
                    embedding: record.embedding
                )
            )
        }
        return embeddings.sorted { $0.assetID < $1.assetID }
    }

    func markMissingAssets(
        rootID: UUID,
        sessionID: UUID
    ) throws -> ScanProgressSnapshot {
        guard let database else {
            throw IndexPhotosError.database("数据库连接已关闭")
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare(
                """
                UPDATE assets
                SET state = 'missing', updated_at = ?
                WHERE root_id = ? AND state = 'active'
                  AND NOT EXISTS (
                      SELECT 1 FROM scan_items
                      WHERE scan_items.session_id = ?
                        AND scan_items.asset_id = assets.id
                        AND scan_items.phase = 'fast_features'
                  );
                """
            )
            defer { sqlite3_finalize(statement) }

            let now = timestamp(.now)
            try bind(now, at: 1, to: statement)
            try bind(rootID.uuidString, at: 2, to: statement)
            try bind(sessionID.uuidString, at: 3, to: statement)
            try step(statement)
            let missingCount = Int(sqlite3_changes(database))

            let sessionStatement = try prepare(
                """
                UPDATE scan_sessions
                SET missing_count = ?, updated_at = ?, heartbeat_at = ?
                WHERE id = ?;
                """
            )
            defer { sqlite3_finalize(sessionStatement) }

            try bind(Int64(missingCount), at: 1, to: sessionStatement)
            try bind(now, at: 2, to: sessionStatement)
            try bind(now, at: 3, to: sessionStatement)
            try bind(sessionID.uuidString, at: 4, to: sessionStatement)
            try step(sessionStatement)

            try execute("COMMIT;")
            return try progress(for: sessionID)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func commitFastFeature(
        sessionID: UUID,
        item: DiscoveredPhoto,
        feature: FastFeatureResult,
        thumbnail: ThumbnailObject
    ) throws -> ScanProgressSnapshot {
        let algorithmVersion = "fast-v1"
        let record = FastFeatureRecord(
            sourceFingerprint: item.sourceFingerprint,
            contentHash: feature.contentHash,
            quickFingerprint: feature.quickFingerprint,
            perceptualHash: feature.perceptualHash,
            thumbnailRelativePath: thumbnail.relativePath,
            width: feature.width,
            height: feature.height
        )
        let encodedRecord = try JSONEncoder().encode(record)

        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            let previousThumbnailPath = try thumbnailPath(
                assetID: item.assetID,
                algorithmVersion: algorithmVersion
            )
            if let contentHash = feature.contentHash {
                try updateAssetContentHash(
                    assetID: item.assetID,
                    sourceFingerprint: item.sourceFingerprint,
                    contentHash: contentHash
                )
            }
            try upsertFeature(
                assetID: item.assetID,
                algorithmVersion: algorithmVersion,
                value: encodedRecord
            )
            try upsertCacheObject(
                objectKey: thumbnail.key,
                relativePath: thumbnail.relativePath,
                sizeBytes: Int64(feature.thumbnailData.count),
                sourceFingerprint: item.sourceFingerprint,
                algorithmVersion: algorithmVersion
            )
            if let previousThumbnailPath,
               previousThumbnailPath != thumbnail.relativePath
            {
                try decrementCacheObject(relativePath: previousThumbnailPath)
            }
            try markFastFeatureTaskCommitted(
                sessionID: sessionID,
                item: item
            )
            try updateFastFeatureProgress(
                sessionID: sessionID,
                lastPath: item.path
            )
            try execute("COMMIT;")
            return try progress(for: sessionID)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func reuseFastFeature(
        sessionID: UUID,
        item: DiscoveredPhoto
    ) throws -> ScanProgressSnapshot {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try markFastFeatureTaskCommitted(sessionID: sessionID, item: item)
            try updateFastFeatureProgress(
                sessionID: sessionID,
                lastPath: item.path
            )
            try execute("COMMIT;")
            return try progress(for: sessionID)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func unreferencedCacheObjects(limit: Int) throws -> [CacheObjectRecord] {
        let statement = try prepare(
            """
            SELECT object_key, relative_path
            FROM cache_objects
            WHERE reference_count <= 0
            ORDER BY last_accessed_at ASC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(Int64(max(limit, 0)), at: 1, to: statement)
        var objects: [CacheObjectRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, index: 0),
                  let relativePath = columnText(statement, index: 1)
            else {
                continue
            }
            objects.append(CacheObjectRecord(key: key, relativePath: relativePath))
        }
        return objects
    }

    func removeCacheObject(_ key: String) throws {
        let statement = try prepare(
            """
            DELETE FROM cache_objects
            WHERE object_key = ? AND reference_count <= 0;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(key, at: 1, to: statement)
        try step(statement)
    }

    func replaceResultIndex(
        groups: [DuplicateGroupRecord],
        candidates: [SimilarityCandidateRecord]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try execute(
                """
                CREATE TEMP TABLE IF NOT EXISTS current_similarity_candidates (
                    id TEXT PRIMARY KEY NOT NULL
                );
                DELETE FROM current_similarity_candidates;
                """
            )
            let currentCandidateStatement = try prepare(
                """
                INSERT OR IGNORE INTO current_similarity_candidates (id)
                VALUES (?);
                """
            )
            defer { sqlite3_finalize(currentCandidateStatement) }
            for candidate in candidates {
                guard sqlite3_reset(currentCandidateStatement) == SQLITE_OK else {
                    throw IndexPhotosError.database("重置相似候选临时语句失败")
                }
                sqlite3_clear_bindings(currentCandidateStatement)
                try bind(candidate.id, at: 1, to: currentCandidateStatement)
                try step(currentCandidateStatement)
            }

            try execute(
                """
                DELETE FROM duplicate_members
                WHERE group_id IN (
                    SELECT id FROM duplicate_groups
                    WHERE algorithm_version = 'exact-v1'
                );
                """
            )
            try execute(
                "DELETE FROM duplicate_groups WHERE algorithm_version = 'exact-v1';"
            )
            try execute(
                """
                DELETE FROM similarity_candidates
                WHERE algorithm_version IN ('fast-phash-v1', 'vision-hnsw-v1')
                  AND id NOT IN (
                      SELECT id FROM current_similarity_candidates
                  )
                  AND id NOT IN (
                      SELECT candidate_id FROM review_decisions
                  );
                """
            )

            for group in groups {
                try insertDuplicateGroup(group)
                for assetID in group.assetIDs {
                    try insertDuplicateMember(groupID: group.id, assetID: assetID)
                }
            }
            for candidate in candidates {
                try upsertSimilarityCandidate(candidate)
            }
            try execute("DELETE FROM current_similarity_candidates;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func resultSummary() throws -> ResultIndexSummary {
        let statement = try prepare(
            """
            SELECT
                (SELECT COUNT(*) FROM duplicate_groups
                 WHERE algorithm_version = 'exact-v1'),
                (SELECT COUNT(*) FROM similarity_candidates
                 WHERE algorithm_version IN ('fast-phash-v1', 'vision-hnsw-v1'));
            """
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexPhotosError.database("读取扫描结果统计失败")
        }
        return ResultIndexSummary(
            duplicateGroupCount: Int(sqlite3_column_int64(statement, 0)),
            similarityCandidateCount: Int(sqlite3_column_int64(statement, 1))
        )
    }

    func similarityCandidates(
        rootID: UUID? = nil,
        includeReviewed: Bool = false,
        limit: Int = 500
    ) throws -> [SimilarityReviewItem] {
        let statement = try prepare(
            """
            SELECT
                c.id,
                a.id, a.path, a.source_fingerprint, fa.value,
                b.id, b.path, b.source_fingerprint, fb.value,
                c.relation_kind, c.score, c.evidence_json,
                c.algorithm_version, d.decision
            FROM similarity_candidates AS c
            JOIN assets AS a ON a.id = c.asset_a_id
            JOIN assets AS b ON b.id = c.asset_b_id
            LEFT JOIN asset_features AS fa
                ON fa.asset_id = a.id
               AND fa.feature_kind = 'fast_features'
               AND fa.algorithm_version = 'fast-v1'
            LEFT JOIN asset_features AS fb
                ON fb.asset_id = b.id
               AND fb.feature_kind = 'fast_features'
               AND fb.algorithm_version = 'fast-v1'
            LEFT JOIN review_decisions AS d ON d.candidate_id = c.id
            WHERE a.state = 'active'
              AND b.state = 'active'
              AND (? IS NULL OR a.root_id = ?)
              AND (? = 1 OR d.decision IS NULL)
            ORDER BY c.score DESC, c.id ASC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let rootValue = rootID?.uuidString
        try bind(rootValue, at: 1, to: statement)
        try bind(rootValue, at: 2, to: statement)
        try bind(Int64(includeReviewed ? 1 : 0), at: 3, to: statement)
        try bind(Int64(max(limit, 0)), at: 4, to: statement)

        var candidates: [SimilarityReviewItem] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw IndexPhotosError.database("读取相似候选失败")
            }
            guard let candidateID = columnText(statement, index: 0),
                  let assetAID = columnText(statement, index: 1),
                  let assetAPath = columnText(statement, index: 2),
                  let assetASourceFingerprint = columnText(statement, index: 3),
                  let assetBID = columnText(statement, index: 5),
                  let assetBPath = columnText(statement, index: 6),
                  let assetBSourceFingerprint = columnText(statement, index: 7),
                  let relationKind = columnText(statement, index: 9),
                  let evidenceJSON = columnText(statement, index: 11),
                  let algorithmVersion = columnText(statement, index: 12)
            else {
                continue
            }

            let decision: ReviewDecision?
            if let decisionValue = columnText(statement, index: 13) {
                guard let decodedDecision = ReviewDecision(rawValue: decisionValue) else {
                    throw IndexPhotosError.database("未知审核决定：\(decisionValue)")
                }
                decision = decodedDecision
            } else {
                decision = nil
            }

            let thumbnailAPath = decodeThumbnailPath(
                from: columnData(statement, index: 4)
            )
            let thumbnailBPath = decodeThumbnailPath(
                from: columnData(statement, index: 8)
            )
            candidates.append(
                SimilarityReviewItem(
                    id: candidateID,
                    assetAID: assetAID,
                    assetAPath: assetAPath,
                    assetASourceFingerprint: assetASourceFingerprint,
                    thumbnailARelativePath: thumbnailAPath,
                    assetBID: assetBID,
                    assetBPath: assetBPath,
                    assetBSourceFingerprint: assetBSourceFingerprint,
                    thumbnailBRelativePath: thumbnailBPath,
                    relationKind: relationKind,
                    score: sqlite3_column_double(statement, 10),
                    evidenceJSON: evidenceJSON,
                    algorithmVersion: algorithmVersion,
                    decision: decision
                )
            )
        }
        return candidates
    }

    func updateSimilarityEvidence(
        candidateID: String,
        evidenceJSON: String
    ) throws {
        let statement = try prepare(
            """
            UPDATE similarity_candidates
            SET evidence_json = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(evidenceJSON, at: 1, to: statement)
        try bind(candidateID, at: 2, to: statement)
        try step(statement)
        guard sqlite3_changes(database) > 0 else {
            throw IndexPhotosError.invalidState("相似候选不存在：\(candidateID)")
        }
    }

    func setReviewDecision(
        candidateID: String,
        decision: ReviewDecision,
        note: String? = nil
    ) throws {
        guard let database else {
            throw IndexPhotosError.database("数据库连接已关闭")
        }
        let statement = try prepare(
            """
            INSERT INTO review_decisions (
                candidate_id, decision, note, updated_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(candidate_id) DO UPDATE SET
                decision = excluded.decision,
                note = excluded.note,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(candidateID, at: 1, to: statement)
        try bind(decision.rawValue, at: 2, to: statement)
        try bind(note, at: 3, to: statement)
        try bind(timestamp(.now), at: 4, to: statement)
        try step(statement)
        guard sqlite3_changes(database) > 0 else {
            throw IndexPhotosError.invalidState("相似候选不存在：\(candidateID)")
        }
    }

    func clearReviewDecision(candidateID: String) throws {
        let statement = try prepare(
            """
            DELETE FROM review_decisions
            WHERE candidate_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(candidateID, at: 1, to: statement)
        try step(statement)
    }

    func recordFeatureFailure(
        sessionID: UUID,
        item: DiscoveredPhoto,
        message: String
    ) throws -> ScanProgressSnapshot {
        let statement = try prepare(
            """
            UPDATE scan_items
            SET status = 'retryable_failed',
                attempt_count = attempt_count + 1,
                error_message = ?,
                heartbeat_at = NULL,
                updated_at = ?
            WHERE session_id = ? AND asset_id = ? AND phase = 'fast_features';
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(message, at: 1, to: statement)
        try bind(now, at: 2, to: statement)
        try bind(sessionID.uuidString, at: 3, to: statement)
        try bind(item.assetID, at: 4, to: statement)
        try step(statement)
        try updateFastFeatureProgress(sessionID: sessionID, lastPath: item.path)
        return try progress(for: sessionID)
    }

    func commitEnumerationBatch(
        sessionID: UUID,
        items: [DiscoveredPhoto],
        lastPath: String?
    ) throws -> ScanProgressSnapshot {
        guard !items.isEmpty else {
            return try progress(for: sessionID)
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            for item in items {
                try upsertAsset(item)
                try upsertScanItem(item, sessionID: sessionID)
            }

            let now = timestamp(.now)
            let updateStatement = try prepare(
                """
                UPDATE scan_sessions
                SET discovered_count = (
                        SELECT COUNT(*) FROM scan_items
                        WHERE session_id = ? AND phase = 'enumerate'
                    ),
                    committed_count = (
                        SELECT COUNT(*) FROM scan_items
                        WHERE session_id = ? AND phase = 'enumerate' AND status = 'committed'
                    ),
                    total_bytes = COALESCE((
                        SELECT SUM(size_bytes) FROM scan_items
                        WHERE session_id = ? AND phase = 'enumerate'
                    ), 0),
                    last_path_hint = ?,
                    last_checkpoint_at = ?,
                    heartbeat_at = ?,
                    updated_at = ?
                WHERE id = ?;
                """
            )
            defer { sqlite3_finalize(updateStatement) }

            try bind(sessionID.uuidString, at: 1, to: updateStatement)
            try bind(sessionID.uuidString, at: 2, to: updateStatement)
            try bind(sessionID.uuidString, at: 3, to: updateStatement)
            try bind(lastPath, at: 4, to: updateStatement)
            try bind(now, at: 5, to: updateStatement)
            try bind(now, at: 6, to: updateStatement)
            try bind(now, at: 7, to: updateStatement)
            try bind(sessionID.uuidString, at: 8, to: updateStatement)
            try step(updateStatement)

            try execute("COMMIT;")
            return try progress(for: sessionID)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func recordScanFailure(
        sessionID: UUID,
        path: String,
        message: String
    ) throws -> ScanProgressSnapshot {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET failed_count = failed_count + 1,
                last_path_hint = ?,
                last_error = ?,
                heartbeat_at = ?,
                updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(path, at: 1, to: statement)
        try bind(message, at: 2, to: statement)
        try bind(now, at: 3, to: statement)
        try bind(now, at: 4, to: statement)
        try bind(sessionID.uuidString, at: 5, to: statement)
        try step(statement)
        return try progress(for: sessionID)
    }

    func finishEnumeration(
        _ sessionID: UUID,
        finalPhase: ScanPhase = .fastFeatures
    ) throws -> ScanProgressSnapshot {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET status = 'completed', phase = ?, is_total_known = 1,
                processed_bytes = COALESCE((
                    SELECT SUM(size_bytes) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features' AND status = 'committed'
                ), 0),
                last_checkpoint_at = ?,
                heartbeat_at = NULL, updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(finalPhase.rawValue, at: 1, to: statement)
        try bind(sessionID.uuidString, at: 2, to: statement)
        try bind(now, at: 3, to: statement)
        try bind(now, at: 4, to: statement)
        try bind(sessionID.uuidString, at: 5, to: statement)
        try step(statement)
        return try progress(for: sessionID)
    }

    func pauseSession(_ sessionID: UUID) throws -> ScanProgressSnapshot {
        try updateStatus(sessionID, status: .paused)
        return try progress(for: sessionID)
    }

    func cancelSession(_ sessionID: UUID) throws -> ScanProgressSnapshot {
        try updateStatus(sessionID, status: .cancelled)
        return try progress(for: sessionID)
    }

    func failSession(_ sessionID: UUID, message: String) throws -> ScanProgressSnapshot {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET status = 'failed', last_error = ?, heartbeat_at = NULL, updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(message, at: 1, to: statement)
        try bind(now, at: 2, to: statement)
        try bind(sessionID.uuidString, at: 3, to: statement)
        try step(statement)
        return try progress(for: sessionID)
    }

    func progress(for sessionID: UUID) throws -> ScanProgressSnapshot {
        let statement = try prepare(
            """
            SELECT status, phase, discovered_count, committed_count, failed_count,
                   missing_count, total_bytes, processed_bytes, is_total_known,
                   last_path_hint, last_error, updated_at
            FROM scan_sessions WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID.uuidString, at: 1, to: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexPhotosError.database("找不到扫描会话 \(sessionID.uuidString)")
        }

        return try ScanProgressSnapshot(
            scanID: sessionID,
            status: decodeStatus(columnText(statement, index: 0)),
            phase: decodePhase(columnText(statement, index: 1)),
            discoveredCount: Int(sqlite3_column_int64(statement, 2)),
            committedCount: Int(sqlite3_column_int64(statement, 3)),
            failedCount: Int(sqlite3_column_int64(statement, 4)),
            missingCount: Int(sqlite3_column_int64(statement, 5)),
            totalBytes: sqlite3_column_int64(statement, 6),
            processedBytes: sqlite3_column_int64(statement, 7),
            isTotalKnown: sqlite3_column_int(statement, 8) != 0,
            lastPath: columnText(statement, index: 9),
            lastError: columnText(statement, index: 10),
            updatedAt: parseTimestamp(columnText(statement, index: 11))
        )
    }

    func latestResumableScan() throws -> ResumableScan? {
        let statement = try prepare(
            """
            SELECT s.id, s.root_id, r.path, r.bookmark_data, s.status, s.phase,
                   s.discovered_count, s.committed_count, s.failed_count, s.updated_at
            FROM scan_sessions AS s
            JOIN roots AS r ON r.id = s.root_id
            WHERE s.status IN ('paused', 'recovering')
            ORDER BY s.updated_at DESC LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = UUID(uuidString: columnText(statement, index: 0) ?? ""),
              let rootID = UUID(uuidString: columnText(statement, index: 1) ?? ""),
              let path = columnText(statement, index: 2),
              let status = try? decodeStatus(columnText(statement, index: 4)),
              let phase = try? decodePhase(columnText(statement, index: 5))
        else {
            return nil
        }

        return ResumableScan(
            id: id,
            rootID: rootID,
            rootURL: URL(fileURLWithPath: path, isDirectory: true),
            bookmarkData: columnData(statement, index: 3),
            status: status,
            phase: phase,
            discoveredCount: Int(sqlite3_column_int64(statement, 6)),
            committedCount: Int(sqlite3_column_int64(statement, 7)),
            failedCount: Int(sqlite3_column_int64(statement, 8)),
            updatedAt: parseTimestamp(columnText(statement, index: 9))
        )
    }

    private func updateStatus(_ sessionID: UUID, status: ScanSessionStatus) throws {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET status = ?, heartbeat_at = NULL, updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(status.rawValue, at: 1, to: statement)
        try bind(timestamp(.now), at: 2, to: statement)
        try bind(sessionID.uuidString, at: 3, to: statement)
        try step(statement)
    }

    private func upsertAsset(_ item: DiscoveredPhoto) throws {
        let statement = try prepare(
            """
            INSERT INTO assets (
                id, root_id, path, file_resource_id, size_bytes, modified_at,
                source_fingerprint, state, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                file_resource_id = excluded.file_resource_id,
                size_bytes = excluded.size_bytes,
                modified_at = excluded.modified_at,
                content_hash = CASE
                    WHEN assets.source_fingerprint = excluded.source_fingerprint
                    THEN assets.content_hash
                    ELSE NULL
                END,
                source_fingerprint = excluded.source_fingerprint,
                state = 'active',
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(item.assetID, at: 1, to: statement)
        try bind(item.rootID.uuidString, at: 2, to: statement)
        try bind(item.path, at: 3, to: statement)
        try bind(item.fileResourceID, at: 4, to: statement)
        try bind(item.sizeBytes, at: 5, to: statement)
        try bind(item.modifiedAt.map(timestamp), at: 6, to: statement)
        try bind(item.sourceFingerprint, at: 7, to: statement)
        try bind(timestamp(.now), at: 8, to: statement)
        try step(statement)
    }

    private func upsertScanItem(_ item: DiscoveredPhoto, sessionID: UUID) throws {
        let statement = try prepare(
            """
            INSERT INTO scan_items (
                session_id, asset_id, phase, status, source_path,
                source_fingerprint, size_bytes, modified_at, updated_at
            ) VALUES (?, ?, 'enumerate', 'committed', ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, asset_id, phase) DO UPDATE SET
                source_path = excluded.source_path,
                source_fingerprint = excluded.source_fingerprint,
                size_bytes = excluded.size_bytes,
                modified_at = excluded.modified_at,
                status = CASE
                    WHEN scan_items.source_fingerprint = excluded.source_fingerprint
                    THEN scan_items.status
                    ELSE 'committed'
                END,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(sessionID.uuidString, at: 1, to: statement)
        try bind(item.assetID, at: 2, to: statement)
        try bind(item.path, at: 3, to: statement)
        try bind(item.sourceFingerprint, at: 4, to: statement)
        try bind(item.sizeBytes, at: 5, to: statement)
        try bind(item.modifiedAt.map(timestamp), at: 6, to: statement)
        try bind(timestamp(.now), at: 7, to: statement)
        try step(statement)
    }

    private func upsertFastFeatureTask(
        _ item: DiscoveredPhoto,
        sessionID: UUID
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO scan_items (
                session_id, asset_id, phase, status, source_path,
                source_fingerprint, size_bytes, modified_at, updated_at
            ) VALUES (?, ?, 'fast_features', 'pending', ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, asset_id, phase) DO UPDATE SET
                source_path = excluded.source_path,
                source_fingerprint = excluded.source_fingerprint,
                size_bytes = excluded.size_bytes,
                modified_at = excluded.modified_at,
                status = CASE
                    WHEN scan_items.source_fingerprint = excluded.source_fingerprint
                    THEN scan_items.status
                    ELSE 'pending'
                END,
                error_message = CASE
                    WHEN scan_items.source_fingerprint = excluded.source_fingerprint
                    THEN scan_items.error_message
                    ELSE NULL
                END,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(sessionID.uuidString, at: 1, to: statement)
        try bind(item.assetID, at: 2, to: statement)
        try bind(item.path, at: 3, to: statement)
        try bind(item.sourceFingerprint, at: 4, to: statement)
        try bind(item.sizeBytes, at: 5, to: statement)
        try bind(item.modifiedAt.map(timestamp), at: 6, to: statement)
        try bind(timestamp(.now), at: 7, to: statement)
        try step(statement)
    }

    private func updateFastFeatureProgress(
        sessionID: UUID,
        lastPath: String?
    ) throws {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET phase = 'fast_features',
                last_path_hint = ?, last_checkpoint_at = ?,
                heartbeat_at = ?, updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        let now = timestamp(.now)
        try bind(lastPath, at: 1, to: statement)
        try bind(now, at: 2, to: statement)
        try bind(now, at: 3, to: statement)
        try bind(now, at: 4, to: statement)
        try bind(sessionID.uuidString, at: 5, to: statement)
        try step(statement)
    }

    private func reconcileFastFeatureProgress(_ sessionID: UUID) throws {
        let statement = try prepare(
            """
            UPDATE scan_sessions
            SET discovered_count = (
                    SELECT COUNT(*) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features'
                ),
                committed_count = (
                    SELECT COUNT(*) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features' AND status = 'committed'
                ),
                failed_count = (
                    SELECT COUNT(*) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features'
                      AND status IN ('retryable_failed', 'permanent_failed')
                ),
                total_bytes = COALESCE((
                    SELECT SUM(size_bytes) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features'
                ), 0),
                processed_bytes = COALESCE((
                    SELECT SUM(size_bytes) FROM scan_items
                    WHERE session_id = ? AND phase = 'fast_features' AND status = 'committed'
                ), 0)
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        for index in 1 ... 6 {
            try bind(sessionID.uuidString, at: Int32(index), to: statement)
        }
        try step(statement)
    }

    private func updateAssetContentHash(
        assetID: String,
        sourceFingerprint: String,
        contentHash: String
    ) throws {
        let statement = try prepare(
            """
            UPDATE assets
            SET content_hash = ?, source_fingerprint = ?, updated_at = ?
            WHERE id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(contentHash, at: 1, to: statement)
        try bind(sourceFingerprint, at: 2, to: statement)
        try bind(timestamp(.now), at: 3, to: statement)
        try bind(assetID, at: 4, to: statement)
        try step(statement)
    }

    private func upsertFeature(
        assetID: String,
        featureKind: String = "fast_features",
        algorithmVersion: String,
        value: Data
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO asset_features (
                asset_id, feature_kind, algorithm_version, value, created_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(asset_id, feature_kind, algorithm_version) DO UPDATE SET
                value = excluded.value,
                created_at = excluded.created_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(assetID, at: 1, to: statement)
        try bind(featureKind, at: 2, to: statement)
        try bind(algorithmVersion, at: 3, to: statement)
        try bind(value, at: 4, to: statement)
        try bind(timestamp(.now), at: 5, to: statement)
        try step(statement)
    }

    private func thumbnailPath(
        assetID: String,
        algorithmVersion: String
    ) throws -> String? {
        let statement = try prepare(
            """
            SELECT value
            FROM asset_features
            WHERE asset_id = ? AND feature_kind = 'fast_features'
              AND algorithm_version = ?
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(assetID, at: 1, to: statement)
        try bind(algorithmVersion, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let data = columnData(statement, index: 0),
              let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: data)
        else {
            return nil
        }
        return record.thumbnailRelativePath
    }

    private func decodeThumbnailPath(from data: Data?) -> String? {
        guard let data,
              let record = try? JSONDecoder().decode(FastFeatureRecord.self, from: data),
              !record.thumbnailRelativePath.isEmpty
        else {
            return nil
        }
        return record.thumbnailRelativePath
    }

    private func decrementCacheObject(relativePath: String) throws {
        let statement = try prepare(
            """
            UPDATE cache_objects
            SET reference_count = MAX(reference_count - 1, 0)
            WHERE relative_path = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(relativePath, at: 1, to: statement)
        try step(statement)
    }

    private func upsertCacheObject(
        objectKey: String,
        relativePath: String,
        sizeBytes: Int64,
        sourceFingerprint: String,
        algorithmVersion: String
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO cache_objects (
                object_key, kind, relative_path, size_bytes, reference_count,
                last_accessed_at, source_fingerprint, algorithm_version
            ) VALUES (?, 'thumbnail_small', ?, ?, 1, ?, ?, ?)
            ON CONFLICT(object_key) DO UPDATE SET
                relative_path = excluded.relative_path,
                size_bytes = excluded.size_bytes,
                reference_count = MAX(cache_objects.reference_count, 1),
                last_accessed_at = excluded.last_accessed_at,
                source_fingerprint = excluded.source_fingerprint,
                algorithm_version = excluded.algorithm_version;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(objectKey, at: 1, to: statement)
        try bind(relativePath, at: 2, to: statement)
        try bind(sizeBytes, at: 3, to: statement)
        try bind(timestamp(.now), at: 4, to: statement)
        try bind(sourceFingerprint, at: 5, to: statement)
        try bind(algorithmVersion, at: 6, to: statement)
        try step(statement)
    }

    private func markFastFeatureTaskCommitted(
        sessionID: UUID,
        item: DiscoveredPhoto
    ) throws {
        let statement = try prepare(
            """
            UPDATE scan_items
            SET status = 'committed', error_message = NULL,
                heartbeat_at = NULL, updated_at = ?
            WHERE session_id = ? AND asset_id = ? AND phase = 'fast_features';
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(timestamp(.now), at: 1, to: statement)
        try bind(sessionID.uuidString, at: 2, to: statement)
        try bind(item.assetID, at: 3, to: statement)
        try step(statement)
    }

    private func insertDuplicateGroup(_ group: DuplicateGroupRecord) throws {
        let statement = try prepare(
            """
            INSERT INTO duplicate_groups (
                id, confidence, algorithm_version, created_at
            ) VALUES (?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(group.id, at: 1, to: statement)
        try bind(group.confidence, at: 2, to: statement)
        try bind(group.algorithmVersion, at: 3, to: statement)
        try bind(timestamp(.now), at: 4, to: statement)
        try step(statement)
    }

    private func insertDuplicateMember(groupID: String, assetID: String) throws {
        let statement = try prepare(
            """
            INSERT INTO duplicate_members (group_id, asset_id)
            VALUES (?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(groupID, at: 1, to: statement)
        try bind(assetID, at: 2, to: statement)
        try step(statement)
    }

    private func upsertSimilarityCandidate(
        _ candidate: SimilarityCandidateRecord
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO similarity_candidates (
                id, asset_a_id, asset_b_id, relation_kind, score,
                evidence_json, algorithm_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(asset_a_id, asset_b_id, algorithm_version) DO UPDATE SET
                relation_kind = excluded.relation_kind,
                score = excluded.score,
                evidence_json = CASE
                    WHEN instr(similarity_candidates.evidence_json, '"geometry"') > 0
                    THEN similarity_candidates.evidence_json
                    ELSE excluded.evidence_json
                END,
                created_at = excluded.created_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(candidate.id, at: 1, to: statement)
        try bind(candidate.assetAID, at: 2, to: statement)
        try bind(candidate.assetBID, at: 3, to: statement)
        try bind(candidate.relationKind, at: 4, to: statement)
        try bind(candidate.score, at: 5, to: statement)
        try bind(candidate.evidenceJSON, at: 6, to: statement)
        try bind(candidate.algorithmVersion, at: 7, to: statement)
        try bind(timestamp(.now), at: 8, to: statement)
        try step(statement)
    }

    private static func createSchema(_ database: OpaquePointer) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS cache_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS roots (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                path TEXT NOT NULL,
                bookmark_data BLOB,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS scan_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                root_id TEXT NOT NULL REFERENCES roots(id),
                status TEXT NOT NULL,
                phase TEXT NOT NULL,
                phase_version INTEGER NOT NULL,
                discovered_count INTEGER NOT NULL DEFAULT 0,
                committed_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0,
                missing_count INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                processed_bytes INTEGER NOT NULL DEFAULT 0,
                is_total_known INTEGER NOT NULL DEFAULT 0,
                last_path_hint TEXT,
                last_error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_checkpoint_at TEXT,
                heartbeat_at TEXT
            );

            CREATE TABLE IF NOT EXISTS scan_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES scan_sessions(id),
                asset_id TEXT NOT NULL,
                phase TEXT NOT NULL,
                status TEXT NOT NULL,
                source_path TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                modified_at TEXT,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                staged_manifest_path TEXT,
                error_message TEXT,
                heartbeat_at TEXT,
                updated_at TEXT NOT NULL,
                UNIQUE(session_id, asset_id, phase)
            );

            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY NOT NULL,
                root_id TEXT NOT NULL REFERENCES roots(id),
                path TEXT NOT NULL,
                file_resource_id TEXT,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                modified_at TEXT,
                source_fingerprint TEXT NOT NULL,
                content_hash TEXT,
                state TEXT NOT NULL DEFAULT 'active',
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS asset_features (
                asset_id TEXT NOT NULL REFERENCES assets(id),
                feature_kind TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                value BLOB NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(asset_id, feature_kind, algorithm_version)
            );

            CREATE TABLE IF NOT EXISTS duplicate_groups (
                id TEXT PRIMARY KEY NOT NULL,
                confidence REAL NOT NULL,
                algorithm_version TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS duplicate_members (
                group_id TEXT NOT NULL REFERENCES duplicate_groups(id),
                asset_id TEXT NOT NULL REFERENCES assets(id),
                PRIMARY KEY(group_id, asset_id)
            );

            CREATE TABLE IF NOT EXISTS similarity_candidates (
                id TEXT PRIMARY KEY NOT NULL,
                asset_a_id TEXT NOT NULL REFERENCES assets(id),
                asset_b_id TEXT NOT NULL REFERENCES assets(id),
                relation_kind TEXT NOT NULL,
                score REAL NOT NULL,
                evidence_json TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(asset_a_id, asset_b_id, algorithm_version)
            );

            CREATE TABLE IF NOT EXISTS review_decisions (
                candidate_id TEXT PRIMARY KEY NOT NULL REFERENCES similarity_candidates(id),
                decision TEXT NOT NULL,
                note TEXT,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS cache_objects (
                object_key TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                reference_count INTEGER NOT NULL DEFAULT 0,
                last_accessed_at TEXT NOT NULL,
                source_fingerprint TEXT,
                algorithm_version TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_scan_sessions_status
                ON scan_sessions(status, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_scan_items_session_status
                ON scan_items(session_id, status);
            CREATE INDEX IF NOT EXISTS idx_assets_root_state
                ON assets(root_id, state);

            CREATE TRIGGER IF NOT EXISTS fast_feature_progress_insert
            AFTER INSERT ON scan_items WHEN NEW.phase = 'fast_features'
            BEGIN
                UPDATE scan_sessions SET
                    discovered_count = discovered_count + 1,
                    committed_count = committed_count + (NEW.status = 'committed'),
                    failed_count = failed_count + (NEW.status IN ('retryable_failed', 'permanent_failed')),
                    total_bytes = total_bytes + NEW.size_bytes,
                    processed_bytes = processed_bytes + NEW.size_bytes * (NEW.status = 'committed')
                WHERE id = NEW.session_id;
            END;

            CREATE TRIGGER IF NOT EXISTS fast_feature_progress_update
            AFTER UPDATE OF status, size_bytes ON scan_items WHEN NEW.phase = 'fast_features'
            BEGIN
                UPDATE scan_sessions SET
                    committed_count = committed_count + (NEW.status = 'committed') - (OLD.status = 'committed'),
                    failed_count = failed_count
                        + (NEW.status IN ('retryable_failed', 'permanent_failed'))
                        - (OLD.status IN ('retryable_failed', 'permanent_failed')),
                    total_bytes = total_bytes + NEW.size_bytes - OLD.size_bytes,
                    processed_bytes = processed_bytes
                        + NEW.size_bytes * (NEW.status = 'committed')
                        - OLD.size_bytes * (OLD.status = 'committed')
                WHERE id = NEW.session_id;
            END;

            CREATE TRIGGER IF NOT EXISTS fast_feature_progress_delete
            AFTER DELETE ON scan_items WHEN OLD.phase = 'fast_features'
            BEGIN
                UPDATE scan_sessions SET
                    discovered_count = discovered_count - 1,
                    committed_count = committed_count - (OLD.status = 'committed'),
                    failed_count = failed_count - (OLD.status IN ('retryable_failed', 'permanent_failed')),
                    total_bytes = total_bytes - OLD.size_bytes,
                    processed_bytes = processed_bytes - OLD.size_bytes * (OLD.status = 'committed')
                WHERE id = OLD.session_id;
            END;

            INSERT OR IGNORE INTO cache_meta (key, value)
                VALUES ('schema_version', '1');
            """
        )
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw IndexPhotosError.database("数据库连接已关闭")
        }
        try Self.execute(database, sql)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw IndexPhotosError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw IndexPhotosError.database("数据库连接已关闭")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw IndexPhotosError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard let database else {
            throw IndexPhotosError.database("数据库连接已关闭")
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexPhotosError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32 = if let value {
            value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }

        guard result == SQLITE_OK else {
            throw IndexPhotosError.database("绑定文本参数失败")
        }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw IndexPhotosError.database("绑定整数参数失败")
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw IndexPhotosError.database("绑定小数参数失败")
        }
    }

    private func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw IndexPhotosError.database("绑定空数据参数失败")
            }
            return
        }

        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw IndexPhotosError.database("绑定二进制参数失败")
        }
    }

    private func bind(_ value: Date?, at index: Int32, to statement: OpaquePointer) throws {
        try bind(value.map(timestamp), at: index, to: statement)
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        let length = sqlite3_column_bytes(statement, index)
        guard length > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: pointer, count: Int(length))
    }

    private func decodeStatus(_ value: String?) throws -> ScanSessionStatus {
        guard let value, let status = ScanSessionStatus(rawValue: value) else {
            throw IndexPhotosError.database("未知扫描状态 \(value ?? "nil")")
        }
        return status
    }

    private func decodePhase(_ value: String?) throws -> ScanPhase {
        guard let value, let phase = ScanPhase(rawValue: value) else {
            throw IndexPhotosError.database("未知扫描阶段 \(value ?? "nil")")
        }
        return phase
    }

    private func timestamp(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func parseTimestamp(_ value: String?) -> Date {
        guard let value else {
            return .now
        }
        return dateFormatter.date(from: value) ?? .now
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
