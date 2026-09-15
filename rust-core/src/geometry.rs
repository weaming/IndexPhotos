use std::panic::catch_unwind;
use std::slice;

const MAX_BASE_KEYPOINTS: usize = 96;
const MAX_IMAGE_DIMENSION: usize = 1024;
const PATCH_MARGIN: usize = 26;
const DESCRIPTOR_SIZE: usize = 8;
const DESCRIPTOR_SCALES: [f32; 2] = [10.0, 18.0];
const MATCH_DISTANCE_LIMIT: f32 = 0.42;
const MATCH_RATIO_LIMIT: f32 = 0.88;
const RANSAC_ITERATIONS: usize = 256;
const RANSAC_INLIER_THRESHOLD: f32 = 0.045;

#[repr(C)]
pub struct IndexPhotosGeometryResult {
    pub matched_count: u32,
    pub inlier_count: u32,
    pub inlier_ratio: f32,
    pub coverage: f32,
    pub median_error: f32,
    pub passed: u8,
}

struct Keypoint {
    x: f32,
    y: f32,
    descriptor: [f32; DESCRIPTOR_SIZE * DESCRIPTOR_SIZE],
}

struct RgbaImage<'a> {
    pixels: &'a [u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
}

struct Match {
    left_index: usize,
    right_index: usize,
}

#[derive(Clone, Copy)]
struct AffineTransform {
    x_scale: f32,
    x_shear: f32,
    x_offset: f32,
    y_shear: f32,
    y_scale: f32,
    y_offset: f32,
}

#[derive(Clone, Copy, Default)]
struct GeometryMetrics {
    matched_count: usize,
    inlier_count: usize,
    inlier_ratio: f32,
    coverage: f32,
    median_error: f32,
    passed: bool,
}

impl GeometryMetrics {
    fn is_finite(self) -> bool {
        self.inlier_ratio.is_finite() && self.coverage.is_finite() && self.median_error.is_finite()
    }
}

#[unsafe(no_mangle)]
/// # Safety
/// 两组 pixels 必须分别包含完整的 RGBA 图像；output 必须指向一个可写结果结构。
pub unsafe extern "C" fn index_photos_verify_geometry(
    left_pixels: *const u8,
    left_width: usize,
    left_height: usize,
    left_bytes_per_row: usize,
    right_pixels: *const u8,
    right_width: usize,
    right_height: usize,
    right_bytes_per_row: usize,
    output: *mut IndexPhotosGeometryResult,
) -> bool {
    let Some(left_length) =
        validate_image(left_pixels, left_width, left_height, left_bytes_per_row)
    else {
        return false;
    };
    let Some(right_length) =
        validate_image(right_pixels, right_width, right_height, right_bytes_per_row)
    else {
        return false;
    };
    if output.is_null() {
        return false;
    }

    catch_unwind(|| {
        // SAFETY: validate_image checked that both buffers contain valid RGBA rows.
        let left = unsafe { slice::from_raw_parts(left_pixels, left_length) };
        let right = unsafe { slice::from_raw_parts(right_pixels, right_length) };
        let left_image = RgbaImage {
            pixels: left,
            width: left_width,
            height: left_height,
            bytes_per_row: left_bytes_per_row,
        };
        let right_image = RgbaImage {
            pixels: right,
            width: right_width,
            height: right_height,
            bytes_per_row: right_bytes_per_row,
        };
        let metrics = verify_geometry(&left_image, &right_image);
        if !metrics.is_finite() {
            return false;
        }
        // SAFETY: The caller guarantees that output points to one writable result structure.
        unsafe {
            output.write(IndexPhotosGeometryResult {
                matched_count: metrics.matched_count as u32,
                inlier_count: metrics.inlier_count as u32,
                inlier_ratio: metrics.inlier_ratio,
                coverage: metrics.coverage,
                median_error: metrics.median_error,
                passed: u8::from(metrics.passed),
            });
        }
        true
    })
    .unwrap_or(false)
}

fn validate_image(
    pixels: *const u8,
    width: usize,
    height: usize,
    bytes_per_row: usize,
) -> Option<usize> {
    let minimum_row_bytes = width.checked_mul(4)?;
    let buffer_length = bytes_per_row.checked_mul(height)?;
    if pixels.is_null()
        || width < PATCH_MARGIN * 2 + 1
        || height < PATCH_MARGIN * 2 + 1
        || width > MAX_IMAGE_DIMENSION
        || height > MAX_IMAGE_DIMENSION
        || bytes_per_row < minimum_row_bytes
        || buffer_length > isize::MAX as usize
    {
        return None;
    }
    Some(buffer_length)
}

fn verify_geometry(left: &RgbaImage, right: &RgbaImage) -> GeometryMetrics {
    let left_gray = grayscale(left);
    let right_gray = grayscale(right);
    let left_keypoints = extract_keypoints(&left_gray, left.width, left.height);
    let right_keypoints = extract_keypoints(&right_gray, right.width, right.height);
    let matches = match_keypoints(&left_keypoints, &right_keypoints);
    let matched_count = matches.len();
    if matched_count < 3 {
        return GeometryMetrics {
            matched_count,
            ..GeometryMetrics::default()
        };
    }

    let (transform, inlier_indices) = ransac(
        &left_keypoints,
        &right_keypoints,
        &matches,
        left.width,
        right.height,
    );
    let inlier_count = inlier_indices.len();
    let inlier_ratio = inlier_count as f32 / matched_count as f32;
    let coverage = inlier_coverage(
        &right_keypoints,
        &matches,
        &inlier_indices,
        right.width,
        right.height,
    );
    let mut errors: Vec<f32> = inlier_indices
        .iter()
        .map(|index| {
            let matched = &matches[*index];
            affine_error(
                transform,
                &left_keypoints[matched.left_index],
                &right_keypoints[matched.right_index],
            )
        })
        .collect();
    errors.sort_by(f32::total_cmp);
    let median_error = errors.get(errors.len() / 2).copied().unwrap_or(0.0);

    GeometryMetrics {
        matched_count,
        inlier_count,
        inlier_ratio,
        coverage,
        median_error,
        passed: inlier_count >= 8 && inlier_ratio >= 0.3 && median_error <= RANSAC_INLIER_THRESHOLD,
    }
}

fn grayscale(image: &RgbaImage) -> Vec<f32> {
    let mut result = vec![0.0_f32; image.width * image.height];
    for y in 0..image.height {
        let row_start = y * image.bytes_per_row;
        let output_start = y * image.width;
        for x in 0..image.width {
            let pixel_start = row_start + x * 4;
            result[output_start + x] = (0.299 * image.pixels[pixel_start] as f32
                + 0.587 * image.pixels[pixel_start + 1] as f32
                + 0.114 * image.pixels[pixel_start + 2] as f32)
                / 255.0;
        }
    }
    result
}

fn extract_keypoints(image: &[f32], width: usize, height: usize) -> Vec<Keypoint> {
    let mut scored_points = Vec::new();
    let margin = PATCH_MARGIN;
    for y in margin..height - margin {
        for x in margin..width - margin {
            let center = image[y * width + x];
            let mut sum = 0.0_f32;
            let mut sum_squared = 0.0_f32;
            for offset_y in -2_i32..=2 {
                for offset_x in -2_i32..=2 {
                    let sample_x = (x as i32 + offset_x) as usize;
                    let sample_y = (y as i32 + offset_y) as usize;
                    let value = image[sample_y * width + sample_x];
                    sum += value;
                    sum_squared += value * value;
                }
            }
            let variance = (sum_squared / 25.0 - (sum / 25.0).powi(2)).max(0.0);
            let gradient_x = image[y * width + x + 1] - image[y * width + x - 1];
            let gradient_y = image[(y + 1) * width + x] - image[(y - 1) * width + x];
            let gradient = gradient_x * gradient_x + gradient_y * gradient_y;
            let center_contrast = (center - sum / 25.0).abs();
            let score = variance + gradient * 2.0 + center_contrast * 0.25;
            if score > 0.0005 {
                scored_points.push((score, x, y));
            }
        }
    }

    scored_points.sort_by(|left, right| {
        right
            .0
            .total_cmp(&left.0)
            .then_with(|| left.2.cmp(&right.2))
            .then_with(|| left.1.cmp(&right.1))
    });

    let mut selected = Vec::<(usize, usize)>::new();
    let minimum_spacing_squared = 10_usize * 10;
    for (_, x, y) in scored_points {
        if selected.iter().all(|(selected_x, selected_y)| {
            let delta_x = x.abs_diff(*selected_x);
            let delta_y = y.abs_diff(*selected_y);
            delta_x * delta_x + delta_y * delta_y >= minimum_spacing_squared
        }) {
            selected.push((x, y));
            if selected.len() == MAX_BASE_KEYPOINTS {
                break;
            }
        }
    }

    let mut keypoints = Vec::with_capacity(selected.len() * DESCRIPTOR_SCALES.len());
    for (x, y) in selected {
        for scale in DESCRIPTOR_SCALES {
            keypoints.push(Keypoint {
                x: x as f32 / (width - 1) as f32,
                y: y as f32 / (height - 1) as f32,
                descriptor: normalized_patch(image, width, height, x, y, scale),
            });
        }
    }
    keypoints
}

