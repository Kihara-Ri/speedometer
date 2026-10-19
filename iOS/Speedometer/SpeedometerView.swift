import SwiftUI
#if canImport(SpeedCore)
import SpeedCore
#endif

// MARK: - Palette

enum Palette {
    static let top = Color(red: 0.043, green: 0.059, blue: 0.082)
    static let bottom = Color(red: 0.075, green: 0.098, blue: 0.137)
    static let card = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.09)
    static let measured = Color(red: 0.25, green: 0.86, blue: 0.66)
    static let predicted = Color(red: 1.0, green: 0.74, blue: 0.22)
    static let idle = Color(white: 0.45)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)
}

// MARK: - Root

struct SpeedometerView: View {
    @Bindable var model: SpeedometerModel
    @AppStorage("speedUnit") private var unitRaw = SpeedUnit.kmh.rawValue
    @Environment(\.openURL) private var openURL
    @State private var showingRecording = false
    @State private var reviewURL: URL?

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .kmh }
    private var speed: Double? { model.estimate?.speed }
    private var state: EstimateState { model.estimate?.state ?? .unavailable }

    private var tint: Color {
        guard model.status == .running else { return Palette.idle }
        if model.estimate?.source == .stationary { return Palette.measured }
        switch state { case .measured: return Palette.measured; case .predicted: return Palette.predicted; case .unavailable: return Palette.idle }
    }

    private var badge: (text: String, color: Color) {
        switch model.status {
        case .stopped: return ("已停止", Palette.idle)
        case .waitingForPermission: return ("等待授权", Palette.predicted)
        case .suspended: return ("已暂停", Palette.idle)
        case .denied, .preciseLocationRequired, .recordingFailed: return ("无法测速", Palette.danger)
        case .running:
            if model.estimate?.source == .stationary { return ("静止", Palette.measured) }
            switch state {
            case .measured: return ("实测", Palette.measured)
            case .predicted: return ("推算中", Palette.predicted)
            case .unavailable: return ("等待速度…", Palette.idle)
            }
        }
    }

    private var scale: (max: Double, step: Double) {
        let scales = unit.scales
        let value = unit.convert(max(model.peakSpeed, speed ?? 0))
        return scales.first { $0.max >= value } ?? scales[scales.count - 1]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                header
                // The dial absorbs all spare height, so the screen never grows past the viewport.
                DialView(value: speed.map(unit.convert) ?? 0,
                         hasValue: speed != nil && model.status == .running,
                         text: unit.format(model.status == .running ? speed : nil),
                         unit: unit.label, scale: scale, tint: tint)
                    .frame(maxWidth: 300, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                unitPicker
                recordingStatus
                stats
                // Notice and details share one fixed-height slot: swapping never moves the layout.
                Group {
                    if let notice { NoticeCard(notice: notice, openSettings: openSettings) } else { details }
                }
                .frame(height: 84)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if model.isRecording, model.status == .running, let candidate = model.rail?.current {
                RailArrivalCard(candidate: candidate, respond: model.respondToArrival)
                    .padding(.horizontal, 16)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.rail?.current?.id)
        .animation(.easeOut(duration: 0.25), value: model.status)
        .sheet(isPresented: $showingRecording) { RecordingView(model: model, initialRecordingURL: reviewURL) }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("测速计").font(.title3.weight(.semibold))
            Spacer()
            Button { reviewURL = nil; showingRecording = true } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.bordered)
            HStack(spacing: 6) {
                Circle().fill(badge.color).frame(width: 8, height: 8)
                Text(badge.text).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(badge.color.opacity(0.15), in: Capsule())
            .foregroundStyle(badge.color)
            .accessibilityElement(children: .combine)
        }
    }

    private var unitPicker: some View {
        Picker("单位", selection: $unitRaw) {
            ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(title: "最高速度", value: model.peakSpeed > 0 ? unit.format(model.peakSpeed) : "--", suffix: unit.label)
            StatTile(title: "平均速度", value: unit.format(model.averageSpeed), suffix: unit.label)
            StatTile(title: "里程", value: distanceText.value, suffix: distanceText.unit)
        }
    }

    private var details: some View {
        HStack(spacing: 0) {
            DetailItem(title: "数据来源", value: sourceText)
            Divider().frame(height: 28).overlay(Color.white.opacity(0.12))
            DetailItem(title: "模型不确定度", value: model.estimate?.uncertainty.map { String(format: "%.1f", unit.convert($0)) + " " + unit.label } ?? "--")
            Divider().frame(height: 28).overlay(Color.white.opacity(0.12))
            DetailItem(title: "数据延迟", value: model.estimate?.observationAge.map { String(format: "%.1f s", $0) } ?? "--")
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: model.toggle) {
                Label(model.isFinalizingRecording ? "正在保存…" : model.isRecording ? "停止并保存" : "开始测速并记录",
                      systemImage: model.isRecording ? "stop.fill" : "location.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? Palette.danger : Palette.measured)
            .foregroundStyle(Color.black)
            .disabled(model.isFinalizingRecording)
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    // MARK: Derived text

    private var recordingStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "record.circle.fill" : "checkmark.circle")
                    .foregroundStyle(model.isRecording ? Palette.danger : Palette.measured)
                if model.isFinalizingRecording {
                    Text("正在保存本次行程…")
                } else if model.isRecording {
                    Text((model.rail?.isRailLike == true ? "疑似轨道交通 · " : "记录中 · ") + reportTime(model.recordingDuration)).monospacedDigit()
                } else if model.recordingError != nil {
                    Text("记录未完整保存").foregroundStyle(Palette.danger)
                } else if let url = model.lastExport {
                    Text("本次已保存 · " + reportTime(model.recordingDuration)).monospacedDigit()
                    Spacer()
                    Button("查看本次") { reviewURL = url; showingRecording = true }
                } else {
                    Text("每次测速自动保存行程").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }

    private var distanceText: (value: String, unit: String) {
        let meters = model.distance
        if unit == .mph {
            let miles = meters / 1609.344
            return (miles < 0.1 ? "0.00" : String(format: "%.2f", miles), "mi")
        }
        return meters < 1000 ? (String(format: "%.0f", meters), "m") : (String(format: "%.2f", meters / 1000), "km")
    }

    private var sourceText: String {
        guard model.status == .running, let source = model.estimate?.source else { return "--" }
        switch source {
        case .location: return "GNSS 定位"
        case .model: return "模型推算"
        case .inertial: return "惯性辅助"
        case .stationary: return "静止判定"
        case .none: return "--"
        }
    }

    private var notice: Notice? {
        switch model.status {
        case .denied:
            Notice(icon: "location.slash.fill", title: "定位权限被拒绝",
                   message: "测速需要使用定位。请在系统设置中允许“测速计”访问位置。", action: "打开设置")
        case .preciseLocationRequired:
            Notice(icon: "location.circle", title: "需要“精确位置”",
                   message: "当前为大致位置，无法得到可靠速度。请在设置中开启精确位置。", action: "打开设置")
        case .recordingFailed:
            Notice(icon: "exclamationmark.triangle.fill", title: "记录失败，测速已停止",
                   message: model.recordingError ?? "无法保存采集数据，请检查剩余空间后重新开始。", action: nil)
        case .waitingForPermission:
            Notice(icon: "location.fill", title: "等待定位授权",
                   message: "请在系统弹窗中选择“使用App时允许”，并保持精确位置开启。", action: nil)
        case .running where state == .unavailable:
            Notice(icon: "location.circle", title: "等待速度或静止判定",
                   message: "正在确认运动状态。位置可用不代表速度已就绪。", action: nil)
        case .running where state == .predicted && model.estimate?.source != .stationary:
            Notice(icon: "waveform.path.ecg", title: "信号暂时中断",
                   message: "当前为模型推算值，数秒内无新定位将停止显示。", action: nil)
        default: nil
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

// MARK: - Dial

private struct DialView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double          // in display unit
    let hasValue: Bool
    let text: String
    let unit: String
    let scale: (max: Double, step: Double)
    let tint: Color

    private let sweep = 0.75   // 270°
    private let startAngle = 135.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = size * 0.065
            let radius = (size - line) / 2
            let fraction = min(max(value / scale.max, 0), 1)
            ZStack {
                Circle().trim(from: 0, to: sweep)
                    .stroke(Palette.track, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)
                Circle().trim(from: 0, to: sweep * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)
                    .shadow(color: tint.opacity(hasValue ? 0.55 : 0), radius: 12)
                    .opacity(hasValue || fraction > 0 ? 1 : 0)

                ticks(radius: radius, line: line, center: size / 2)

                VStack(spacing: 2) {
                    Text(hasValue ? text : "—")
                        .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .foregroundStyle(hasValue ? Color.white : Color.white.opacity(0.35))
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: size * 0.065, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, size * 0.2)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .animation(dialAnimation, value: fraction)
            .animation(dialAnimation, value: text)
            // Unit changes must animate even when no speed is available.
            .animation(dialAnimation, value: unit)
            .animation(dialAnimation, value: scale.max)
            .animation(dialAnimation, value: scale.step)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前速度")
        .accessibilityValue(hasValue ? "\(text) \(unit)" : "暂无")
    }

    private var dialAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.35)
    }

    private func ticks(radius: Double, line: Double, center: Double) -> some View {
        let minorPerMajor = 5
        let majors = Int((scale.max / scale.step).rounded())
        let total = majors * minorPerMajor
        let outer = radius - line * 1.1
        return ZStack {
            ForEach(0...total, id: \.self) { i in
                let isMajor = i % minorPerMajor == 0
                let angle = startAngle + 270 * Double(i) / Double(total)
                Capsule()
                    .fill(Color.white.opacity(isMajor ? 0.55 : 0.22))
                    .frame(width: isMajor ? 2 : 1, height: isMajor ? line * 0.7 : line * 0.35)
                    .offset(y: -(outer - (isMajor ? line * 0.35 : line * 0.175)))
                    .rotationEffect(.degrees(angle + 90))
            }
            ForEach(0...majors, id: \.self) { m in
                let angle = (startAngle + 270 * Double(m) / Double(majors)) * .pi / 180
                let r = outer - line * 1.25
                Text(String(format: "%.0f", Double(m) * scale.step))
                    .font(.system(size: line * 0.62, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(m) * scale.step))
                    .foregroundStyle(.secondary)
                    .position(x: center + r * cos(angle), y: center + r * sin(angle))
            }
        }
        .frame(width: center * 2, height: center * 2)
    }
}

// MARK: - Components

private struct StatTile: View {
    let title: String, value: String, suffix: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(suffix).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct DetailItem: View {
    let title: String, value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct Notice {
    let icon: String, title: String, message: String, action: String?
}

private struct NoticeCard: View {
    let notice: Notice
    let openSettings: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.icon).font(.title3).foregroundStyle(Palette.predicted).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.subheadline.weight(.semibold))
                Text(notice.message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action, action: openSettings).font(.footnote.weight(.semibold)).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
