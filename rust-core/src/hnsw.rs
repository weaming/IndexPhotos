//! 面向海量照片相似候选检索的 HNSW，输入向量须已做 L2 归一化。
//!
//! 论文参考：Yu. A. Malkov, D. A. Yashunin,
//! “Efficient and robust approximate nearest neighbor search using Hierarchical Navigable
//! Small World graphs”, arXiv:1603.09320v4 (2018)。
//! [论文与版本信息](https://arxiv.org/abs/1603.09320v4)，
//! [全文 PDF](https://arxiv.org/pdf/1603.09320v4)。
//! 邻居选择参考算法 4：不扩展候选集，并用被剪掉的近邻补足连接；层级概率与连接上限
//! 参考 §4.1（论文建议 p=1/M，本实现用二进制采样近似）；u32 连接存储参考 §4.2.3。
//! 搜索缓冲复用、8 路累加及直接序列化是本实现的工程取舍。
//!
//! - 内存中的邻居编号使用 u32，缩减图连接存储；文件仍以 u64 编码，兼容 v1 格式与 C ABI。
//! - 每个搜索线程复用候选堆、结果堆和访问标记数组，以代数区分搜索，避免逐层分配 HashSet
//!   或清空整个访问数组；仅代数溢出时清空。访问标记约占 4 字节/节点/线程，另有预留容量。
//! - 层级由 label 的稳定散列采样，晋升概率为 2^(-floor(log2(M)))；M=16 时为 1/16，
//!   控制上层节点及连接数量，兼顾导航能力与内存占用。
//! - 新节点每层最多选择 M 个邻居，反向连接仅超限时剪枝（底层 2M、上层 M），并借用向量
//!   计算距离。优先保留不同方向的连接，再用近邻补足，兼顾跨簇导航与密集近重复照片召回。
//! - 归一化向量的 cosine 距离使用 8 路独立累加，减少串行依赖并便于编译器向量化；
//!   结果堆实时更新接纳阈值，满堆时直接替换最差项，搜索宽度不超过节点数。
//! - 序列化直接写入调用方缓冲，避免再分配完整索引副本；反序列化在分配前校验字节边界，
//!   并检查邻居数量、编号及层级关系，拒绝损坏索引。
//!
//! 查重召回率仍取决于照片分布与 construction_ef/search_ef，HNSW 不保证穷举所有重复项。
//! 可用 hnsw_photo_benchmark 基准对照精确近邻调参；模拟向量结果不能替代实际照片验证。

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::panic::catch_unwind;
use std::slice;

const HNSW_FORMAT_VERSION: u32 = 1;
const HNSW_MAGIC: &[u8; 8] = b"IPHNSW01";
const MAX_LEVEL: usize = 16;

thread_local! {
    static SEARCH_SCRATCH: RefCell<SearchScratch> = RefCell::new(SearchScratch::default());
}

#[derive(Default)]
struct SearchScratch {
    visited: Vec<u32>,
    generation: u32,
    candidates: BinaryHeap<MinDistanceCandidate>,
    results: BinaryHeap<MaxDistanceCandidate>,
}

impl SearchScratch {
    fn reset(&mut self, node_count: usize) {
        self.visited.resize(node_count, 0);
        self.generation = self.generation.wrapping_add(1);
        if self.generation == 0 {
            self.visited.fill(0);
            self.generation = 1;
        }
        self.candidates.clear();
        self.results.clear();
    }

    fn visit(&mut self, node_index: usize) -> bool {
        if self.visited[node_index] == self.generation {
            return false;
        }
        self.visited[node_index] = self.generation;
        true
    }
}

struct HnswNode {
    label: u64,
    vector: Vec<f32>,
    neighbors: Vec<Vec<u32>>,
}

struct HnswIndex {
    dimension: usize,
    max_neighbors: usize,
    construction_ef: usize,
    max_level: usize,
    entry_point: Option<usize>,
    nodes: Vec<HnswNode>,
}

#[derive(Clone, Copy)]
struct MinDistanceCandidate {
    distance: f32,
    node_index: usize,
}

impl PartialEq for MinDistanceCandidate {
    fn eq(&self, other: &Self) -> bool {
        self.distance.total_cmp(&other.distance) == Ordering::Equal
            && self.node_index == other.node_index
    }
}

impl Eq for MinDistanceCandidate {}

