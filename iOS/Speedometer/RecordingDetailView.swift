import SwiftUI
import Charts
#if canImport(SpeedCore)
import SpeedCore
#endif

struct RecordingDetailView: View {
    let entry: RecordingEntry
    @Bindable var model: SpeedometerModel
    @State private var report: SessionReport?
    @State private var plot: [SessionSample] = []
    @State private var info = RecordingInfo()
    @State private var selection: Double?
    @State private var metric = "速度"
    @State private var error: String?
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftNote = ""
    @State private var csvURL: URL?
    @State private var exporting = false

    private var selected: SessionSample? {
        guard let report else { return nil }
        return report.nearestSample(to: report.startTime + (selection ?? 0))
    }

    var body: some View {
        Group {
            if let report {
                List {
                    summary(report)
                    Section {
                        Picker("曲线", selection: $metric) {
                            ForEach(["速度", "累计距离", "加速度"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented)
                        chart(report).frame(height: 220).padding(.vertical, 8)
                        HStack(spacing: 12) {
                            Label("估计", systemImage: "circle.fill").foregroundStyle(Palette.measured)
                            if metric == "速度" { Label("原始定位", systemImage: "circle.fill").foregroundStyle(.orange) }
                        }.font(.caption2)
                        Text("横轴为经过时间（秒）。拖动曲线或下方滑块查看原始时刻的数据；采样缺口处断线。定位速度是同源对照。").font(.caption).foregroundStyle(.secondary)
                        if report.duration > 0 {
                            Slider(value: Binding(get: { selection ?? 0 }, set: { selection = $0 }), in: 0...report.duration)
                                .accessibilityLabel("回看时间")
                        }
                    } header: { Text("全过程曲线") }
                    if let selected { sampleSection(selected, report: report) }
                    Section("距离核对") {
                        NavigationLink("选择时间标记与铁路距离") {
                            RecordingDistanceView(report: report, entry: entry, model: model)
                        }
                        ForEach(report.stationSegments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.title)
                                Text(reportNumber(segment.distance.meters, digits: 1, suffix: " m") + " · " + reportTime(segment.distance.duration) + " · 覆盖 " + reportNumber(segment.distance.coverage * 100, digits: 1, suffix: "%"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("事件标记") {
                        ForEach(report.markers) { marker in
                            Button {
                                selection = marker.timestamp - report.startTime
                            } label: {
                                HStack {
                                    Text(reportTime(marker.timestamp - report.startTime)).monospacedDigit()
                                    Text(marker.marker.kind == "arrival" ? "到站停稳" : marker.marker.kind == "departure" ? "起步" : "事件")
                                    Text(marker.title).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }
                        if report.markers.isEmpty { Text("这份记录没有事件标记").foregroundStyle(.secondary) }
                    }
                    if !report.railCandidates.isEmpty {
                        Section("到站推测与反馈") {
                            ForEach(report.railCandidates) { candidate in
                                let resolution = report.railResolutions.first { $0.candidateID == candidate.id }
                                HStack {
                                    Text(reportTime(candidate.stoppedAt - report.startTime)).monospacedDigit()
                                    Spacer()
                                    Text(resolution?.answer == .confirmed ? "已确认到站" :
                                         resolution?.answer == .denied ? "已否认" : "未确认")
                                }.font(.subheadline)
                            }
                        }
                    }
                    Section("采样质量") {
                        ForEach(report.sensorStats.keys.sorted(), id: \.self) { key in
                            if let stats = report.sensorStats[key] {
                                VStack(alignment: .leading, spacing: 4) {
                                    ReportValue(title: sensorName(key), value: "\(stats.count) 条 · " + reportNumber(stats.averageHz, digits: 1, suffix: " Hz"))
                                    Text("最大间隔 " + reportNumber(stats.largestInterval, suffix: " s") + " · 平均回调延迟 " + reportNumber(stats.averageDelay.map { $0 * 1000 }, digits: 1, suffix: " ms"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ReportValue(title: "总事件", value: "\(report.eventCount)")
                        ReportValue(title: "损坏或乱序行", value: "\(report.malformedLines)")
                        ForEach(Array(report.sensorErrors.enumerated()), id: \.offset) { _, message in Text(message).font(.caption).foregroundStyle(.orange) }
                    }
                    Section("记录信息") {
                        if !info.note.isEmpty { Text(info.note) }
                        ForEach(report.metadata.keys.sorted(), id: \.self) { key in
                            ReportValue(title: key, value: report.metadata[key] ?? "—")
                        }
                        Text(entry.url.lastPathComponent).font(.caption2).textSelection(.enabled)
                    }
                    Section("导出") {
                        ShareLink(item: entry.url) { Label("完整原始数据 · JSONL", systemImage: "square.and.arrow.up") }
                        Button(exporting ? "正在生成…" : "生成速度与诊断 CSV") { exportCSV(report) }.disabled(exporting)
                        if let csvURL { ShareLink(item: csvURL) { Label("分享 CSV", systemImage: "tablecells") } }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
            } else if let error {
                ContentUnavailableView("无法读取记录", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView("正在读取详细数据…") }
        }
        .navigationTitle(info.title.isEmpty ? entry.title : info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") {
                    draftTitle = info.title; draftNote = info.note; error = nil; editing = true
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    TextField("记录名称", text: $draftTitle)
                    TextField("备注", text: $draftNote, axis: .vertical).lineLimit(3...8)
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle("名称与备注")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                do {
                                    var latest = try model.recordingStore.info(for: entry.url)
                                    latest.title = draftTitle; latest.note = draftNote
                                    try model.saveRecordingInfo(latest, for: entry.url)
                                    info = latest; editing = false
                                }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
            }.preferredColorScheme(.dark)
        }
        .task {
            do {
                info = try model.recordingStore.info(for: entry.url)
                let url = entry.url
                let job = Task.detached(priority: .userInitiated) { try SessionReport.load(url: url) }
                let loaded = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation()
                plot = loaded.plotSamples(); report = loaded
            } catch is CancellationError { }
              catch { self.error = error.localizedDescription }
        }
    }

    private func summary(_ report: SessionReport) -> some View {
        let distance = report.distance
        return Section {
            ReportValue(title: "记录时长", value: reportTime(report.duration))
            ReportValue(title: distance.isComplete ? "估计距离" : "已覆盖区间距离", value: reportNumber(distance.meters / 1000, digits: 3, suffix: " km"))
            ReportValue(title: "时间覆盖率", value: reportNumber(distance.coverage * 100, digits: 1, suffix: "%"))
            ReportValue(title: "最长缺口", value: reportNumber(distance.longestGap, digits: 1, suffix: " s"))
            ReportValue(title: "最高估计速度", value: reportNumber(report.peakSpeed.map { $0 * 3.6 }, digits: 1, suffix: " km/h"))
            ReportValue(title: "记录状态", value: report.endedNormally ? "正常结束" : "未正常结束 / 旧版记录")
        } header: { Text("行程概览") }
          footer: { if !distance.isComplete { Text("缺口没有补零或猜测。显示的是有效区间积分，不能把它作为全程完整里程。") } }
    }

    private func chart(_ report: SessionReport) -> some View {
        Chart {
            ForEach(plot) { point in
                if let y = plotValue(point) {
                    LineMark(x: .value("时间", point.timestamp - report.startTime), y: .value(metric, y), series: .value("连续区间", point.run))
                        .foregroundStyle(Palette.measured)
                }
                if metric == "速度", let raw = point.rawSpeed, raw.speed.isFinite, raw.speed >= 0,
                   raw.speedAccuracy >= 0, abs(point.timestamp - raw.timestamp) <= 2.5 {
                    LineMark(x: .value("时间", point.timestamp - report.startTime), y: .value("原始定位", raw.speed * 3.6), series: .value("原始连续区间", "raw-\(point.run)"))
                        .foregroundStyle(.orange.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let selected {
                RuleMark(x: .value("选中时间", selected.timestamp - report.startTime))
                    .foregroundStyle(.white.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .chartXScale(domain: 0...max(1, report.duration))
        .chartXSelection(value: $selection)
        .chartYAxisLabel(metric == "速度" ? "km/h" : metric == "累计距离" ? "m" : "m/s²")
        .chartLegend(.hidden)
    }

    private func plotValue(_ point: SessionSample) -> Double? {
        guard let speed = point.speed else { return nil }
        if metric == "速度" { return speed * 3.6 }
        if metric == "累计距离" { return point.cumulativeMeters }
        return point.diagnostics?.state?[1]
    }

    private func sampleSection(_ point: SessionSample, report: SessionReport) -> some View {
        Section("选中时刻 · " + reportTime(point.timestamp - report.startTime)) {
            ReportValue(title: "时间（精确）", value: reportNumber(point.timestamp - report.startTime, digits: 3, suffix: " s"))
            ReportValue(title: "估计速度", value: reportNumber(point.speed.map { $0 * 3.6 }, digits: 2, suffix: " km/h"))
            ReportValue(title: "累计有效距离", value: reportNumber(point.cumulativeMeters, suffix: " m"))
            ReportValue(title: "状态 / 来源", value: point.state.rawValue + " / " + point.source.rawValue)
            ReportValue(title: "模型不确定度", value: reportNumber(point.uncertainty.map { $0 * 3.6 }, suffix: " km/h"))
            ReportValue(title: "定位年龄", value: reportNumber(point.observationAge, suffix: " s"))
            if let diag = point.diagnostics {
                ReportValue(title: "模型加速度", value: reportNumber(diag.state?[1], digits: 4, suffix: " m/s²"))
                ReportValue(title: "加速度计偏置", value: reportNumber(diag.state?[2], digits: 4, suffix: " m/s²"))
                ReportValue(title: "不确定度下限", value: reportNumber(diag.uncertaintyFloor.map { $0 * 3.6 }, suffix: " km/h"))
                ReportValue(title: "协方差速度标准差", value: reportNumber(diag.covarianceSpeedSigma.map { $0 * 3.6 }, suffix: " km/h"))
                ReportValue(title: "创新 / NIS", value: reportNumber(diag.innovation) + " / " + reportNumber(diag.nis))
                ReportValue(title: "最近输入结果", value: diag.lastResult?.rawValue ?? "—")
                if let covariance = diag.covariance {
                    Text("协方差 P\n" + covariance.map { $0.map { reportNumber($0, digits: 5) }.joined(separator: "  ") }.joined(separator: "\n"))
                        .font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            if let raw = point.rawSpeed {
                ReportValue(title: "最近定位速度", value: reportNumber(raw.speed >= 0 ? raw.speed * 3.6 : nil, suffix: " km/h"))
                ReportValue(title: "原始定位样本年龄", value: reportNumber(point.timestamp - raw.timestamp, digits: 3, suffix: " s"))
                ReportValue(title: "定位报告精度", value: reportNumber(raw.speedAccuracy >= 0 ? raw.speedAccuracy : nil, suffix: " m/s"))
                ReportValue(title: "水平精度", value: reportNumber(raw.horizontalAccuracy, suffix: " m"))
            }
            if let location = point.location {
                ReportValue(title: "经纬度", value: reportNumber(location.latitude, digits: 6) + ", " + reportNumber(location.longitude, digits: 6))
                ReportValue(title: "高度 / 航向", value: reportNumber(location.altitude, suffix: " m") + " / " + reportNumber(location.course >= 0 ? location.course : nil, suffix: "°"))
                ReportValue(title: "垂直 / 航向精度", value: reportNumber(location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil, suffix: " m") + " / " + reportNumber(location.courseAccuracy >= 0 ? location.courseAccuracy : nil, suffix: "°"))
            }
            if let motion = point.motion {
                ReportValue(title: "运动样本年龄", value: reportNumber(motion.timestamp.map { point.timestamp - $0 }, digits: 3, suffix: " s"))
                ReportValue(title: "去重力加速度 · g", value: vector(motion.acceleration))
                ReportValue(title: "重力 · g", value: vector(motion.gravity))
                ReportValue(title: "角速度 · rad/s", value: vector(motion.rotationRate))
                Text("姿态四元数 [x,y,z,w]\n" + vector(motion.quaternion)).font(.caption2.monospaced())
            }
            if let raw = point.accelerometer {
                ReportValue(title: "原始加速度 · g", value: vector(raw.values))
                ReportValue(title: "加速度计样本年龄", value: reportNumber(point.timestamp - raw.timestamp, digits: 3, suffix: " s"))
            }
            if let raw = point.gyroscope {
                ReportValue(title: "原始陀螺仪 · rad/s", value: vector(raw.values))
                ReportValue(title: "陀螺仪样本年龄", value: reportNumber(point.timestamp - raw.timestamp, digits: 3, suffix: " s"))
            }
            if let raw = point.magnetometer {
                ReportValue(title: "磁场 · µT", value: vector(raw.values))
                ReportValue(title: "磁力计样本年龄", value: reportNumber(point.timestamp - raw.timestamp, digits: 3, suffix: " s"))
            }
            ReportValue(title: "最近气压 / 相对高度", value: reportNumber(point.pressure, suffix: " kPa") + " / " + reportNumber(point.relativeAltitude, suffix: " m"))
            ReportValue(title: "电量 / 热状态", value: reportNumber(point.batteryLevel.flatMap { $0 >= 0 ? Double($0) * 100 : nil }, digits: 0, suffix: "%") + " / " + (point.thermalState.map(String.init) ?? "—"))
        }
    }

    private func vector(_ values: [Double]) -> String { values.map { reportNumber($0, digits: 4) }.joined(separator: ", ") }
    private func sensorName(_ key: String) -> String {
        ["location":"定位", "deviceMotion":"姿态与去重力运动", "accelerometer":"加速度计", "gyroscope":"陀螺仪", "magnetometer":"磁力计", "altimeter":"气压计"][key] ?? key
    }

    private func exportCSV(_ report: SessionReport) {
        exporting = true
        Task {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent + "-samples.csv")
                try await Task.detached(priority: .userInitiated) { try report.writeCSV(to: url) }.value
                csvURL = url
            } catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
}
