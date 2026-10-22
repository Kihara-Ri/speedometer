import SwiftUI
#if canImport(SpeedCore)
import SpeedCore
#endif

struct RecordingDistanceView: View {
    let report: SessionReport
    let entry: RecordingEntry
    @Bindable var model: SpeedometerModel
    @State private var startID = "recording-start"
    @State private var endID = "recording-end"
    @State private var reference = ""
    @State private var source = ""
    @State private var message: String?
    @FocusState private var editingDistance: Bool

    private var startTime: Double { report.markers.first { $0.id == startID }?.timestamp ?? report.startTime }
    private var endTime: Double { report.markers.first { $0.id == endID }?.timestamp ?? report.endTime }
    private var distance: DistanceSummary { report.distance(from: startTime, to: endTime) }
    private var referenceMeters: Double? {
        guard let value = Double(reference.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("选择区间") {
                Picker("起点", selection: $startID) {
                    Text("记录开始").tag("recording-start")
                    ForEach(report.markers) { marker in Text(marker.id + " · " + marker.title).tag(marker.id) }
                }
                Picker("终点", selection: $endID) {
                    ForEach(report.markers) { marker in Text(marker.id + " · " + marker.title).tag(marker.id) }
                    Text("记录结束").tag("recording-end")
                }
                if endTime <= startTime { Text("终点必须晚于起点").foregroundStyle(.orange) }
            }
            Section {
                ReportValue(title: "区间时长", value: reportTime(distance.duration))
                ReportValue(title: distance.isComplete ? "推测距离" : "已覆盖距离", value: reportNumber(distance.meters, digits: 1, suffix: " m"))
                ReportValue(title: "有效时间覆盖率", value: reportNumber(distance.coverage * 100, digits: 1, suffix: "%"))
                ReportValue(title: "最长缺口", value: reportNumber(distance.longestGap, digits: 1, suffix: " s"))
                ReportValue(title: "区间平均速度", value: reportNumber(distance.averageSpeed.map { $0 * 3.6 }, digits: 2, suffix: " km/h"))
            } header: { Text("手机数据积分") }
              footer: { Text("以完整分析采样作梯形积分，不使用图表抽样点；缺失区间不补零、不外推。") }
            Section("铁路距离对照") {
                TextField("铁路距离（米）", text: $reference).keyboardType(.decimalPad).focused($editingDistance)
                TextField("距离来源、线路或里程定义", text: $source, axis: .vertical)
                if let meters = referenceMeters {
                    ReportValue(title: "参考距离", value: reportNumber(meters, digits: 1, suffix: " m"))
                    if distance.isComplete {
                        ReportValue(title: "有符号距离误差", value: reportNumber(distance.meters - meters, digits: 1, suffix: " m"))
                        ReportValue(title: "误差比例", value: reportNumber((distance.meters - meters) / meters * 100, suffix: "%"))
                    } else {
                        Text("该区间有采样缺口，无法给出完整距离误差。").foregroundStyle(.orange).font(.caption)
                    }
                }
                Button("保存这段参考距离") { save() }
                    .disabled(referenceMeters == nil || endTime <= startTime)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("已保存的区间") {
                ForEach((try? model.recordingStore.info(for: entry.url).references) ?? []) { value in
                    Button {
                        startID = value.startMarker; endID = value.endMarker
                        reference = String(value.meters); source = value.source
                    } label: {
                        VStack(alignment: .leading) {
                            Text(value.startMarker + " → " + value.endMarker + " · " + reportNumber(value.meters, digits: 1, suffix: " m"))
                            Text(value.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section { Text("参考距离只用于对照，不会反过来修正本次曲线。逐站误差与全程误差应同时看，防止前后偏差抵消。").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("距离推测与核对")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let segment = report.stationSegments.first { startID = segment.start.id; endID = segment.end.id }
            loadReference()
        }
        .onChange(of: startID) { _, _ in loadReference() }
        .onChange(of: endID) { _, _ in loadReference() }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { editingDistance = false } } }
    }

    private func loadReference() {
        let info = try? model.recordingStore.info(for: entry.url)
        let existing = info?.references.first { $0.startMarker == startID && $0.endMarker == endID }
        reference = existing.map { String($0.meters) } ?? ""; source = existing?.source ?? ""; message = nil
    }

    private func save() {
        guard let meters = referenceMeters else { return }
        do {
            var info = try model.recordingStore.info(for: entry.url)
            info.references.removeAll { $0.startMarker == startID && $0.endMarker == endID }
            info.references.append(DistanceReference(startMarker: startID, endMarker: endID, meters: meters, source: source))
            try model.saveRecordingInfo(info, for: entry.url)
            message = "参考距离已保存"; editingDistance = false
        } catch { message = error.localizedDescription }
    }
}