impl PartialOrd for MinDistanceCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for MinDistanceCandidate {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .distance
            .total_cmp(&self.distance)
            .then_with(|| other.node_index.cmp(&self.node_index))
    }
}

#[derive(Clone, Copy)]
struct MaxDistanceCandidate {
    distance: f32,
    node_index: usize,
}

impl PartialEq for MaxDistanceCandidate {
    fn eq(&self, other: &Self) -> bool {
        self.distance.total_cmp(&other.distance) == Ordering::Equal
            && self.node_index == other.node_index
    }
}

impl Eq for MaxDistanceCandidate {}

impl PartialOrd for MaxDistanceCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for MaxDistanceCandidate {
    fn cmp(&self, other: &Self) -> Ordering {
        self.distance
            .total_cmp(&other.distance)
            .then_with(|| self.node_index.cmp(&other.node_index))
    }
}

impl HnswIndex {
    fn new(dimension: usize, max_neighbors: usize, construction_ef: usize) -> Self {
        Self {
            dimension,
            max_neighbors,
            construction_ef: construction_ef.max(max_neighbors),
            max_level: 0,
            entry_point: None,
            nodes: Vec::new(),
        }
    }

    fn insert(&mut self, label: u64, vector: &[f32]) -> bool {
        if vector.len() != self.dimension
            || !vector.iter().all(|value| value.is_finite())
            || self.nodes.len() >= u32::MAX as usize
        {
            return false;
        }

        let level = level_for_label(label, self.max_neighbors);
        let node_index = self.nodes.len();
        self.nodes.push(HnswNode {
            label,
            vector: vector.to_vec(),
            neighbors: vec![Vec::new(); level + 1],
        });

        let Some(mut current) = self.entry_point else {
            self.entry_point = Some(node_index);
            self.max_level = level;
            return true;
        };

        if self.max_level > level {
            for current_level in ((level + 1)..=self.max_level).rev() {
                current = self.greedy_search(vector, current, current_level);
            }
        }

        let connect_level = level.min(self.max_level);
        for current_level in (0..=connect_level).rev() {
            let candidates =
                self.search_layer(vector, current, current_level, self.construction_ef);
            if let Some(best) = candidates.iter().min() {
                current = best.node_index;
            }
            let selected = self.select_neighbors(candidates, self.max_neighbors);
            self.nodes[node_index].neighbors[current_level] = selected.clone();

            for neighbor_index in selected {
                let neighbor_index = neighbor_index as usize;
                self.nodes[neighbor_index].neighbors[current_level].push(node_index as u32);
                self.prune_neighbors(neighbor_index, current_level);
            }
        }

        if level > self.max_level {
            self.max_level = level;
            self.entry_point = Some(node_index);
        }
        true
    }

    fn search(&self, vector: &[f32], limit: usize, search_ef: usize) -> Vec<(u64, f32)> {
        if vector.len() != self.dimension
            || !vector.iter().all(|value| value.is_finite())
            || limit == 0
            || self.nodes.is_empty()
        {
            return Vec::new();
        }

        let Some(mut current) = self.entry_point else {
            return Vec::new();
        };
        for current_level in (1..=self.max_level).rev() {
            current = self.greedy_search(vector, current, current_level);
        }

        let candidates = self.search_layer(vector, current, 0, search_ef.max(limit));
        let mut result: Vec<(u64, f32)> = candidates
            .into_iter()
            .map(|candidate| (self.nodes[candidate.node_index].label, candidate.distance))
            .collect();
        result.sort_by(|left, right| {
            left.1
                .total_cmp(&right.1)
                .then_with(|| left.0.cmp(&right.0))
        });
        result.truncate(limit);
        result
    }

    fn greedy_search(&self, query: &[f32], start: usize, level: usize) -> usize {
        let mut current = start;
        let mut current_distance = self.distance(query, &self.nodes[current].vector);
        loop {
            let mut improved = false;
            for &neighbor in self.nodes[current]
                .neighbors
                .get(level)
                .map(Vec::as_slice)
                .unwrap_or(&[])
            {
                let neighbor = neighbor as usize;
                let distance = self.distance(query, &self.nodes[neighbor].vector);
                if distance < current_distance {
                    current = neighbor;
                    current_distance = distance;
                    improved = true;
                }
            }
            if !improved {
                return current;
            }
        }
    }

    fn search_layer(
        &self,
        query: &[f32],
        entry: usize,
        level: usize,
        limit: usize,
    ) -> Vec<MaxDistanceCandidate> {
        SEARCH_SCRATCH.with_borrow_mut(|scratch| {
            self.search_layer_with_scratch(query, entry, level, limit, scratch)
        })
    }

