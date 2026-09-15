use super::{HnswIndex, SearchScratch, bench, level_for_label};

fn legacy_index_bytes() -> Vec<u8> {
    let mut bytes = b"IPHNSW01".to_vec();
    bytes.extend_from_slice(&1_u32.to_le_bytes());
    for value in [2_u64, 2, 4, 1, 0, 2] {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    for (label, vector, levels) in [
        (10_u64, [1.0_f32, 0.0], vec![vec![1_u64], vec![]]),
        (20_u64, [0.0_f32, 1.0], vec![vec![0_u64]]),
    ] {
        bytes.extend_from_slice(&label.to_le_bytes());
        bytes.extend_from_slice(&2_u64.to_le_bytes());
        for value in vector {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.extend_from_slice(&(levels.len() as u64).to_le_bytes());
        for neighbors in levels {
            bytes.extend_from_slice(&(neighbors.len() as u64).to_le_bytes());
            for neighbor in neighbors {
                bytes.extend_from_slice(&neighbor.to_le_bytes());
            }
        }
    }
    bytes
}

#[test]
fn hnsw_preserves_legacy_format_and_supports_more_insertions() {
    let bytes = legacy_index_bytes();
    let mut index = HnswIndex::deserialize(&bytes).expect("应兼容原始 v1 格式");
    assert_eq!(index.serialize(), bytes);
    assert_eq!(index.search(&[1.0, 0.0], 2, 4), vec![(10, 0.0), (20, 1.0)]);
    assert!(index.insert(30, &[0.7, 0.7]));
    let restored = HnswIndex::deserialize(&index.serialize()).expect("追加后的索引应能加载");
    assert_eq!(restored.search(&[0.0, 1.0], 3, 16).len(), 3);
}

#[test]
fn hnsw_rejects_truncated_or_invalid_graphs() {
    let bytes = legacy_index_bytes();
    for length in 0..bytes.len() {
        assert!(HnswIndex::deserialize(&bytes[..length]).is_none());
    }
    for (offset, value) in [
        (12, u64::MAX),
        (20, u64::MAX),
        (44, 1),
        (52, u64::MAX),
        (68, u64::MAX),
        (92, u64::MAX),
        (100, 0),
        (100, 2),
    ] {
        let mut corrupted = bytes.clone();
        corrupted[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
        assert!(
            HnswIndex::deserialize(&corrupted).is_none(),
            "offset={offset}"
        );
    }
    let mut invalid_level = bytes;
    invalid_level[108..116].copy_from_slice(&1_u64.to_le_bytes());
    invalid_level.splice(116..116, 1_u64.to_le_bytes());
    assert!(HnswIndex::deserialize(&invalid_level).is_none());
}

#[test]
fn hnsw_search_handles_invalid_inputs_and_large_limits() {
    let mut index = HnswIndex::new(2, 4, 1);
    assert_eq!(index.construction_ef, 4);
    assert!(index.search(&[1.0, 0.0], 1, 1).is_empty());
    assert!(!index.insert(1, &[f32::NAN, 0.0]));
    assert!(!index.insert(1, &[1.0]));
    assert!(index.insert(1, &[1.0, 0.0]));
    assert!(index.search(&[f32::INFINITY, 0.0], 1, 1).is_empty());
    assert!(index.search(&[1.0], 1, 1).is_empty());
    assert!(index.search(&[1.0, 0.0], 0, 1).is_empty());
    assert_eq!(
        index.search(&[1.0, 0.0], usize::MAX, usize::MAX),
        vec![(1, 0.0)]
    );
    let mut wrong_output = vec![0; index.serialized_length() - 1];
    assert!(index.serialize_into(&mut wrong_output).is_none());
    assert!(wrong_output.iter().all(|&value| value == 0));
}

#[test]
fn hnsw_ffi_writes_only_within_output_capacity() {
    let vector = [1.0_f32, 0.0];
    let index = super::index_photos_hnsw_create(2, 4, 32);
    assert!(!index.is_null());
    // SAFETY: 句柄来自 create，数组在调用期间有效，输出容量与分配一致。
    unsafe {
        assert!(super::index_photos_hnsw_insert(
            index,
            10,
            vector.as_ptr(),
            2
        ));
        let length = super::index_photos_hnsw_serialized_length(index);
        let mut output = vec![0xaa; length + 2];
        assert!(!super::index_photos_hnsw_serialize(
            index,
            output.as_mut_ptr(),
            length - 1
        ));
        assert!(output.iter().all(|&value| value == 0xaa));
        assert!(super::index_photos_hnsw_serialize(
            index,
            output.as_mut_ptr().add(1),
            length
        ));
        assert_eq!(output[0], 0xaa);
        assert_eq!(output[length + 1], 0xaa);
        let restored = super::index_photos_hnsw_deserialize(output.as_ptr().add(1), length);
        assert!(!restored.is_null());
        let mut labels = [u64::MAX; 2];
        let mut distances = [-1.0_f32; 2];
        let count = super::index_photos_hnsw_search(
            restored,
            vector.as_ptr(),
            2,
            usize::MAX,
            usize::MAX,
            labels.as_mut_ptr(),
            distances.as_mut_ptr(),
            1,
        );
        assert_eq!(count, 1);
        assert_eq!(labels, [10, u64::MAX]);
        assert_eq!(distances, [0.0, -1.0]);
        super::index_photos_hnsw_destroy(restored);
        super::index_photos_hnsw_destroy(index);
    }
}

#[test]
fn hnsw_visited_generation_rollover_clears_old_marks() {
    let mut scratch = SearchScratch {
        visited: vec![1, u32::MAX, 0],
        generation: u32::MAX,
        ..SearchScratch::default()
    };
    scratch.reset(3);
    assert_eq!(scratch.generation, 1);
    assert!(scratch.visit(0));
    assert!(!scratch.visit(0));
    assert!(scratch.visit(1));
    scratch.reset(5);
    assert!(scratch.visit(0));
    assert!(scratch.visit(4));
}

#[test]
fn hnsw_layer_density_follows_neighbor_count() {
    let upper_count = (0..100_000)
        .filter(|&label| level_for_label(label, 16) > 0)
        .count();
    assert!(
        (5_800..6_700).contains(&upper_count),
        "upper_count={upper_count}"
    );
}

#[test]
fn hnsw_cosine_distance_matches_f64_reference() {
    for dimension in [1, 2, 7, 8, 9, 64, 127, 128, 768] {
        let vectors = bench::photo_vectors(64, dimension);
        let index = HnswIndex::new(dimension, 16, 96);
        for pair in vectors.windows(2) {
            let dot_product: f64 = pair[0]
                .iter()
                .zip(&pair[1])
                .map(|(&left, &right)| f64::from(left) * f64::from(right))
                .sum();
            let expected = (1.0 - dot_product).max(0.0);
            let actual = f64::from(index.distance(&pair[0], &pair[1]));
            assert!(
                (actual - expected).abs() < 0.000_001,
                "dimension={dimension}"
            );
        }
    }
}

#[test]
fn hnsw_retrieves_dense_photo_clusters_and_bounds_graph_degree() {
    let vectors = bench::photo_vectors(2048, 64);
    let mut index = HnswIndex::new(64, 16, 96);
    for (label, vector) in vectors.iter().enumerate() {
        assert!(index.insert(label as u64, vector));
    }
    let mut recalled = 0;
    for query in vectors.iter().step_by(32) {
        let mut exact: Vec<_> = vectors
            .iter()
            .enumerate()
            .map(|(label, vector)| (label as u64, index.distance(query, vector)))
            .collect();
        exact.sort_unstable_by(|left, right| {
            left.1
                .total_cmp(&right.1)
                .then_with(|| left.0.cmp(&right.0))
        });
        let matches = index.search(query, 24, 96);
        recalled += matches
            .iter()
            .filter(|item| exact[..24].contains(item))
            .count();
    }
    assert!(
        recalled as f64 / (64.0 * 24.0) >= 0.95,
        "recalled={recalled}"
    );
    for (node_index, node) in index.nodes.iter().enumerate() {
        for (level, neighbors) in node.neighbors.iter().enumerate() {
            assert!(neighbors.len() <= index.neighbor_limit(level));
            for &neighbor in neighbors {
                assert_ne!(neighbor as usize, node_index);
                assert!(index.nodes[neighbor as usize].neighbors.len() > level);
            }
        }
    }
    std::thread::scope(|scope| {
        for query in vectors.iter().step_by(512) {
            let expected = index.search(query, 24, 96);
            let index = &index;
            scope.spawn(move || assert_eq!(index.search(query, 24, 96), expected));
        }
    });
    let restored = HnswIndex::deserialize(&index.serialize()).expect("照片簇索引应能加载");
    assert_eq!(
        restored.search(&vectors[1000], 24, 96),
        index.search(&vectors[1000], 24, 96)
    );
}

#[test]
fn hnsw_handles_identical_vectors_deterministically() {
    let mut index = HnswIndex::new(2, 16, 96);
    for label in 0..512 {
        assert!(index.insert(label, &[1.0, 0.0]));
    }
    let matches = index.search(&[1.0, 0.0], 24, 96);
    assert_eq!(matches.len(), 24);
    assert!(matches.iter().all(|item| item.1 == 0.0));
    assert!(matches.windows(2).all(|pair| pair[0].0 < pair[1].0));
    assert_eq!(index.search(&[1.0, 0.0], 24, 96), matches);
}

#[test]
fn hnsw_returns_nearest_vectors() {
    let mut index = HnswIndex::new(2, 4, 32);
    assert!(index.insert(0, &[1.0, 0.0]));
    assert!(index.insert(1, &[0.0, 1.0]));
    assert!(index.insert(2, &[-1.0, 0.0]));
    assert!(index.insert(3, &[0.7, 0.7]));

    let result = index.search(&[0.99, 0.01], 2, 32);

    assert_eq!(result[0].0, 0);
    assert_eq!(result[1].0, 3);
    assert!(result[0].1 < result[1].1);
}

#[test]
fn hnsw_serialization_round_trip_preserves_search() {
    let mut index = HnswIndex::new(2, 4, 32);
    assert!(index.insert(0, &[1.0, 0.0]));
    assert!(index.insert(1, &[0.0, 1.0]));
    assert!(index.insert(2, &[-1.0, 0.0]));
    assert!(index.insert(3, &[0.7, 0.7]));

    let bytes = index.serialize();
    assert_eq!(bytes.len(), index.serialized_length());
    let restored = HnswIndex::deserialize(&bytes).expect("valid HNSW bytes");

    assert_eq!(
        restored.search(&[0.99, 0.01], 3, 32),
        index.search(&[0.99, 0.01], 3, 32)
    );
}
