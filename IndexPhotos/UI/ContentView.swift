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

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var isImporterPresented: Bool

    var body: some View {
        List {
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
        VStack(alignment: .leading, spacing: 24) {
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

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