    fn search_layer_with_scratch(
        &self,
        query: &[f32],
        entry: usize,
        level: usize,
        limit: usize,
        scratch: &mut SearchScratch,
    ) -> Vec<MaxDistanceCandidate> {
        let limit = limit.max(1).min(self.nodes.len());
        scratch.reset(self.nodes.len());
        let initial_distance = self.distance(query, &self.nodes[entry].vector);
        scratch.candidates.push(MinDistanceCandidate {
            distance: initial_distance,
            node_index: entry,
        });
        scratch.results.push(MaxDistanceCandidate {
            distance: initial_distance,
            node_index: entry,
        });
        scratch.visit(entry);

        while let Some(candidate) = scratch.candidates.pop() {
            let worst_distance = scratch
                .results
                .peek()
                .map(|result: &MaxDistanceCandidate| result.distance)
                .unwrap_or(f32::INFINITY);
            if scratch.results.len() >= limit && candidate.distance > worst_distance {
                break;
            }

            for &neighbor in self.nodes[candidate.node_index]
                .neighbors
                .get(level)
                .map(Vec::as_slice)
                .unwrap_or(&[])
            {
                let neighbor = neighbor as usize;
                if !scratch.visit(neighbor) {
                    continue;
                }
                let distance = self.distance(query, &self.nodes[neighbor].vector);
                let result = MaxDistanceCandidate {
                    distance,
                    node_index: neighbor,
                };
                let is_better = scratch.results.len() < limit
                    || scratch.results.peek().is_some_and(|worst| result < *worst);
                if is_better {
                    scratch.candidates.push(MinDistanceCandidate {
                        distance,
                        node_index: neighbor,
                    });
                    if scratch.results.len() == limit {
                        *scratch.results.peek_mut().expect("搜索结果不能为空") = result;
                    } else {
                        scratch.results.push(result);
                    }
                }
            }
        }
        scratch.results.iter().copied().collect()
    }

    /// 优先保留不同方向的连接，再用近邻补足密集重复簇的连接。
    fn select_neighbors(&self, candidates: Vec<MaxDistanceCandidate>, limit: usize) -> Vec<u32> {
        let mut candidates = candidates;
        candidates.sort_unstable_by(|left, right| {
            left.distance
                .total_cmp(&right.distance)
                .then_with(|| left.node_index.cmp(&right.node_index))
        });
        let mut selected = Vec::with_capacity(limit.min(candidates.len()));
        for candidate in &candidates {
            let candidate_vector = &self.nodes[candidate.node_index].vector;
            let has_diverse_direction = selected.iter().all(|&neighbor: &u32| {
                self.distance(candidate_vector, &self.nodes[neighbor as usize].vector)
                    >= candidate.distance
            });
            if has_diverse_direction {
                selected.push(candidate.node_index as u32);
                if selected.len() == limit {
                    return selected;
                }
            }
        }
        for candidate in candidates {
            let neighbor = candidate.node_index as u32;
            if !selected.contains(&neighbor) {
                selected.push(neighbor);
                if selected.len() == limit {
                    break;
                }
            }
        }
        selected
    }

    fn prune_neighbors(&mut self, node_index: usize, level: usize) {
        let limit = self.neighbor_limit(level);
        let neighbors = &self.nodes[node_index].neighbors[level];
        if neighbors.len() <= limit {
            return;
        }
        let node_vector = &self.nodes[node_index].vector;
        let ranked = neighbors
            .iter()
            .map(|&neighbor| MaxDistanceCandidate {
                node_index: neighbor as usize,
                distance: self.distance(node_vector, &self.nodes[neighbor as usize].vector),
            })
            .collect();
        let selected = self.select_neighbors(ranked, limit);
        self.nodes[node_index].neighbors[level] = selected;
    }

    fn neighbor_limit(&self, level: usize) -> usize {
        if level == 0 {
            self.max_neighbors * 2
        } else {
            self.max_neighbors
        }
    }

