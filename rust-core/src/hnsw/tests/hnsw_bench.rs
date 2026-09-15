use super::HnswIndex;
use std::mem::size_of_val;
use std::time::Instant;

fn next_value(state: &mut u64) -> f32 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    (*state >> 40) as f32 / (1_u32 << 24) as f32 * 2.0 - 1.0
}

fn normalize(vector: &mut [f32]) {
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    for value in vector {
        *value /= norm;
    }
}

pub(super) fn photo_vectors(count: usize, dimension: usize) -> Vec<Vec<f32>> {
    let mut state = 0x1234_5678_9abc_def0;
    let mut vectors = Vec::with_capacity(count);
    let mut center = vec![0.0; dimension];
    for photo in 0..count {
        if photo % 32 == 0 {
            for value in &mut center {
                *value = next_value(&mut state);
            }
            normalize(&mut center);
        }
        let mut vector: Vec<f32> = center
            .iter()
            .map(|value| value + next_value(&mut state) * 0.03)
            .collect();
        normalize(&mut vector);
        vectors.push(vector);
    }
    vectors
}

#[test]
#[ignore = "使用 cargo test --release hnsw_photo_benchmark -- --ignored --nocapture 运行"]
fn hnsw_photo_benchmark() {
    let count = std::env::var("HNSW_BENCH_COUNT")
        .unwrap_or_else(|_| "10000".to_owned())
        .parse::<usize>()
        .expect("HNSW_BENCH_COUNT 必须是正整数");
    let dimension = std::env::var("HNSW_BENCH_DIM")
        .unwrap_or_else(|_| "128".to_owned())
        .parse::<usize>()
        .expect("HNSW_BENCH_DIM 必须是正整数");
    assert!(count >= 100 && dimension > 0);
    let search_ef = std::env::var("HNSW_BENCH_EF")
        .unwrap_or_else(|_| "96".to_owned())
        .parse::<usize>()
        .expect("HNSW_BENCH_EF 必须是正整数");
    assert!(search_ef > 0);

    let vectors = photo_vectors(count, dimension);
    let mut index = HnswIndex::new(dimension, 16, 96);
    let started = Instant::now();
    for (label, vector) in vectors.iter().enumerate() {
        assert!(index.insert(label as u64, vector));
    }
    let build_secs = started.elapsed().as_secs_f64();
    let mut query_micros = Vec::new();
    let mut recalled = 0;
    let mut state = 0xfedc_ba98_7654_3210;
    for sample in 0..100 {
        let mut query = vectors[sample * count / 100].clone();
        for value in &mut query {
            *value += next_value(&mut state) * 0.005;
        }
        normalize(&mut query);
        let mut exact: Vec<(usize, f32)> = vectors
            .iter()
            .enumerate()
            .map(|(label, vector)| (label, index.distance(&query, vector)))
            .collect();
        exact.sort_unstable_by(|left, right| {
            left.1
                .total_cmp(&right.1)
                .then_with(|| left.0.cmp(&right.0))
        });
        let started = Instant::now();
        let matches = index.search(&query, 24, search_ef);
        query_micros.push(started.elapsed().as_secs_f64() * 1_000_000.0);
        recalled += matches
            .iter()
            .filter(|item| {
                exact[..24]
                    .iter()
                    .any(|candidate| candidate.0 as u64 == item.0)
            })
            .count();
    }
    query_micros.sort_unstable_by(f64::total_cmp);
    let graph_bytes: usize = index
        .nodes
        .iter()
        .map(|node| {
            size_of_val(node.vector.as_slice())
                + node.neighbors.capacity() * std::mem::size_of_val(&node.neighbors[0])
                + node
                    .neighbors
                    .iter()
                    .map(|neighbors| {
                        neighbors.capacity() * neighbors.first().map(size_of_val).unwrap_or(0)
                    })
                    .sum::<usize>()
        })
        .sum::<usize>()
        + index.nodes.capacity() * std::mem::size_of_val(&index.nodes[0]);
    let started = Instant::now();
    let bytes = index.serialize();
    let serialize_secs = started.elapsed().as_secs_f64();
    let started = Instant::now();
    let restored = HnswIndex::deserialize(&bytes).expect("索引应能重新加载");
    let load_secs = started.elapsed().as_secs_f64();
    assert_eq!(restored.nodes.len(), count);
    println!(
        "HNSW count={count} dim={dimension} ef={search_ef} build={build_secs:.3}s query_p50={:.1}us query_p95={:.1}us recall@24={:.2}% graph={:.2}MiB serialized={:.2}MiB serialize={serialize_secs:.3}s load={load_secs:.3}s",
        query_micros[50],
        query_micros[95],
        recalled as f64 / 24.0,
        graph_bytes as f64 / 1_048_576.0,
        bytes.len() as f64 / 1_048_576.0,
    );
}
