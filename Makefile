CARGO ?= cargo
SWIFTC ?= xcrun swiftc
BENCH_BIN = dist/bin/scan-benchmark
RUST_DIR = rust-core
RUST_LIB = $(RUST_DIR)/target/release/libindex_photos_core.a
RUST_HEADER = $(RUST_DIR)/include/index_photos_rust.h
RUST_SOURCES = $(wildcard $(RUST_DIR)/src/*.rs)
MACOS_TARGET = $(shell uname -m)-apple-macosx15.0

build-bench: $(BENCH_BIN)

$(BENCH_BIN): $(wildcard IndexPhotos/Domain/*.swift IndexPhotos/Infrastructure/*.swift IndexPhotos/Scanning/*.swift) \
		Tests/Benchmarks/ScanBenchmark.swift $(RUST_HEADER) $(RUST_LIB) Makefile
	mkdir -p "$(dir $@)"
	$(SWIFTC) -O -swift-version 6 -parse-as-library -target $(MACOS_TARGET) \
		-import-objc-header $(RUST_HEADER) \
		-L $(RUST_DIR)/target/release -lindex_photos_core -lsqlite3 \
		$(filter %.swift,$^) -o "$@"

$(RUST_LIB): $(RUST_DIR)/Cargo.toml $(RUST_DIR)/Cargo.lock $(RUST_SOURCES) Makefile
	MACOSX_DEPLOYMENT_TARGET=15.0 $(CARGO) build --release --locked \
		--manifest-path $(RUST_DIR)/Cargo.toml --target-dir $(RUST_DIR)/target
