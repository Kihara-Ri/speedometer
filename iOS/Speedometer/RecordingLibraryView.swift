import SwiftUI
#if canImport(SpeedCore)
import SpeedCore
#endif

struct RecordingView: View {
    @Bindable var model: SpeedometerModel
    @Environment(\.dismiss) private var dismiss
    var initialRecordingURL: URL? = nil
    @State private var path: [URL] = []
    @State private var openedInitialRecording = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isRecording || model.isFinalizingRecording {
                    Section {
                        Label(model.isFinalizingRecording ? "本次行程正在保存…" : "本次测速正在自动记录", systemImage: "record.circle")
                            .foregroundStyle(Palette.measured)
                        Text("停止测速后，本次行程会出现在这里，可查看速度曲线和详细数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message = error ?? model.recordingError {
                    Section("操作异常") { Text(message).foregroundStyle(.red) }
                }
                Section("全部记录 · \(model.recordings.count)") {
                    ForEach(model.recordings) { entry in
                        NavigationLink {
                            RecordingDetailView(entry: entry, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.headline)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !entry.info.note.isEmpty { Text(entry.info.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button("移入最近删除", role: .destructive) { perform { try model.trashRecording(entry) } }
                        }
                        .contextMenu {
                            ShareLink(item: entry.url) { Label("导出原始数据", systemImage: "square.and.arrow.up") }
                            Button("移入最近删除", role: .destructive) { perform { try model.trashRecording(entry) } }
                        }
                    }
                    if model.recordings.isEmpty {
                        Text("每次测速都会自动记录。停止测速后，在这里查看速度曲线、距离和详细数据。").foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink("最近删除（\(model.deletedRecordings.count)）") {
                        List {
                            ForEach(model.deletedRecordings) { entry in
                                HStack {
                                    VStack(alignment: .leading) { Text(entry.title); Text(entry.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button("恢复") { perform { try model.restoreRecording(entry) } }.buttonStyle(.bordered)
                                }
                            }
                            if model.deletedRecordings.isEmpty { Text("没有已删除的记录").foregroundStyle(.secondary) }
                        }.navigationTitle("最近删除")
                    }
                } footer: { Text("原始日志保留完整采样。可通过分享或 Finder 文件共享导出；移入最近删除后可恢复。") }
            }
            .navigationTitle("行程记录")
            .navigationDestination(for: URL.self) { url in
                if let entry = model.recordings.first(where: { $0.url == url }) {
                    RecordingDetailView(entry: entry, model: model)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                model.refreshRecordings()
                if !openedInitialRecording, let url = initialRecordingURL,
                   model.recordings.contains(where: { $0.url == url }) { path = [url] }
                openedInitialRecording = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct ReportValue: View {
    let title: String
    let value: String
    var body: some View { LabeledContent(title, value: value).font(.subheadline).monospacedDigit() }
}

func reportNumber(_ value: Double?, digits: Int = 2, suffix: String = "") -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.\(digits)f", value) + suffix
}

func reportTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
}
