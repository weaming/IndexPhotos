#ifndef INDEX_PHOTOS_RUST_H
#define INDEX_PHOTOS_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct IndexPhotosBlake3Hasher IndexPhotosBlake3Hasher;

IndexPhotosBlake3Hasher *index_photos_blake3_create(void);

bool index_photos_blake3_update(
    IndexPhotosBlake3Hasher *hasher,
    const uint8_t *data,
    size_t length
);

bool index_photos_blake3_finalize(
    const IndexPhotosBlake3Hasher *hasher,
    uint8_t *output,
    size_t output_length
);

void index_photos_blake3_destroy(IndexPhotosBlake3Hasher *hasher);

bool index_photos_perceptual_hash(
    const uint8_t *pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row,
    uint64_t *output
);

#endif
