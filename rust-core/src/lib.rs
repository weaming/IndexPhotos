#![deny(unsafe_op_in_unsafe_fn)]

use std::panic::catch_unwind;
use std::slice;
use std::sync::OnceLock;

const HASH_LENGTH: usize = 32;
const PHASH_SIZE: usize = 32;
const DCT_COEFFICIENTS: usize = 64;
const PHASH_AC_BITS: usize = DCT_COEFFICIENTS - 1;
static COSINE_TABLE: OnceLock<[[f64; PHASH_SIZE]; 8]> = OnceLock::new();

#[repr(C)]
pub struct IndexPhotosBlake3Hasher {
    inner: blake3::Hasher,
}

#[unsafe(no_mangle)]
pub extern "C" fn index_photos_blake3_create() -> *mut IndexPhotosBlake3Hasher {
    Box::into_raw(Box::new(IndexPhotosBlake3Hasher {
        inner: blake3::Hasher::new(),
    }))
}

#[unsafe(no_mangle)]
/// # Safety
/// hasher 必须仍然有效且无并发更新；data 必须指向 length 字节可读内存。
pub unsafe extern "C" fn index_photos_blake3_update(
    hasher: *mut IndexPhotosBlake3Hasher,
    data: *const u8,
    length: usize,
) -> bool {
    if hasher.is_null() || (data.is_null() && length > 0) {
        return false;
    }

    catch_unwind(|| {
        let bytes = if length == 0 {
            &[]
        } else {
            // SAFETY: The caller guarantees that data points to length readable bytes.
            unsafe { slice::from_raw_parts(data, length) }
        };

        // SAFETY: The caller guarantees that hasher points to a live hasher.
        unsafe { (*hasher).inner.update(bytes) };
    })
    .is_ok()
}

#[unsafe(no_mangle)]
/// # Safety
/// hasher 必须仍然有效；output 必须指向 output_length 字节可写内存。
pub unsafe extern "C" fn index_photos_blake3_finalize(
    hasher: *const IndexPhotosBlake3Hasher,
    output: *mut u8,
    output_length: usize,
) -> bool {
    if hasher.is_null() || output.is_null() || output_length < HASH_LENGTH {
        return false;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that hasher points to a live hasher.
        let hash = unsafe { (*hasher).inner.finalize() };
        // SAFETY: The caller guarantees that output points to output_length writable bytes.
        let output_bytes = unsafe { slice::from_raw_parts_mut(output, output_length) };
        output_bytes[..HASH_LENGTH].copy_from_slice(hash.as_bytes());
    })
    .is_ok()
}

#[unsafe(no_mangle)]
/// # Safety
/// hasher 必须来自 create，且只能销毁一次；销毁后不得再次访问。
pub unsafe extern "C" fn index_photos_blake3_destroy(hasher: *mut IndexPhotosBlake3Hasher) {
    if hasher.is_null() {
        return;
    }

    // SAFETY: The caller must pass a pointer returned by index_photos_blake3_create once.
    unsafe { drop(Box::from_raw(hasher)) };
}

#[unsafe(no_mangle)]
/// # Safety
/// pixels 必须包含 height 行 RGBA 数据；output 必须指向一个可写 u64。
pub unsafe extern "C" fn index_photos_perceptual_hash(
    pixels: *const u8,
    width: usize,
    height: usize,
    bytes_per_row: usize,
    output: *mut u64,
) -> bool {
    let Some(minimum_row_bytes) = width.checked_mul(4) else {
        return false;
    };
    let Some(buffer_length) = bytes_per_row.checked_mul(height) else {
        return false;
    };
    if pixels.is_null()
        || output.is_null()
        || width == 0
        || height == 0
        || bytes_per_row < minimum_row_bytes
        || buffer_length > isize::MAX as usize
    {
        return false;
    }

    catch_unwind(|| {
        // SAFETY: The caller guarantees that pixels points to height rows of RGBA bytes.
        let source = unsafe { slice::from_raw_parts(pixels, buffer_length) };
        let hash = calculate_perceptual_hash(source, width, height, bytes_per_row);

        // SAFETY: The caller guarantees that output points to one writable u64.
        unsafe { output.write(hash) };
    })
    .is_ok()
}

