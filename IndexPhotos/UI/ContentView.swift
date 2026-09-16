import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isImporterPresented = false

    var body: some View {
        NavigationSplitView {
            SidebarView(isImporterPresented: $isImporterPresented)
        } detail: {
            DashboardView()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                model.selectDirectory(urls)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AppLogoView: View {
    let size: CGFloat

    init(size: CGFloat = 42) {
        self.size = size
    }

    var body: some View {
        Group {
            if let logoImage = NSApp.applicationIconImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var isImporterPresented: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppLogoView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IndexPhotos")
                            .font(.headline)
                        Text("重复照片助手")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("IndexPhotos，重复照片助手")
            }

            Section("扫描目录") {
                if let selectedRootURL = model.selectedRootURL {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedRootURL.lastPathComponent)
                            Text(selectedRootURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                } else {
                    Text("尚未选择目录")
                        .foregroundStyle(.secondary)
                }

                Button("选择照片目录…") {
                    isImporterPresented = true
                }
            }

            if let resumableScan = model.resumableScan {
                Section("可继续任务") {
                    Button {
                        model.resumeScan()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("继续扫描")
                                Text("已提交 \(resumableScan.committedCount) / \(resumableScan.discoveredCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("缓存") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("缓存已统一保存")
                        Text(model.cachePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                } icon: {
                    Image(systemName: "internaldrive")
                }
            }
        }
        .navigationTitle("IndexPhotos")
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }
}

private struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.isReady {
                InitializationErrorView()
            } else if model.selectedRootURL == nil {
                WelcomeView()
            } else {
                ScanDashboardView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.startScan()
                } label: {
                    Label("开始扫描", systemImage: "play.fill")
                }
                .disabled(model.isScanning || model.selectedRootURL == nil)

                Button {
                    model.pauseScan()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .disabled(!model.isScanning)

                Button {
                    model.cancelScan()
                } label: {
                    Label("取消", systemImage: "stop.fill")
                }
                .disabled(!model.isScanning)
            }
        }
        .alert("发生错误", isPresented: errorPresented) {
            Button("好") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }
}

private struct WelcomeView: View {
    var body: some View {
        ContentUnavailableView {
            Label("选择照片目录", systemImage: "photo.on.rectangle")
        } description: {
            Text("选择一个目录后开始登记照片。扫描结果和断点信息会保存到 ~/.index-photos/。")
        }
    }
}

private struct InitializationErrorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("缓存不可用", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(model.errorMessage ?? "无法初始化缓存目录。")
        }
    }
}

private struct ScanDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedRootURL?.lastPathComponent ?? "照片目录")
                        .font(.largeTitle)
                        .bold()
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }

                ProgressPanel(snapshot: model.currentProgress)

                if let lastPath = model.currentProgress.lastPath {
                    GroupBox("最近处理") {
                        Text(lastPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SimilarityCandidatesPanel()
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: model.selectedRootID) {
            model.refreshSimilarityCandidates(resetPage: true)
        }
    }
}

private struct SimilarityCandidatesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("相似候选") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            model.showReviewedSimilarityCandidates
                                ? "显示全部候选"
                                : "待人工处理"
                        )
                        Text("\(model.similarityVisibleCount) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    SimilarityScoreBucketMenu()

                    Button {
                        model.toggleReviewedSimilarityCandidates()
                    } label: {
                        Label(
                            model.showReviewedSimilarityCandidates
                                ? "仅显示待处理"
                                : "显示已审核",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                if model.similarityCandidates.isEmpty,
                   model.isLoadingSimilarityCandidates
                {
                    ProgressView("正在读取相似候选…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.similarityCandidates.isEmpty {
                    ContentUnavailableView {
                        Label("暂无相似候选", systemImage: "checkmark.circle")
                    } description: {
                        Text(
                            model.showReviewedSimilarityCandidates
                                ? "当前目录还没有可查看的相似照片。"
                                : "新发现的轻微修改、裁剪或曝光变化会出现在这里。"
                        )
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ZStack(alignment: .topTrailing) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.similarityCandidates) { candidate in
                                SimilarityCandidateRow(
                                    candidate: candidate,
                                    thumbnailRootURL: model.thumbnailCacheURL,
                                    isUpdating: model.isUpdatingSimilarityCandidate(candidate.id),
                                    onDecision: { decision in
                                        model.reviewCandidate(
                                            candidate.id,
                                            decision: decision
                                        )
                                    },
                                    onClearDecision: {
                                        model.clearReviewDecision(candidate.id)
                                    }
                                )
                            }
                        }

                        if model.isLoadingSimilarityCandidates {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }

                    SimilarityCandidatesPagination()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SimilarityScoreBucketMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.selectSimilarityScoreBucket(.all)
            } label: {
                Text(menuTitle(for: .all))
            }

            Divider()

            ForEach(SimilarityScoreBucket.valuesDescending) { bucket in
                Button {
                    model.selectSimilarityScoreBucket(bucket)
                } label: {
                    Text(menuTitle(for: bucket))
                }
            }
        } label: {
            Label(
                "区间：\(model.similarityScoreBucket.title)",
                systemImage: "slider.horizontal.3"
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func menuTitle(for bucket: SimilarityScoreBucket) -> String {
        let marker = bucket == model.similarityScoreBucket ? "✓ " : ""
        return "\(marker)\(bucket.title)（\(model.similarityBucketCount(for: bucket))）"
    }
}

private struct SimilarityCandidatesPagination: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text("每页 24 项")
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.setSimilarityPage(model.similarityPageIndex - 1)
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasPreviousSimilarityPage || model.isLoadingSimilarityCandidates)

            Text("第 \(model.similarityPageNumber) / \(max(model.similarityPageCount, 1)) 页")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.setSimilarityPage(model.similarityPageIndex + 1)
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasNextSimilarityPage || model.isLoadingSimilarityCandidates)
        }
        .font(.caption)
    }
}