fn normalized_patch(
    image: &[f32],
    width: usize,
    height: usize,
    center_x: usize,
    center_y: usize,
    scale: f32,
) -> [f32; DESCRIPTOR_SIZE * DESCRIPTOR_SIZE] {
    let mut descriptor = [0.0_f32; DESCRIPTOR_SIZE * DESCRIPTOR_SIZE];
    let half_size = (DESCRIPTOR_SIZE as f32 - 1.0) * 0.5;
    for row in 0..DESCRIPTOR_SIZE {
        for column in 0..DESCRIPTOR_SIZE {
            let local_x = (column as f32 - half_size) / half_size * scale;
            let local_y = (row as f32 - half_size) / half_size * scale;
            let sample_x = center_x as f32 + local_x;
            let sample_y = center_y as f32 + local_y;
            descriptor[row * DESCRIPTOR_SIZE + column] =
                sample(image, width, height, sample_x, sample_y);
        }
    }

    let mean = descriptor.iter().sum::<f32>() / descriptor.len() as f32;
    let variance = descriptor
        .iter()
        .map(|value| {
            let difference = *value - mean;
            difference * difference
        })
        .sum::<f32>()
        / descriptor.len() as f32;
    let standard_deviation = variance.sqrt().max(0.01);
    for value in &mut descriptor {
        *value = (*value - mean) / standard_deviation;
    }
    descriptor
}

fn sample(image: &[f32], width: usize, height: usize, x: f32, y: f32) -> f32 {
    let x = x.clamp(0.0, (width - 1) as f32);
    let y = y.clamp(0.0, (height - 1) as f32);
    let left = x.floor() as usize;
    let top = y.floor() as usize;
    let right = (left + 1).min(width - 1);
    let bottom = (top + 1).min(height - 1);
    let horizontal_weight = x - left as f32;
    let vertical_weight = y - top as f32;
    let top_left = image[top * width + left];
    let top_right = image[top * width + right];
    let bottom_left = image[bottom * width + left];
    let bottom_right = image[bottom * width + right];
    let top_value = top_left + (top_right - top_left) * horizontal_weight;
    let bottom_value = bottom_left + (bottom_right - bottom_left) * horizontal_weight;
    top_value + (bottom_value - top_value) * vertical_weight
}

fn match_keypoints(left: &[Keypoint], right: &[Keypoint]) -> Vec<Match> {
    let mut best_left_for_right = vec![f32::INFINITY; right.len()];
    let mut best_left_index_for_right = vec![usize::MAX; right.len()];
    for (left_index, left_point) in left.iter().enumerate() {
        for (right_index, right_point) in right.iter().enumerate() {
            let distance = descriptor_distance(&left_point.descriptor, &right_point.descriptor);
            if distance < best_left_for_right[right_index] {
                best_left_for_right[right_index] = distance;
                best_left_index_for_right[right_index] = left_index;
            }
        }
    }

    let mut matches = Vec::new();
    for (left_index, left_point) in left.iter().enumerate() {
        let mut best = (usize::MAX, f32::INFINITY);
        let mut second_best = f32::INFINITY;
        for (right_index, right_point) in right.iter().enumerate() {
            let distance = descriptor_distance(&left_point.descriptor, &right_point.descriptor);
            if distance < best.1 {
                second_best = best.1;
                best = (right_index, distance);
            } else if distance < second_best {
                second_best = distance;
            }
        }
        if best.0 == usize::MAX
            || best.1 > MATCH_DISTANCE_LIMIT
            || best_left_index_for_right[best.0] != left_index
        {
            continue;
        }
        let has_distinct_second = second_best.is_finite() && second_best > 0.0001;
        if has_distinct_second && best.1 >= second_best * MATCH_RATIO_LIMIT {
            continue;
        }
        matches.push(Match {
            left_index,
            right_index: best.0,
        });
    }
    matches
}

fn descriptor_distance(
    left: &[f32; DESCRIPTOR_SIZE * DESCRIPTOR_SIZE],
    right: &[f32; DESCRIPTOR_SIZE * DESCRIPTOR_SIZE],
) -> f32 {
    let squared_distance = left
        .iter()
        .zip(right)
        .map(|(left, right)| {
            let difference = left - right;
            difference * difference
        })
        .sum::<f32>()
        / left.len() as f32;
    squared_distance.sqrt()
}

