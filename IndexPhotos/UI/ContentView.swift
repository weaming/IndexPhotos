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
            allowsMultipleSelection: true
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
    @State private var rootToRemove: SavedRoot?
    @State private var isRootRemovalDialogPresented = false

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

            Section {
                HStack {
                    Text("目录")
                    Spacer()
                    Toggle(
                        "多选目录",
                        isOn: Binding(
                            get: { model.isSimilarityMultiSelectEnabled },
                            set: { model.setSimilarityMultiSelectEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("开启后可勾选多个目录进行跨根目录相似探测")
                }

                if model.savedRoots.isEmpty {
                    Text("尚未选择目录")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.savedRoots) { root in
                    SavedRootListItem(root: root) {
                        rootToRemove = root
                        isRootRemovalDialogPresented = true
                    }
                }

                Button("添加照片目录…") {
                    isImporterPresented = true
                }
            } header: {
                Text("扫描目录")
            }

            if !model.resumableScans.isEmpty {
                Section("可继续任务") {
                    ForEach(model.resumableScans) { resumableScan in
                        Button {
                            model.selectRoot(resumableScan.rootID)
                            model.resumeScan(for: resumableScan.rootID)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.rootName(for: resumableScan.rootID))
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
        .confirmationDialog(
            "移除目录索引？",
            isPresented: $isRootRemovalDialogPresented,
            titleVisibility: .visible
        ) {
            if let root = rootToRemove {
                Button("移除 \(root.displayName) 的索引", role: .destructive) {
                    model.removeSavedRoot(root.id)
                }
            }
        } message: {
            Text(
                rootToRemove.map {
                    "将清除该目录在 IndexPhotos 中的扫描结果和缓存引用，不会删除磁盘上的实际目录或照片。\n\n\($0.url.path)"
                } ?? "将清除该目录在 IndexPhotos 中的扫描结果和缓存引用。"
            )
        }
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

private struct SavedRootListItem: View {
    @Environment(AppModel.self) private var model
    let root: SavedRoot
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if model.isSimilarityMultiSelectEnabled {
                Button {
                    model.toggleSimilarityRoot(root.id)
                } label: {
                    Image(
                        systemName: model.isSimilarityRootSelected(root.id)
                            ? "checkmark.square.fill"
                            : "square"
                    )
                    .foregroundStyle(
                        model.isSimilarityRootSelected(root.id)
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("纳入相似探测")
            }

            Button {
                model.selectRoot(root.id)
            } label: {
                SavedRootRow(
                    root: root,
                    progress: model.progress(for: root.id),
                    isSelected: model.selectedRootID == root.id,
                    isScanning: model.activeScanRootIDs.contains(root.id)
                )
            }
            .buttonStyle(.plain)

            SavedRootActionsMenu(
                isDisabled: model.activeScanRootIDs.contains(root.id),
                onRemove: onRemove
            )
        }
    }
}

private struct SavedRootActionsMenu: View {
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        Menu {
            Button("移除目录索引", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .accessibilityLabel("目录操作")
        }
        .menuStyle(.borderlessButton)
        .disabled(isDisabled)
        .help(isDisabled ? "扫描中不能移除目录索引" : "目录操作")
    }
}

private struct SavedRootRow: View {
    let root: SavedRoot
    let progress: ScanProgressSnapshot
    let isSelected: Bool
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isScanning ? "arrow.triangle.2.circlepath" : "folder")
                .foregroundStyle(isScanning ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                    .lineLimit(1)
                Text(root.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(statusTitle)
                    .font(.caption2)
                    .foregroundStyle(isScanning ? Color.accentColor : Color.secondary)
            }

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusTitle: String {
        if isScanning {
            return "扫描中 · \(phaseTitle(progress.phase))"
        }
        switch progress.status {
        case .paused, .recovering:
            return "已暂停，可继续"
        case .completed:
            return "已完成 · \(progress.committedCount) 个文件"
        case .cancelled:
            return "已取消"
        case .failed:
            return "扫描失败"
        case .queued, .running, .pausing:
            return phaseTitle(progress.phase)
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
                .disabled(model.isSelectedRootScanning || model.selectedRootURL == nil)

                if model.selectedRootResumableScan != nil {
                    Button {
                        model.resumeScan()
                    } label: {
                        Label("继续扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isSelectedRootScanning)
                }

                Button {
                    model.pauseScan()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .disabled(!model.isSelectedRootScanning)

                Button {
                    model.cancelScan()
                } label: {
                    Label("取消", systemImage: "stop.fill")
                }
                .disabled(!model.isSelectedRootScanning)
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
            Text("选择一个或多个目录后查找相同或相似的照片。扫描结果和断点信息会保存到 ~/.index-photos/。")
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
    @State private var isDeletionDialogPresented = false
    @State private var deletionMode = PhotoDeletionMode.trash

    var body: some View {
        GroupBox("相同或相似候选") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            model.showReviewedSimilarityCandidates
                                ? "已审核候选"
                                : "待人工处理"
                        )
                        Text("\(model.similarityVisibleCount) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    SimilarityAlgorithmMenu()
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

                if model.pendingDeletionCount > 0 {
                    HStack(spacing: 10) {
                        Label(
                            "待删除 \(model.pendingDeletionCount) 项",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)

                        Spacer(minLength: 0)

                        Button {
                            deletionMode = .trash
                            isDeletionDialogPresented = true
                        } label: {
                            Label("移到废纸篓", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button {
                            deletionMode = .permanent
                            isDeletionDialogPresented = true
                        } label: {
                            Label("永久删除", systemImage: "trash.slash")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }
                    .disabled(model.isDeletingPhotos)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if model.similarityCandidates.isEmpty,
                   model.isLoadingSimilarityCandidates
                {
                    ProgressView("正在读取相似候选…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.similarityCandidates.isEmpty {
                    ContentUnavailableView {
                        Label(
                            model.showReviewedSimilarityCandidates
                                ? "暂无已审核候选"
                                : "暂无待处理候选",
                            systemImage: "checkmark.circle"
                        )
                    } description: {
                        Text(
                            model.showReviewedSimilarityCandidates
                                ? "当前探测范围还没有已审核的相似照片。"
                                : "相似度超过 0.6 的相同或相似照片会出现在当前探测范围。"
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
        .confirmationDialog(
            "确认\(deletionMode.title)",
            isPresented: $isDeletionDialogPresented,
            titleVisibility: .visible
        ) {
            Button(deletionMode.title, role: .destructive) {
                model.executePendingDeletions(mode: deletionMode)
            }
        } message: {
            switch deletionMode {
            case .trash:
                Text("将把当前筛选中的 \(model.pendingDeletionCount) 张照片移到 macOS 废纸篓，并清理对应索引。照片仍可从废纸篓恢复。")
            case .permanent:
                Text("将永久删除当前筛选中的 \(model.pendingDeletionCount) 张照片，并清理对应索引。此操作无法恢复。")
            }
        }
    }
}

private struct SimilarityAlgorithmMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(SimilarityAlgorithmFilter.allCases) { filter in
                Button {
                    model.selectSimilarityAlgorithmFilter(filter)
                } label: {
                    Label {
                        Text(filter.title)
                    } icon: {
                        Image(
                            systemName: filter == model.similarityAlgorithmFilter
                                ? "checkmark"
                                : "circle"
                        )
                    }
                }
            }
        } label: {
            Label(
                "来源：\(model.similarityAlgorithmFilter.title)",
                systemImage: "camera.filters"
            )
        }
        .menuStyle(.borderlessButton)
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

            ForEach(availableBuckets) { bucket in
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

    private var availableBuckets: [SimilarityScoreBucket] {
        SimilarityScoreBucket.valuesDescending.filter {
            model.similarityBucketCount(for: $0) > 0
        }
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
                model.setSimilarityPage(0)
            } label: {
                Label("首页", systemImage: "chevron.left.2")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasPreviousSimilarityPage || model.isLoadingSimilarityCandidates)

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

            Button {
                model.setSimilarityPage(model.similarityPageCount - 1)
            } label: {
                Label("尾页", systemImage: "chevron.right.2")
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
                    thumbnailRootURL: thumbnailRootURL,
                    thumbnailRelativePath: candidate.thumbnailARelativePath
                )

                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 72)
                    .accessibilityHidden(true)

                CandidatePhotoCard(
                    path: candidate.assetBPath,
                    thumbnailRootURL: thumbnailRootURL,
                    thumbnailRelativePath: candidate.thumbnailBRelativePath
                )
            }

            HStack(spacing: 12) {
                Text(metadataText)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)

                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else if let decision = candidate.decision {
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
                    Button("标记左图待删除", role: .destructive) {
                        onDecision(.deleteA)
                    }
                    Button("标记右图待删除", role: .destructive) {
                        onDecision(.deleteB)
                    }
                    Button("跳过") {
                        onDecision(.ignore)
                    }
                }
            }
            .disabled(isUpdating)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reviewDecisionTitle(_ decision: ReviewDecision) -> String {
        switch decision {
        case .keep:
            return "已标记保留两张"
        case .deleteA:
            return "已标记左图待删除"
        case .deleteB:
            return "已标记右图待删除"
        case .process:
            return "已审核"
        case .ignore:
            return "已跳过"
        }
    }

    private var metadataText: String {
        "\(sizeInMB(candidate.assetASizeBytes))MB / \(sizeInMB(candidate.assetBSizeBytes))MB, \(relationTitle) \(String(format: "%.2f", candidate.score)), \(algorithmTitle)"
    }

    private var relationTitle: String {
        candidate.relationKind == "exact_same_file" ? "相同" : "相似"
    }

    private var algorithmTitle: String {
        switch candidate.algorithmVersion {
        case "exact-v1":
            return "exact"
        case "fast-phash-v1":
            return "phash"
        case "vision-hnsw-v1":
            return "vision"
        default:
            return candidate.algorithmVersion
        }
    }

    private func sizeInMB(_ sizeBytes: Int64) -> String {
        String(format: "%.2f", Double(max(sizeBytes, 0)) / 1_000_000)
    }
}

private struct CandidatePhotoCard: View {
    let path: String
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
                if isNotStarted {
                    Label("尚未开始", systemImage: "circle")
                        .foregroundStyle(.secondary)
                } else if let fractionCompleted = snapshot.fractionCompleted {
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

                if !isNotStarted, !snapshot.isTotalKnown {
                    Text("正在枚举目录，文件总量确定后显示精确进度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isNotStarted: Bool {
        snapshot.scanID == nil && snapshot.status == .completed
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