private struct SimilarityCandidateRow: View {
    let candidate: SimilarityReviewItem
    let thumbnailRootURL: URL?
    let isUpdating: Bool
    let onDecision: (ReviewDecision) -> Void
    let onClearDecision: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                CandidatePhotoCard(
                    path: candidate.assetAPath,
                    sizeBytes: candidate.assetASizeBytes,
                    thumbnailRootURL: thumbnailRootURL,
                    thumbnailRelativePath: candidate.thumbnailARelativePath
                )

                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 72)
                    .accessibilityHidden(true)

                CandidatePhotoCard(
                    path: candidate.assetBPath,
                    sizeBytes: candidate.assetBSizeBytes,
                    thumbnailRootURL: thumbnailRootURL,
                    thumbnailRelativePath: candidate.thumbnailBRelativePath
                )
            }

            HStack(spacing: 12) {
                Text(
                    "相似度 \(candidate.score, format: .number.precision(.fractionLength(2)))"
                )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(candidate.relationKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let decision = candidate.decision {
                    Text(reviewDecisionTitle(decision))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("取消标记") {
                        onClearDecision()
                    }
                } else {
                    Button("保留两张") {
                        onDecision(.keep)
                    }
                    Button("删除左图", role: .destructive) {
                        onDecision(.deleteA)
                    }
                    Button("删除右图", role: .destructive) {
                        onDecision(.deleteB)
                    }
                    Button("跳过") {
                        onDecision(.ignore)
                    }
                }
            }
            .disabled(isUpdating)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reviewDecisionTitle(_ decision: ReviewDecision) -> String {
        switch decision {
        case .keep:
            return "已标记保留两张"
        case .deleteA:
            return "已标记删除左图"
        case .deleteB:
            return "已标记删除右图"
        case .process:
            return "已审核"
        case .ignore:
            return "已跳过"
        }
    }
}

private struct CandidatePhotoCard: View {
    let path: String
    let sizeBytes: Int64
    let thumbnailRootURL: URL?
    let thumbnailRelativePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedThumbnailView(
                cacheRootURL: thumbnailRootURL,
                relativePath: thumbnailRelativePath
            )

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .help(path)

            Text("\(sizeInMB, format: .number.precision(.fractionLength(2))) MB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: path)
                ])
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sizeInMB: Double {
        Double(max(sizeBytes, 0)) / 1_000_000
    }
}

private struct CachedThumbnailView: View {
    let cacheRootURL: URL?
    let relativePath: String?

    @State private var image: NSImage?
    @State private var hasLoadFailed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("照片缩略图")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if hasLoadFailed {
                    Label("缩略图不可用", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: thumbnailURL?.path) {
            await loadImage()
        }
    }

    private var thumbnailURL: URL? {
        guard let cacheRootURL,
              let relativePath,
              !relativePath.isEmpty
        else {
            return nil
        }

        let rootPath = cacheRootURL.standardizedFileURL.path
        let fileURL = cacheRootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return fileURL
    }

    private func loadImage() async {
        image = nil
        hasLoadFailed = false
        guard let thumbnailURL else {
            hasLoadFailed = true
            return
        }

        do {
            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: thumbnailURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else {
                return
            }
            guard let decodedImage = NSImage(data: data) else {
                hasLoadFailed = true
                return
            }
            image = decodedImage
        } catch {
            hasLoadFailed = true
        }
    }
}

private struct ProgressPanel: View {
    let snapshot: ScanProgressSnapshot

    var body: some View {
        GroupBox("扫描进度") {
            VStack(alignment: .leading, spacing: 12) {
                if let fractionCompleted = snapshot.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                } else {
                    ProgressView()
                }

                HStack(spacing: 20) {
                    ProgressMetric(title: "已发现", value: "\(snapshot.discoveredCount)")
                    ProgressMetric(title: "已提交", value: "\(snapshot.committedCount)")
                    ProgressMetric(title: "失败", value: "\(snapshot.failedCount)")
                    ProgressMetric(title: "阶段", value: phaseTitle(snapshot.phase))
                }

                if !snapshot.isTotalKnown {
                    Text("正在枚举目录，文件总量确定后显示精确进度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseTitle(_ phase: ScanPhase) -> String {
        switch phase {
        case .prepare: return "准备"
        case .enumerate: return "登记"
        case .fastFeatures: return "快速特征"
        case .embedding: return "向量"
        case .index: return "索引"
        case .verify: return "复核"
        case .finalize: return "整理"
        }
    }
}

private struct ProgressMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("缓存目录", value: "~/.index-photos/")
            LabeledContent("最低系统版本", value: "macOS 15")
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