fn calculate_perceptual_hash(
    pixels: &[u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
) -> u64 {
    let mut samples = [[0.0_f64; PHASH_SIZE]; PHASH_SIZE];
    for (y, row) in samples.iter_mut().enumerate() {
        for (x, sample) in row.iter_mut().enumerate() {
            *sample = area_average_luminance(pixels, width, height, bytes_per_row, x, y);
        }
    }

    let coefficients = calculate_dct_coefficients(&samples);

    let mut ac_coefficients = [0.0_f64; PHASH_AC_BITS];
    ac_coefficients.copy_from_slice(&coefficients[1..]);
    let median_index = ac_coefficients.len() / 2;
    let (_, median, _) =
        ac_coefficients.select_nth_unstable_by(median_index, |left, right| left.total_cmp(right));
    let median = *median;

    let mut hash = 0_u64;
    for (index, coefficient) in coefficients[1..].iter().enumerate() {
        if *coefficient > median {
            hash |= 1_u64 << index;
        }
    }
    hash
}

fn calculate_dct_coefficients(
    samples: &[[f64; PHASH_SIZE]; PHASH_SIZE],
) -> [f64; DCT_COEFFICIENTS] {
    let cosine_table = cosine_table();
    let mut horizontal_dct = [[0.0_f64; PHASH_SIZE]; 8];
    for y in 0..PHASH_SIZE {
        for u in 0..8 {
            let mut sum = 0.0_f64;
            for x in 0..PHASH_SIZE {
                sum += samples[y][x] * cosine_table[u][x];
            }
            horizontal_dct[u][y] = sum;
        }
    }

    let mut coefficients = [0.0_f64; DCT_COEFFICIENTS];
    for u in 0..8 {
        for v in 0..8 {
            let mut sum = 0.0_f64;
            for y in 0..PHASH_SIZE {
                sum += horizontal_dct[u][y] * cosine_table[v][y];
            }
            coefficients[u * 8 + v] = sum;
        }
    }
    coefficients
}

fn area_average_luminance(
    pixels: &[u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
    target_x: usize,
    target_y: usize,
) -> f64 {
    let x_start = target_x * width / PHASH_SIZE;
    let y_start = target_y * height / PHASH_SIZE;
    let x_end = ((target_x + 1) * width / PHASH_SIZE)
        .min(width)
        .max(x_start + 1);
    let y_end = ((target_y + 1) * height / PHASH_SIZE)
        .min(height)
        .max(y_start + 1);

    let mut luminance_sum = 0.0_f64;
    let mut sample_count = 0_usize;
    for source_y in y_start..y_end {
        let row_start = source_y * bytes_per_row;
        for source_x in x_start..x_end {
            let pixel_start = row_start + source_x * 4;
            let red = pixels[pixel_start] as f64;
            let green = pixels[pixel_start + 1] as f64;
            let blue = pixels[pixel_start + 2] as f64;
            luminance_sum += 0.299 * red + 0.587 * green + 0.114 * blue;
            sample_count += 1;
        }
    }

    luminance_sum / sample_count as f64
}

fn cosine_table() -> &'static [[f64; PHASH_SIZE]; 8] {
    COSINE_TABLE.get_or_init(|| {
        let mut table = [[0.0_f64; PHASH_SIZE]; 8];
        let scale = std::f64::consts::PI / (2.0 * PHASH_SIZE as f64);
        for (u, row) in table.iter_mut().enumerate() {
            for (position, value) in row.iter_mut().enumerate() {
                *value = ((2 * position + 1) as f64 * u as f64 * scale).cos();
            }
        }
        table
    })
}

#[cfg(test)]
mod tests {
    use super::{PHASH_SIZE, area_average_luminance};

    #[test]
    fn perceptual_hash_rejects_overflowing_dimensions() {
        let pixel = 0_u8;
        let mut output = 0_u64;
        // SAFETY: 无效尺寸必须在访问 pixel 之前被拒绝，output 是有效指针。
        unsafe {
            assert!(!super::index_photos_perceptual_hash(
                &pixel,
                usize::MAX,
                1,
                usize::MAX,
                &mut output
            ));
            assert!(!super::index_photos_perceptual_hash(
                &pixel,
                1,
                usize::MAX,
                4,
                &mut output
            ));
        }
    }

    #[test]
    fn perceptual_hash_matches_sorted_median_definition() {
        for (width, height) in [(1, 1), (17, 41), (100, 100), (320, 213)] {
            let mut state = 0x1234_5678_u64;
            let pixels: Vec<u8> = (0..width * height * 4)
                .map(|_| {
                    state = state
                        .wrapping_mul(6_364_136_223_846_793_005)
                        .wrapping_add(1);
                    (state >> 32) as u8
                })
                .collect();
            let mut samples = [[0.0_f64; PHASH_SIZE]; PHASH_SIZE];
            for (y, row) in samples.iter_mut().enumerate() {
                for (x, sample) in row.iter_mut().enumerate() {
                    *sample = area_average_luminance(&pixels, width, height, width * 4, x, y);
                }
            }
            let coefficients = super::calculate_dct_coefficients(&samples);
            let mut sorted = coefficients[1..].to_vec();
            sorted.sort_by(|left, right| left.total_cmp(right));
            let median = sorted[sorted.len() / 2];
            let expected =
                coefficients[1..]
                    .iter()
                    .enumerate()
                    .fold(0_u64, |hash, (index, value)| {
                        if *value > median {
                            hash | (1_u64 << index)
                        } else {
                            hash
                        }
                    });
            assert_eq!(
                super::calculate_perceptual_hash(&pixels, width, height, width * 4),
                expected
            );
        }
    }

    #[test]
    fn area_partitions_cover_each_source_pixel_once() {
        let width = 100;
        let height = 100;
        let pixels = vec![0_u8; width * height * 4];
        let mut coverage = vec![0_u8; width];

        for target_x in 0..PHASH_SIZE {
            let x_start = target_x * width / PHASH_SIZE;
            let x_end = ((target_x + 1) * width / PHASH_SIZE)
                .min(width)
                .max(x_start + 1);
            for count in &mut coverage[x_start..x_end] {
                *count += 1;
            }
            let _ = area_average_luminance(&pixels, width, height, width * 4, target_x, 0);
        }

        assert!(coverage.iter().all(|count| *count == 1));
    }

    #[test]
    fn separable_dct_matches_reference_dct() {
        let mut samples = [[0.0_f64; PHASH_SIZE]; PHASH_SIZE];
        let mut state = 0x1234_5678_u64;
        for row in &mut samples {
            for sample in row {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1);
                *sample = (state >> 32) as f64 / u32::MAX as f64 * 255.0;
            }
        }

        let optimized = super::calculate_dct_coefficients(&samples);
        let reference = reference_dct(&samples);
        for (optimized_value, reference_value) in optimized.iter().zip(reference) {
            assert!((optimized_value - reference_value).abs() < 1e-8);
        }
    }

    fn reference_dct(samples: &[[f64; PHASH_SIZE]; PHASH_SIZE]) -> [f64; super::DCT_COEFFICIENTS] {
        let mut coefficients = [0.0_f64; super::DCT_COEFFICIENTS];
        let scale = std::f64::consts::PI / (2.0 * PHASH_SIZE as f64);
        for u in 0..8 {
            for v in 0..8 {
                let mut sum = 0.0_f64;
                for (y, row) in samples.iter().enumerate() {
                    for (x, sample) in row.iter().enumerate() {
                        let x_angle = (2 * x + 1) as f64 * u as f64 * scale;
                        let y_angle = (2 * y + 1) as f64 * v as f64 * scale;
                        sum += sample * x_angle.cos() * y_angle.cos();
                    }
                }
                coefficients[u * 8 + v] = sum;
            }
        }
        coefficients
    }
}