    fn distance(&self, left: &[f32], right: &[f32]) -> f32 {
        let (left_chunks, left_tail) = left.as_chunks::<8>();
        let (right_chunks, right_tail) = right.as_chunks::<8>();
        let mut sums = [0.0_f32; 8];
        for (left_chunk, right_chunk) in left_chunks.iter().zip(right_chunks) {
            for lane in 0..8 {
                sums[lane] += left_chunk[lane] * right_chunk[lane];
            }
        }
        let tail_sum: f32 = left_tail
            .iter()
            .zip(right_tail)
            .map(|(left, right)| left * right)
            .sum();
        let dot_product = sums.iter().sum::<f32>() + tail_sum;
        (1.0 - dot_product).max(0.0)
    }

    fn serialized_length(&self) -> usize {
        let mut length: usize = 8 + 4 + 8 * 6;
        for node in &self.nodes {
            let Some(vector_bytes) = node.vector.len().checked_mul(4) else {
                return 0;
            };
            let Some(node_length) = (8 + 8 + vector_bytes).checked_add(8).and_then(|value| {
                node.neighbors.iter().try_fold(value, |length, neighbors| {
                    neighbors.len().checked_mul(8).and_then(|neighbor_bytes| {
                        length
                            .checked_add(8)
                            .and_then(|length| length.checked_add(neighbor_bytes))
                    })
                })
            }) else {
                return 0;
            };
            let Some(new_length) = length.checked_add(node_length) else {
                return 0;
            };
            length = new_length;
        }
        length
    }

    #[cfg(test)]
    fn serialize(&self) -> Vec<u8> {
        let mut bytes = vec![0; self.serialized_length()];
        self.serialize_into(&mut bytes)
            .expect("索引序列化长度必须正确");
        bytes
    }

    fn serialize_into(&self, output: &mut [u8]) -> Option<()> {
        let length = self.serialized_length();
        if length == 0 || length != output.len() {
            return None;
        }
        let mut writer = ByteWriter {
            bytes: output,
            cursor: 0,
        };
        writer.write(HNSW_MAGIC)?;
        writer.write(&HNSW_FORMAT_VERSION.to_le_bytes())?;
        writer.write_u64(self.dimension as u64)?;
        writer.write_u64(self.max_neighbors as u64)?;
        writer.write_u64(self.construction_ef as u64)?;
        writer.write_u64(self.max_level as u64)?;
        writer.write_u64(
            self.entry_point
                .map(|value| value as u64)
                .unwrap_or(u64::MAX),
        )?;
        writer.write_u64(self.nodes.len() as u64)?;

        for node in &self.nodes {
            writer.write_u64(node.label)?;
            writer.write_u64(node.vector.len() as u64)?;
            for value in &node.vector {
                writer.write(&value.to_le_bytes())?;
            }
            writer.write_u64(node.neighbors.len() as u64)?;
            for neighbors in &node.neighbors {
                writer.write_u64(neighbors.len() as u64)?;
                for neighbor in neighbors {
                    writer.write_u64(*neighbor as u64)?;
                }
            }
        }
        Some(())
    }

