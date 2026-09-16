CARGO ?= cargo
SWIFTC ?= xcrun swiftc
XCODEGEN ?= xcodegen
XCODEBUILD ?= xcodebuild
ICON_SCRIPT ?= apply-icon.fish

XCODE_PROJECT ?= IndexPhotos.xcodeproj
XCODE_SCHEME ?= IndexPhotos
XCODE_CONFIGURATION ?= Debug
XCODE_DERIVED_DATA ?= tmp/DerivedData
APP_OUTPUT ?= dist/IndexPhotos.app
BUILT_APP = $(XCODE_DERIVED_DATA)/Build/Products/$(XCODE_CONFIGURATION)/$(XCODE_SCHEME).app
CURRENT_ARCH ?= $(shell uname -m)

SHELL := /bin/zsh

BENCH_BIN = dist/bin/scan-benchmark
RUST_DIR = rust-core
RUST_LIB = $(RUST_DIR)/target/release/libindex_photos_core.a
RUST_HEADER = $(RUST_DIR)/include/index_photos_rust.h
RUST_SOURCES = $(wildcard $(RUST_DIR)/src/*.rs)
MACOS_TARGET = $(shell uname -m)-apple-macosx15.0

app: FORCE
	@command -v fish >/dev/null 2>&1 || { echo "错误：未找到 fish"; exit 1; }
	@fish "$(ICON_SCRIPT)"
	@command -v "$(XCODEGEN)" >/dev/null 2>&1 || { echo "错误：未找到 xcodegen，请先安装 XcodeGen"; exit 1; }
	@"$(XCODEGEN)" generate
	@"$(XCODEBUILD)" \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-configuration "$(XCODE_CONFIGURATION)" \
		-destination 'platform=macOS,arch=$(CURRENT_ARCH)' \
		-derivedDataPath "$(XCODE_DERIVED_DATA)" \
		ONLY_ACTIVE_ARCH=YES \
		-quiet build
	@mkdir -p "$(dir $(APP_OUTPUT))"
	@/usr/bin/ditto "$(BUILT_APP)" "$(APP_OUTPUT)"
	@echo "应用已生成：$(APP_OUTPUT)"

open:
	open "$(APP_OUTPUT)"

clean: FORCE
	@if [ -e "$(XCODE_DERIVED_DATA)" ]; then /usr/bin/trash "$(XCODE_DERIVED_DATA)"; fi
	@if [ -e "$(APP_OUTPUT)" ]; then /usr/bin/trash "$(APP_OUTPUT)"; fi

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

FORCE:
