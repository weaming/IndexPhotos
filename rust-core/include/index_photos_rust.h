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

typedef struct IndexPhotosGeometryResult {
    uint32_t matched_count;
    uint32_t inlier_count;
    float inlier_ratio;
    float coverage;
    float median_error;
    uint8_t passed;
} IndexPhotosGeometryResult;

bool index_photos_verify_geometry(
    const uint8_t *left_pixels,
    size_t left_width,
    size_t left_height,
    size_t left_bytes_per_row,
    const uint8_t *right_pixels,
    size_t right_width,
    size_t right_height,
    size_t right_bytes_per_row,
    IndexPhotosGeometryResult *output
);

typedef struct IndexPhotosHnswIndex IndexPhotosHnswIndex;

IndexPhotosHnswIndex *index_photos_hnsw_create(
    size_t dimension,
    size_t max_neighbors,
    size_t construction_ef
);

bool index_photos_hnsw_insert(
    IndexPhotosHnswIndex *index,
    uint64_t label,
    const float *vector,
    size_t vector_length
);

size_t index_photos_hnsw_search(
    const IndexPhotosHnswIndex *index,
    const float *query,
    size_t query_length,
    size_t limit,
    size_t search_ef,
    uint64_t *labels,
    float *distances,
    size_t result_capacity
);

size_t index_photos_hnsw_serialized_length(
    const IndexPhotosHnswIndex *index
);

bool index_photos_hnsw_serialize(
    const IndexPhotosHnswIndex *index,
    uint8_t *output,
    size_t output_length
);

IndexPhotosHnswIndex *index_photos_hnsw_deserialize(
    const uint8_t *data,
    size_t length
);

void index_photos_hnsw_destroy(IndexPhotosHnswIndex *index);

#endif
