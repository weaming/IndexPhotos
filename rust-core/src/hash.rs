use std::panic::catch_unwind;
use std::slice;

const HASH_LENGTH: usize = 32;

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