    fn deserialize(bytes: &[u8]) -> Option<Self> {
        let mut cursor = 0;
        if read_bytes(bytes, &mut cursor, HNSW_MAGIC.len())? != HNSW_MAGIC.as_slice() {
            return None;
        }
        if read_u32(bytes, &mut cursor)? != HNSW_FORMAT_VERSION {
            return None;
        }

        let dimension = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
        let max_neighbors = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
        let construction_ef = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
        let stored_max_level = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
        let stored_entry_point = read_u64(bytes, &mut cursor)?;
        let node_count = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;

        if dimension == 0
            || !(2..=usize::MAX / 2).contains(&max_neighbors)
            || construction_ef == 0
            || stored_max_level > MAX_LEVEL
            || node_count > u32::MAX as usize
            || (node_count == 0 && stored_entry_point != u64::MAX)
            || (node_count > 0
                && (stored_entry_point == u64::MAX || stored_entry_point >= node_count as u64))
        {
            return None;
        }

        let vector_bytes = dimension.checked_mul(4)?;
        let min_node_bytes = vector_bytes.checked_add(32)?;
        if node_count > bytes.len().saturating_sub(cursor) / min_node_bytes {
            return None;
        }

        let mut nodes = Vec::with_capacity(node_count);
        for _ in 0..node_count {
            let label = read_u64(bytes, &mut cursor)?;
            let vector_length = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
            if vector_length != dimension {
                return None;
            }
            let encoded_vector = read_bytes(bytes, &mut cursor, vector_bytes)?;
            let mut vector = Vec::with_capacity(vector_length);
            for encoded_value in encoded_vector.as_chunks::<4>().0 {
                let value = f32::from_le_bytes(*encoded_value);
                if !value.is_finite() {
                    return None;
                }
                vector.push(value);
            }

            let level_count = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
            if level_count == 0 || level_count > stored_max_level + 1 {
                return None;
            }
            let mut neighbors_by_level = Vec::with_capacity(level_count);
            for level in 0..level_count {
                let neighbor_count = usize::try_from(read_u64(bytes, &mut cursor)?).ok()?;
                let neighbor_limit = if level == 0 {
                    max_neighbors * 2
                } else {
                    max_neighbors
                };
                if neighbor_count > neighbor_limit || neighbor_count > node_count {
                    return None;
                }
                let encoded_neighbors =
                    read_bytes(bytes, &mut cursor, neighbor_count.checked_mul(8)?)?;
                let mut neighbors = Vec::with_capacity(neighbor_count);
                for encoded_neighbor in encoded_neighbors.as_chunks::<8>().0 {
                    let neighbor = u32::try_from(u64::from_le_bytes(*encoded_neighbor)).ok()?;
                    if neighbor as usize >= node_count
                        || neighbor as usize == nodes.len()
                        || neighbors.contains(&neighbor)
                    {
                        return None;
                    }
                    neighbors.push(neighbor);
                }
                neighbors_by_level.push(neighbors);
            }
            nodes.push(HnswNode {
                label,
                vector,
                neighbors: neighbors_by_level,
            });
        }

        if cursor != bytes.len() {
            return None;
        }

        let max_level = nodes
            .iter()
            .map(|node| node.neighbors.len().saturating_sub(1))
            .max()
            .unwrap_or(0);
        if max_level != stored_max_level {
            return None;
        }

        if stored_entry_point != u64::MAX
            && nodes[stored_entry_point as usize].neighbors.len() != max_level + 1
        {
            return None;
        }
        for node in &nodes {
            for (level, neighbors) in node.neighbors.iter().enumerate() {
                if neighbors
                    .iter()
                    .any(|&neighbor| nodes[neighbor as usize].neighbors.len() <= level)
                {
                    return None;
                }
            }
        }

        Some(Self {
            dimension,
            max_neighbors,
            construction_ef,
            max_level,
            entry_point: (stored_entry_point != u64::MAX).then_some(stored_entry_point as usize),
            nodes,
        })
    }
}

struct ByteWriter<'a> {
    bytes: &'a mut [u8],
    cursor: usize,
}

impl ByteWriter<'_> {
    fn write(&mut self, value: &[u8]) -> Option<()> {
        let end = self.cursor.checked_add(value.len())?;
        self.bytes.get_mut(self.cursor..end)?.copy_from_slice(value);
        self.cursor = end;
        Some(())
    }

    fn write_u64(&mut self, value: u64) -> Option<()> {
        self.write(&value.to_le_bytes())
    }
}

fn read_bytes<'a>(bytes: &'a [u8], cursor: &mut usize, length: usize) -> Option<&'a [u8]> {
    let end = cursor.checked_add(length)?;
    let result = bytes.get(*cursor..end)?;
    *cursor = end;
    Some(result)
}

fn read_u32(bytes: &[u8], cursor: &mut usize) -> Option<u32> {
    let value = read_bytes(bytes, cursor, 4)?;
    Some(u32::from_le_bytes(value.try_into().ok()?))
}

fn read_u64(bytes: &[u8], cursor: &mut usize) -> Option<u64> {
    let value = read_bytes(bytes, cursor, 8)?;
    Some(u64::from_le_bytes(value.try_into().ok()?))
}