fn ransac(
    left: &[Keypoint],
    right: &[Keypoint],
    matches: &[Match],
    left_width: usize,
    right_height: usize,
) -> (AffineTransform, Vec<usize>) {
    let mut random_state = (left_width as u64)
        .wrapping_mul(0x9E3779B97F4A7C15)
        .wrapping_add(right_height as u64)
        .wrapping_add(matches.len() as u64);
    let mut best_transform = AffineTransform {
        x_scale: 1.0,
        x_shear: 0.0,
        x_offset: 0.0,
        y_shear: 0.0,
        y_scale: 1.0,
        y_offset: 0.0,
    };
    let mut best_inliers = Vec::new();

    for _ in 0..RANSAC_ITERATIONS {
        let first = next_random(&mut random_state) % matches.len();
        let mut second = next_random(&mut random_state) % matches.len();
        let mut third = next_random(&mut random_state) % matches.len();
        if first == second || first == third || second == third {
            second = (first + 1) % matches.len();
            third = (first + 2) % matches.len();
        }
        let sample = [first, second, third];
        let Some(transform) = fit_affine(left, right, matches, sample) else {
            continue;
        };
        let inliers = collect_inliers(left, right, matches, transform);
        if inliers.len() > best_inliers.len() {
            best_transform = transform;
            best_inliers = inliers;
        }
    }

    (best_transform, best_inliers)
}

fn fit_affine(
    left: &[Keypoint],
    right: &[Keypoint],
    matches: &[Match],
    sample: [usize; 3],
) -> Option<AffineTransform> {
    let mut matrix = [[0.0_f32; 3]; 3];
    let mut x_values = [0.0_f32; 3];
    let mut y_values = [0.0_f32; 3];
    for (row, match_index) in sample.into_iter().enumerate() {
        let matched = &matches[match_index];
        let left_point = &left[matched.left_index];
        let right_point = &right[matched.right_index];
        matrix[row] = [left_point.x, left_point.y, 1.0];
        x_values[row] = right_point.x;
        y_values[row] = right_point.y;
    }
    let x_solution = solve_3x3(matrix, x_values)?;
    let y_solution = solve_3x3(matrix, y_values)?;
    Some(AffineTransform {
        x_scale: x_solution[0],
        x_shear: x_solution[1],
        x_offset: x_solution[2],
        y_shear: y_solution[0],
        y_scale: y_solution[1],
        y_offset: y_solution[2],
    })
}

fn solve_3x3(mut matrix: [[f32; 3]; 3], mut values: [f32; 3]) -> Option<[f32; 3]> {
    for pivot in 0..3 {
        let pivot_row = (pivot..3).max_by(|left, right| {
            matrix[*left][pivot]
                .abs()
                .total_cmp(&matrix[*right][pivot].abs())
        })?;
        if matrix[pivot_row][pivot].abs() < 0.00001 {
            return None;
        }
        matrix.swap(pivot, pivot_row);
        values.swap(pivot, pivot_row);
        let pivot_value = matrix[pivot][pivot];
        if !pivot_value.is_finite() {
            return None;
        }
        for value in matrix[pivot].iter_mut().skip(pivot) {
            *value /= pivot_value;
        }
        values[pivot] /= pivot_value;
        let normalized_pivot = matrix[pivot];
        for row in 0..3 {
            if row == pivot {
                continue;
            }
            let factor = matrix[row][pivot];
            for (column, value) in matrix[row].iter_mut().enumerate().skip(pivot) {
                *value -= factor * normalized_pivot[column];
            }
            values[row] -= factor * values[pivot];
        }
    }
    values
        .iter()
        .all(|value| value.is_finite())
        .then_some(values)
}

fn collect_inliers(
    left: &[Keypoint],
    right: &[Keypoint],
    matches: &[Match],
    transform: AffineTransform,
) -> Vec<usize> {
    matches
        .iter()
        .enumerate()
        .filter_map(|(index, matched)| {
            (affine_error(
                transform,
                &left[matched.left_index],
                &right[matched.right_index],
            ) <= RANSAC_INLIER_THRESHOLD)
                .then_some(index)
        })
        .collect()
}

fn affine_error(transform: AffineTransform, left: &Keypoint, right: &Keypoint) -> f32 {
    let predicted_x = transform.x_scale * left.x + transform.x_shear * left.y + transform.x_offset;
    let predicted_y = transform.y_shear * left.x + transform.y_scale * left.y + transform.y_offset;
    ((predicted_x - right.x).powi(2) + (predicted_y - right.y).powi(2)).sqrt()
}