fn level_for_label(label: u64, max_neighbors: usize) -> usize {
    let mut value = label.wrapping_add(0x9E3779B97F4A7C15);
    value = (value ^ (value >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94D049BB133111EB);
    value ^= value >> 31;

    let mut level = 0;
    let level_bits = max_neighbors.ilog2().max(1);
    let level_mask = (1_u64 << level_bits) - 1;
    while level < MAX_LEVEL && value & level_mask == 0 {
        level += 1;
        value >>= level_bits;
    }
    level
}

#[repr(C)]
pub struct IndexPhotosHnswIndex {
    inner: HnswIndex,
}

#[unsafe(no_mangle)]
pub extern "C" fn index_photos_hnsw_create(
    dimension: usize,
    max_neighbors: usize,
    construction_ef: usize,
) -> *mut IndexPhotosHnswIndex {
    if dimension == 0 || !(2..=usize::MAX / 2).contains(&max_neighbors) || construction_ef == 0 {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(IndexPhotosHnswIndex {
        inner: HnswIndex::new(dimension, max_neighbors, construction_ef),
    }))
}

#[unsafe(no_mangle)]
/// # Safety
/// index 必须来自 create；vector 必须指向 vector_length 个有效的 f32。
pub unsafe extern "C" fn index_photos_hnsw_insert(
    index: *mut IndexPhotosHnswIndex,
    label: u64,
    vector: *const f32,
    vector_length: usize,
) -> bool {
    if index.is_null() || vector.is_null() || vector_length == 0 {
        return false;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that vector points to vector_length readable f32 values.
        let vector = unsafe { slice::from_raw_parts(vector, vector_length) };
        // SAFETY: The caller guarantees that index points to a live index.
        unsafe { (*index).inner.insert(label, vector) }
    })
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
/// # Safety
/// index、query 和输出数组必须有效；输出数组至少容纳 result_capacity 项。
pub unsafe extern "C" fn index_photos_hnsw_search(
    index: *const IndexPhotosHnswIndex,
    query: *const f32,
    query_length: usize,
    limit: usize,
    search_ef: usize,
    labels: *mut u64,
    distances: *mut f32,
    result_capacity: usize,
) -> usize {
    if index.is_null()
        || query.is_null()
        || query_length == 0
        || limit == 0
        || result_capacity == 0
        || labels.is_null()
        || distances.is_null()
    {
        return 0;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that query points to query_length readable values.
        let query = unsafe { slice::from_raw_parts(query, query_length) };
        // SAFETY: The caller guarantees that index points to a live index.
        let result = unsafe {
            (*index)
                .inner
                .search(query, limit.min(result_capacity), search_ef)
        };
        let count = result.len().min(result_capacity);
        for (position, (label, distance)) in result.into_iter().take(count).enumerate() {
            // SAFETY: The caller guarantees that output arrays contain result_capacity items.
            unsafe {
                labels.add(position).write(label);
                distances.add(position).write(distance);
            }
        }
        count
    })
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
/// # Safety
/// index 必须来自 create，且在调用期间保持有效。
pub unsafe extern "C" fn index_photos_hnsw_serialized_length(
    index: *const IndexPhotosHnswIndex,
) -> usize {
    if index.is_null() {
        return 0;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that index points to a live index.
        unsafe { (*index).inner.serialized_length() }
    })
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
/// # Safety
/// index 必须来自 create；output 必须指向 serialized_length 个可写字节。
pub unsafe extern "C" fn index_photos_hnsw_serialize(
    index: *const IndexPhotosHnswIndex,
    output: *mut u8,
    output_length: usize,
) -> bool {
    if index.is_null()
        || output.is_null()
        || output_length == 0
        || output_length > isize::MAX as usize
    {
        return false;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that index points to a live index.
        let inner = unsafe { &(*index).inner };
        if inner.serialized_length() != output_length {
            return false;
        }
        // SAFETY: The caller guarantees that output points to output_length writable bytes.
        let output = unsafe { slice::from_raw_parts_mut(output, output_length) };
        inner.serialize_into(output).is_some()
    })
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
/// # Safety
/// data 必须指向 length 个可读字节；返回的索引由 destroy 释放。
pub unsafe extern "C" fn index_photos_hnsw_deserialize(
    data: *const u8,
    length: usize,
) -> *mut IndexPhotosHnswIndex {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return std::ptr::null_mut();
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that data points to length readable bytes.
        let bytes = unsafe { slice::from_raw_parts(data, length) };
        HnswIndex::deserialize(bytes)
            .map(|inner| Box::into_raw(Box::new(IndexPhotosHnswIndex { inner })))
            .unwrap_or(std::ptr::null_mut())
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
/// # Safety
/// index 必须来自 create，且只能销毁一次。
pub unsafe extern "C" fn index_photos_hnsw_destroy(index: *mut IndexPhotosHnswIndex) {
    if index.is_null() {
        return;
    }

    // SAFETY: The caller must pass a pointer returned by index_photos_hnsw_create once.
    unsafe { drop(Box::from_raw(index)) };
}

#[cfg(test)]
#[path = "hnsw/tests/hnsw_bench.rs"]
mod bench;

#[cfg(test)]
#[path = "hnsw/tests.rs"]
mod tests;