fn inlier_coverage(
    right: &[Keypoint],
    matches: &[Match],
    inlier_indices: &[usize],
    width: usize,
    height: usize,
) -> f32 {
    let Some(first_index) = inlier_indices.first() else {
        return 0.0;
    };
    let first_point = &right[matches[*first_index].right_index];
    let mut min_x = first_point.x;
    let mut max_x = first_point.x;
    let mut min_y = first_point.y;
    let mut max_y = first_point.y;
    for index in inlier_indices.iter().skip(1) {
        let point = &right[matches[*index].right_index];
        min_x = min_x.min(point.x);
        max_x = max_x.max(point.x);
        min_y = min_y.min(point.y);
        max_y = max_y.max(point.y);
    }
    let image_scale = ((width * height) as f32).max(1.0);
    ((max_x - min_x) * (max_y - min_y) * (width * height) as f32 / image_scale).clamp(0.0, 1.0)
}

fn next_random(state: &mut u64) -> usize {
    *state ^= *state << 7;
    *state ^= *state >> 9;
    *state as usize
}

#[cfg(test)]
mod tests {
    use super::{IndexPhotosGeometryResult, index_photos_verify_geometry};

    #[test]
    fn geometry_rejects_invalid_image() {
        let pixel = 0_u8;
        let mut output = IndexPhotosGeometryResult {
            matched_count: 0,
            inlier_count: 0,
            inlier_ratio: 0.0,
            coverage: 0.0,
            median_error: 0.0,
            passed: 0,
        };
        // SAFETY: 指针有效，但图像尺寸不满足几何复核最低要求。
        unsafe {
            assert!(!index_photos_verify_geometry(
                &pixel,
                1,
                1,
                4,
                &pixel,
                1,
                1,
                4,
                &mut output
            ));
        }
    }

    #[test]
    fn geometry_finds_copy_with_brightness_change() {
        let width = 96;
        let height = 96;
        let mut left = vec![0_u8; width * height * 4];
        let mut right = vec![0_u8; width * height * 4];
        for y in 0..height {
            for x in 0..width {
                let value = (((x * 31 + y * 17 + (x * y) % 47) % 256) as u8).max(24);
                let offset = (y * width + x) * 4;
                left[offset] = value;
                left[offset + 1] = value.saturating_add((x % 9) as u8);
                left[offset + 2] = value.saturating_sub((y % 7) as u8);
                left[offset + 3] = 255;

                right[offset] = value.saturating_add(18);
                right[offset + 1] = value.saturating_add(24);
                right[offset + 2] = value.saturating_add(12);
                right[offset + 3] = 255;
            }
        }

        let mut output = IndexPhotosGeometryResult {
            matched_count: 0,
            inlier_count: 0,
            inlier_ratio: 0.0,
            coverage: 0.0,
            median_error: 0.0,
            passed: 0,
        };
        // SAFETY: 两个向量都包含 height 行完整 RGBA 数据。
        unsafe {
            assert!(index_photos_verify_geometry(
                left.as_ptr(),
                width,
                height,
                width * 4,
                right.as_ptr(),
                width,
                height,
                width * 4,
                &mut output
            ));
        }
        assert_eq!(output.passed, 1);
        assert!(output.matched_count >= 8);
        assert!(output.inlier_count >= 8);
    }

    #[test]
    fn geometry_returns_finite_metrics_for_unrelated_images() {
        let width = 96;
        let height = 96;
        let mut left = vec![0_u8; width * height * 4];
        let mut right = vec![0_u8; width * height * 4];
        for y in 0..height {
            for x in 0..width {
                let left_value = ((x * 13 + y * 29 + (x * y) % 31) % 256) as u8;
                let right_value = ((x * 47 + y * 11 + (x * y) % 17) % 256) as u8;
                let offset = (y * width + x) * 4;
                left[offset..offset + 4].copy_from_slice(&[
                    left_value,
                    left_value.saturating_add(7),
                    left_value.saturating_sub(5),
                    255,
                ]);
                right[offset..offset + 4].copy_from_slice(&[
                    right_value,
                    right_value.saturating_add(11),
                    right_value.saturating_sub(9),
                    255,
                ]);
            }
        }

        let mut output = IndexPhotosGeometryResult {
            matched_count: 0,
            inlier_count: 0,
            inlier_ratio: 0.0,
            coverage: 0.0,
            median_error: 0.0,
            passed: 0,
        };
        // SAFETY: 两个向量都包含 height 行完整 RGBA 数据。
        unsafe {
            assert!(index_photos_verify_geometry(
                left.as_ptr(),
                width,
                height,
                width * 4,
                right.as_ptr(),
                width,
                height,
                width * 4,
                &mut output
            ));
        }
        assert!(output.inlier_ratio.is_finite());
        assert!(output.coverage.is_finite());
        assert!(output.median_error.is_finite());
    }
}
