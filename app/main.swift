import Cocoa
import SwiftUI
import Combine
import IOKit
import UserNotifications

// MARK: - 系统调用

func sysctlSet(_ name: String, _ value: Int32) {
    var v = value
    sysctlbyname(name, nil, nil, &v, MemoryLayout<Int32>.size)
}
func sysctlGet(_ name: String) -> Int32 {
    var v: Int32 = -1
    var len = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &len, nil, 0)
    return v
}
func setModeValue(_ v: Int32) { sysctlSet("kern.fanprobe.mode", v) }
func setDutyValue(fan: UInt32, duty: UInt32) {
    sysctlSet("kern.fanprobe.duty", Int32((fan << 8) | (duty > 100 ? 100 : duty)))
}
func saveFanState(_ state: String) {
    try? state.write(toFile: "/Users/Shared/fanctl.state", atomically: true, encoding: .utf8)
}
func readEC(_ reg: Int32) -> Int32 {
    var v = reg
    sysctlbyname("kern.fanprobe.ecread", nil, nil, &v, MemoryLayout<Int32>.size)
    return sysctlGet("kern.fanprobe.lastval")
}
func smcRead(_ key: String) -> Double {
    let path = Bundle.main.resourcePath ?? "/Applications/FanCtl.app/Contents/Resources"
    let exe = path + "/smcread"
    guard FileManager.default.isExecutableFile(atPath: exe) else { return 0 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = [key]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let v = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 && v < 200 { return v }
    return 0
}
func gpuTemperature() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
    var result = 0.0
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let prop = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
           let dict = prop.takeRetainedValue() as? [String: Any],
           let t = dict["Temperature(C)"] as? Int {
            result = Double(t); IOObjectRelease(service); break
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    IOObjectRelease(iterator)
    return result
}

func notifyHighTemp(_ temp: Double) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "FanCtl · 温度过高"
        content.body = String(format: "CPU 当前 %.0f°C，风扇已自动提速", temp)
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - 主题

let accentChoices: [(String, Color)] = [
    ("blue", .blue), ("green", .green), ("orange", .orange),
    ("pink", .pink), ("purple", .purple), ("red", .red),
    ("graphite", Color(white: 0.5))
]
let appearanceChoices = [("system", "自动", "Auto"), ("dark", "深色", "Dark"), ("light", "浅色", "Light")]
let defaultCustomCurve: [(Double, Double)] = [(45, 20), (55, 30), (65, 45), (75, 65), (85, 85), (92, 100)]
let curves: [String: [(Double, Double)]] = [
    "silent":      [(50, 20), (60, 30), (70, 45), (80, 60), (90, 85)],
    "balanced":    [(45, 20), (55, 30), (65, 45), (75, 65), (85, 85), (92, 100)],
    "performance": [(45, 55), (55, 70), (65, 85), (75, 95), (85, 100)]
]
func dutyForTemp(_ t: Double, preset: String, custom: [(Double, Double)]? = nil) -> UInt32 {
    let c: [(Double, Double)]
    if preset == "custom" { c = custom ?? defaultCustomCurve }
    else { c = curves[preset] ?? curves["balanced"]! }
    if t <= c[0].0 { return UInt32(c[0].1) }
    if t >= c[c.count-1].0 { return UInt32(c[c.count-1].1) }
    for i in 0..<(c.count - 1) {
        let (t0, d0) = c[i], (t1, d1) = c[i+1]
        if t >= t0 && t <= t1 { return UInt32(d0 + (d1 - d0) * ((t - t0) / (t1 - t0))) }
    }
    return 50
}

// MARK: - 模型

final class FanModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var gpu: Double = 0
    @Published var fan1: Int = 0
    @Published var fan2: Int = 0
    @Published var duty: Int = 45
    @Published var curveOn: Bool = true
    @Published var fullSpeed: Bool = false
    @Published var preset: String = "balanced"
    @Published var lastMsg: String = ""
    @Published var manualMode: String = "曲线 · 平衡"
    @Published var appearance: String = UserDefaults.standard.string(forKey: "fanctl.appearance") ?? "system"
    @Published var accentName: String = UserDefaults.standard.string(forKey: "fanctl.accent") ?? "blue"
    @Published var cpuHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var fan1Duty: Int = 50
    @Published var fan2Duty: Int = 50
    @Published var customPoints: [(Double, Double)] = defaultCustomCurve
    @Published var showCurveEditor = false
    @Published var showSettings = false
    @Published var lang: String = UserDefaults.standard.string(forKey: "fanctl.lang") ?? "zh"
    @Published var fan1Preset: String = "balanced"
    @Published var fan2Preset: String = "balanced"
    @Published var curveTarget: Int = 0

    func tr(_ zh: String, _ en: String) -> String { lang == "en" ? en : zh }
    func setLang(_ v: String) { lang = v; UserDefaults.standard.set(v, forKey: "fanctl.lang") }

    private var lastNotify = Date.distantPast
    private var lastCurveDuty1: UInt32 = 0
    private var lastCurveDuty2: UInt32 = 0
    private var preFullSpeedCurveOn = true
    private var preFullSpeedFan1 = 50
    private var preFullSpeedFan2 = 50

    var accentColor: Color { accentChoices.first(where: { $0.0 == accentName })?.1 ?? .blue }
    private var timer: Timer?
    private var lastAppliedDuty: UInt32 = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "fanctl.customCurve"),
           let arr = try? JSONDecoder().decode([[Double]].self, from: data), arr.count >= 2 {
            customPoints = arr.map { ($0[0], $0[1]) }
        }
        if sysctlGet("kern.fanprobe.lastmode") == 171 {
            fullSpeed = true
            curveOn = false
            fan1Duty = 100; fan2Duty = 100; duty = 100
            manualMode = "G-Mode"
        }
        applyAppearance()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func refresh() {
        let t = (smcRead("TC0P"), 0.0)
        let g = gpuTemperature()
        let f1 = readEC(0x57), f2 = readEC(0x59)
        DispatchQueue.main.async {
            self.cpu = t.0; self.gpu = g
            self.fan1 = Int(f1); self.fan2 = Int(f2)
            if self.cpuHistory.isEmpty {
                self.cpuHistory = Array(repeating: t.0, count: 150)
                self.gpuHistory = Array(repeating: g, count: 150)
            }
            self.cpuHistory.append(t.0); if self.cpuHistory.count > 300 { self.cpuHistory.removeFirst() }
            self.gpuHistory.append(g); if self.gpuHistory.count > 300 { self.gpuHistory.removeFirst() }
            if self.curveOn {
                let d1 = dutyForTemp(t.0, preset: self.fan1Preset, custom: self.customPoints)
                let d2 = dutyForTemp(t.0, preset: self.fan2Preset, custom: self.customPoints)
                if abs(Int(d1) - Int(self.lastCurveDuty1)) >= 3 {
                    setDutyValue(fan: 0x32, duty: d1); self.lastCurveDuty1 = d1
                }
                if abs(Int(d2) - Int(self.lastCurveDuty2)) >= 3 {
                    setDutyValue(fan: 0x33, duty: d2); self.lastCurveDuty2 = d2
                }
                self.fan1Duty = Int(d1); self.fan2Duty = Int(d2)
                self.duty = Int(max(d1, d2))
                self.manualMode = "曲线 · " + self.presetName(self.preset)
            }
            if t.0 >= 92 && Date().timeIntervalSince(self.lastNotify) > 300 {
                self.lastNotify = Date()
                notifyHighTemp(t.0)
            }
        }
    }

    func presetName(_ key: String) -> String {
        switch key {
        case "silent": return tr("安静", "Silent")
        case "performance": return tr("性能", "Performance")
        case "custom": return tr("自定义", "Custom")
        default: return tr("平衡", "Balanced")
        }
    }
    func applyMode(_ name: String, _ v: Int32) {
        if v == 171 && !fullSpeed {
            preFullSpeedCurveOn = curveOn
            preFullSpeedFan1 = fan1Duty
            preFullSpeedFan2 = fan2Duty
        }
        setModeValue(v); saveFanState("mode=\(v)")
        curveOn = false; manualMode = name
        fullSpeed = (v == 171)
        if fullSpeed { fan1Duty = 100; fan2Duty = 100; duty = 100 }
        lastMsg = "已切换：\(name)（返回码 \(sysctlGet("kern.fanprobe.lastret"))）"
    }

    /// Leave G-Mode before a curve/manual action. G-Mode keeps the EC at
    /// 100%, so writing a duty without this would be ignored by the firmware.
    private func exitFullSpeed() {
        guard fullSpeed else { return }
        fullSpeed = false
        setModeValue(160)
    }

    func setFullSpeed(_ on: Bool) {
        guard on != fullSpeed else { return }
        if on {
            preFullSpeedCurveOn = curveOn
            preFullSpeedFan1 = fan1Duty
            preFullSpeedFan2 = fan2Duty
            fullSpeed = true
            curveOn = false
            setModeValue(171)
            saveFanState("mode=171")
            fan1Duty = 100; fan2Duty = 100; duty = 100
            manualMode = "G-Mode"
            lastMsg = tr("风扇全速模式", "Full speed mode")
        } else {
            fullSpeed = false
            setModeValue(160)
            saveFanState("mode=160")
            if preFullSpeedCurveOn {
                curveOn = true
                lastCurveDuty1 = 0; lastCurveDuty2 = 0
                refresh()
            } else {
                curveOn = false
                fan1Duty = preFullSpeedFan1; fan2Duty = preFullSpeedFan2
                setDutyValue(fan: 0x32, duty: UInt32(fan1Duty))
                setDutyValue(fan: 0x33, duty: UInt32(fan2Duty))
                saveFanState("duty1=\(fan1Duty);duty2=\(fan2Duty)")
                manualMode = "手动 \(fan1Duty)% / \(fan2Duty)%"
            }
        }
    }

    func applyDuty(fan: Int, _ d: Int) {
        let v = min(max(d, 0), 100)
        exitFullSpeed()
        curveOn = false
        if fan == 1 { fan1Duty = v } else { fan2Duty = v }
        setDutyValue(fan: fan == 1 ? 0x32 : 0x33, duty: UInt32(v))
        saveFanState("duty1=\(fan1Duty);duty2=\(fan2Duty)")
        manualMode = "手动 \(fan1Duty)% / \(fan2Duty)%"
        lastMsg = "手动：风扇1 \(fan1Duty)% · 风扇2 \(fan2Duty)%"
    }

    func saveCustomCurve() {
        exitFullSpeed()
        let arr = customPoints.map { [$0.0, $0.1] }
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: "fanctl.customCurve")
        }
        preset = "custom"; curveOn = true; saveFanState("mode=160")
        if curveTarget == 1 { fan1Preset = "custom" } else if curveTarget == 2 { fan2Preset = "custom" } else { fan1Preset = "custom"; fan2Preset = "custom" }
        lastCurveDuty1 = 0; lastCurveDuty2 = 0; refresh()
    }
    func setCurve(_ on: Bool) {
        exitFullSpeed()
        curveOn = on
        if on { setModeValue(160); saveFanState("mode=160"); lastAppliedDuty = 0; refresh() }
        else { setModeValue(160); saveFanState("mode=160"); manualMode = "自动" }
    }
    func setPreset(_ key: String) {
        exitFullSpeed()
        preset = key; curveOn = true; saveFanState("mode=160")
        switch curveTarget {
        case 1: fan1Preset = key
        case 2: fan2Preset = key
        default: fan1Preset = key; fan2Preset = key
        }
        lastCurveDuty1 = 0; lastCurveDuty2 = 0
        lastMsg = tr("曲线预设：", "Curve preset: ") + presetName(key)
        refresh()
    }
    func setAppearance(_ v: String) {
        appearance = v; UserDefaults.standard.set(v, forKey: "fanctl.appearance"); applyAppearance()
    }
    func applyAppearance() {
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
    func setAccent(_ v: String) {
        accentName = v; UserDefaults.standard.set(v, forKey: "fanctl.accent")
    }
}

// MARK: - 组件

struct SpeedBadge: View {
    let rpm: Int
    var body: some View {
        let (text, color): (String, Color) = rpm < 2800 ? ("低速", .green) : (rpm < 4300 ? ("中速", .yellow) : ("高速", .orange))
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct FanColumn: View {
    let title: String
    let rpm: Int
    let maxRPM: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "fanblades").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                SpeedBadge(rpm: rpm)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(rpm)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("RPM").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * min(Double(rpm) / maxRPM, 1.0))
                }
            }.frame(height: 4)
            HStack {
                Text("\(Int(maxRPM)) 最大").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}

struct PillButton: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.accentColor : Color.white.opacity(0.08)))
                .foregroundStyle(active ? .white : .primary)
        }.buttonStyle(.plain)
    }
}

struct TempChart: View {
    let cpu: [Double]
    let gpu: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach([20.0, 40.0, 60.0, 80.0], id: \.self) { t in
                    let y = h - CGFloat((t - 20) / 70) * h
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    Text("\(Int(t))°").font(.system(size: 8)).foregroundStyle(.tertiary)
                        .position(x: w - 14, y: y - 6)
                }
                line(cpu, color: .blue, w: w, h: h)
                line(gpu, color: .purple, w: w, h: h)
            }
        }.frame(height: 120)
    }
    func line(_ data: [Double], color: Color, w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            guard data.count > 1 else { return }
            for (i, t) in data.enumerated() {
                let x = w * CGFloat(i) / CGFloat(max(data.count - 1, 1))
                let y = h - CGFloat(min(max((t - 20) / 70, 0), 1)) * h
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }.stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }
}

struct CurveEditor: View {
    @ObservedObject var model: FanModel
    @Binding var points: [(Double, Double)]
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragIdx: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.tr("自定义风扇曲线", "Custom Fan Curve")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(model.tr("恢复默认", "Reset")) { points = defaultCustomCurve }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    ForEach([20.0, 40.0, 60.0, 80.0], id: \.self) { t in
                        let y = h - CGFloat(t / 100) * h
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        Text("\(Int(t))%").font(.system(size: 8)).foregroundStyle(.tertiary)
                            .position(x: w - 16, y: y - 6)
                    }
                    Path { p in
                        let sorted = points.sorted { $0.0 < $1.0 }
                        for (i, pt) in sorted.enumerated() {
                            let x = CGFloat(pt.0 / 100) * w
                            let y = h - CGFloat(pt.1 / 100) * h
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    ForEach(points.indices, id: \.self) { i in
                        Circle().fill(Color.accentColor)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                            .position(x: CGFloat(points[i].0 / 100) * w, y: h - CGFloat(points[i].1 / 100) * h)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let x = Double(v.location.x / w) * 100
                    let y = (1 - Double(v.location.y / h)) * 100
                    if dragIdx == nil {
                        var best = 0; var bestD = Double.infinity
                        for i in points.indices {
                            let dx = points[i].0 - x, dy = points[i].1 - y
                            let d = dx * dx + dy * dy
                            if d < bestD { bestD = d; best = i }
                        }
                        dragIdx = best
                    }
                    if let i = dragIdx {
                        var t = min(max(x, 25), 100)
                        var d = min(max(y, 0), 100)
                        let sorted = points.sorted { $0.0 < $1.0 }
                        if let idx = sorted.firstIndex(where: { abs($0.0 - points[i].0) < 0.001 }) {
                            if idx > 0 { t = max(t, sorted[idx-1].0 + 2) }
                            if idx < sorted.count - 1 { t = min(t, sorted[idx+1].0 - 2) }
                        }
                        points[i] = (t, d)
                    }
                }.onEnded { _ in dragIdx = nil })
            }
            .frame(height: 230)
            Text(model.tr("拖动圆点调整：横轴温度，纵轴占空比", "Drag the dots: X = temperature, Y = duty")).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(model.tr("取消", "Cancel")) { dismiss() }
                Button(model.tr("保存并启用", "Save & Enable")) { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }
}

struct SettingsView: View {
    @ObservedObject var model: FanModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.tr("设置", "Settings")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(model.tr("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(model.tr("外观", "Appearance")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(appearanceChoices, id: \.0) { a in
                    PillButton(title: model.tr(a.1, a.2), active: model.appearance == a.0) { model.setAppearance(a.0) }
                }
            }
            Text(model.tr("强调色", "Accent color")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(accentChoices, id: \.0) { c in
                    Circle().fill(c.1).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.primary.opacity(model.accentName == c.0 ? 0.9 : 0), lineWidth: 2))
                        .onTapGesture { model.setAccent(c.0) }
                }
            }
            Text(model.tr("语言", "Language")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                PillButton(title: "中文", active: model.lang == "zh") { model.setLang("zh") }
                PillButton(title: "English", active: model.lang == "en") { model.setLang("en") }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 300)
    }
}

// MARK: - 菜单栏悬浮窗

struct MenuBarPanel: View {
    @ObservedObject var model: FanModel
    var openPanel: () -> Void

    private func temp(_ v: Double) -> String {
        v > 0 ? String(format: "%.0f°", v) : "--"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(model.accentColor)
                Text("FanCtl")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openPanel) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(model.tr("打开控制面板", "Open control panel"))
            }

            HStack(spacing: 8) {
                PanelMetric(title: "CPU", value: temp(model.cpu), color: .blue)
                PanelMetric(title: "GPU", value: temp(model.gpu), color: .purple)
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                PanelFan(title: model.tr("风扇 1", "Fan 1"), rpm: model.fan1)
                PanelFan(title: model.tr("风扇 2", "Fan 2"), rpm: model.fan2)
            }

            Divider().opacity(0.35)

            Toggle(isOn: Binding(
                get: { model.fullSpeed },
                set: { model.setFullSpeed($0) }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "wind")
                    Text(model.tr("风扇全速模式", "Full speed mode"))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(model.fullSpeed
                 ? model.tr("G-Mode · 双风扇 100%", "G-Mode · both fans 100%")
                 : model.tr("关闭后恢复之前的控制方式", "Off restores the previous control"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(14)
        .frame(width: 280, height: 250, alignment: .top)
        .tint(model.accentColor)
    }
}

struct PanelMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
    }
}

struct PanelFan: View {
    let title: String
    let rpm: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(rpm)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var model: FanModel
    let modes = [("自动", Int32(160)), ("性能", Int32(161)), ("冷静", Int32(162)), ("安静", Int32(163)), ("G-Mode", Int32(171))]
    let presets = ["silent", "balanced", "performance"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // header
            HStack(spacing: 10) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FanCtl").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text(model.tr("风扇正常 · Dell G15 · macOS 26", "Fans normal · Dell G15 · macOS 26")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.manualMode).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                Button(action: { model.showSettings = true }) {
                    Image(systemName: "gearshape").font(.system(size: 13))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            // fans
            HStack(alignment: .top, spacing: 22) {
                FanColumn(title: model.tr("风扇 1", "Fan 1"), rpm: model.fan1, maxRPM: 5200)
                FanColumn(title: model.tr("风扇 2", "Fan 2"), rpm: model.fan2, maxRPM: 5200)
            }

            // mode bar
            HStack(spacing: 6) {
                ForEach(modes, id: \.0) { m in
                    PillButton(title: m.0, active: !model.curveOn && model.manualMode == m.0) { model.applyMode(m.0, m.1) }
                }
            }

            // manual duty (per fan)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.tr("手动占空比", "Manual duty")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.fan1Duty)% / \(model.fan2Duty)%").font(.system(size: 11, weight: .medium))
                }
                HStack(spacing: 8) {
                    Text(model.tr("风扇1", "Fan 1")).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.fan1Duty) },
                                          set: { model.applyDuty(fan: 1, Int($0)) }), in: 0...100, step: 5)
                        .controlSize(.mini)
                }
                HStack(spacing: 8) {
                    Text(model.tr("风扇2", "Fan 2")).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.fan2Duty) },
                                          set: { model.applyDuty(fan: 2, Int($0)) }), in: 0...100, step: 5)
                        .controlSize(.mini)
                }
            }

            Divider().opacity(0.15)

            // temps
            HStack(alignment: .top, spacing: 20) {
                tempBlock("CPU", model.cpu, .blue)
                tempBlock("GPU", model.gpu, .purple)
            }

            // chart
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.tr("温度", "Temperature")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(model.tr("最近 10 分钟", "Last 10 min")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                TempChart(cpu: model.cpuHistory, gpu: model.gpuHistory)
                HStack(spacing: 12) {
                    legend("CPU", .blue); legend("GPU", .purple)
                    Spacer()
                }
            }

            // compact curve target
            HStack(spacing: 6) {
                Text(model.tr("应用到", "Apply to")).font(.system(size: 10)).foregroundStyle(.tertiary)
                ForEach([(0, "两个", "Both"), (1, "风扇1", "Fan 1"), (2, "风扇2", "Fan 2")], id: \.0) { t in
                    Button(action: { model.curveTarget = t.0 }) {
                        Text(model.tr(t.1, t.2)).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(model.curveTarget == t.0 ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06)))
                            .foregroundStyle(model.curveTarget == t.0 ? .white : .secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }

            // curve presets
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    PillButton(title: model.presetName(p), active: model.curveOn && model.preset == p) { model.setPreset(p) }
                }
                PillButton(title: model.tr("自定义…", "Custom…"), active: model.curveOn && model.preset == "custom") { model.showCurveEditor = true }
            }

            Spacer(minLength: 0)

            // footer
            HStack {
                Button(model.tr("活动监视器", "Activity Monitor")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(model.tr("退出", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showCurveEditor) {
            CurveEditor(model: model, points: $model.customPoints, onSave: { model.saveCustomCurve() })
        }
        .padding(18)
        .padding(.top, 10)
        .frame(width: 460, height: 740)
        .tint(model.accentColor)
    }

    func tempBlock(_ name: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", value)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("°C").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(color).frame(width: geo.size.width * min(value / 100, 1))
                }
            }.frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var menu: NSMenu!
    var popover: NSPopover!
    var model = FanModel()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = statusImage(temp: "--", rpm1: nil, rpm2: nil)

        menu = NSMenu()
        let openItem = NSMenuItem(title: model.tr("打开控制面板…", "Open Control Panel…"), action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        let rpmItem = NSMenuItem(title: model.tr("菜单栏显示转速", "Show RPM in Menu Bar"), action: #selector(toggleMenuRPM), keyEquivalent: "")
        rpmItem.target = self
        rpmItem.state = UserDefaults.standard.bool(forKey: "fanctl.menuRPM") ? .on : .off
        menu.addItem(rpmItem)
        let quitItem = NSMenuItem(title: model.tr("退出 FanCtl", "Quit FanCtl"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let button = self.statusItem.button, event.window == button.window else {
                return event
            }
            if event.type == .rightMouseDown {
                self.showStatusMenu()
            } else {
                self.togglePopover()
            }
            return nil
        }

        makePopover()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateTitle() }
        RunLoop.current.add(timer!, forMode: .common)
        updateTitle()
        showWindow()
    }

    func showStatusMenu() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func makePopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let panel = MenuBarPanel(model: model) { [weak self] in
            self?.popover.performClose(nil)
            self?.showWindow()
        }
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: 280, height: 250)
    }

    func togglePopover() {
        guard let popover = popover, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc func toggleMenuRPM(_ sender: NSMenuItem) {
        let on = !UserDefaults.standard.bool(forKey: "fanctl.menuRPM")
        UserDefaults.standard.set(on, forKey: "fanctl.menuRPM")
        sender.state = on ? .on : .off
        updateTitle()
    }

    func compactRPM(_ v: Int32) -> String {
        let r = Int(v)
        if r >= 1000 { return String(format: "%.1fk", Double(r) / 1000.0) }
        return "\(r)"
    }

    func statusImage(temp: String, rpm1: String?, rpm2: String?) -> NSImage {
        let fontT = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let fontR = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let attrsT: [NSAttributedString.Key: Any] = [.font: fontT, .foregroundColor: NSColor.black]
        let attrsR: [NSAttributedString.Key: Any] = [.font: fontR, .foregroundColor: NSColor.black]
        let tSize = (temp as NSString).size(withAttributes: attrsT)
        let r1Size = rpm1.map { ($0 as NSString).size(withAttributes: attrsR) } ?? .zero
        let r2Size = rpm2.map { ($0 as NSString).size(withAttributes: attrsR) } ?? .zero
        let rWidth = max(r1Size.width, r2Size.width)
        let width = 17 + 3 + tSize.width + (rpm1 != nil ? 5 + rWidth : 0)
        let height: CGFloat = 18
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        if let sym = NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil) {
            let s = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? sym
            s.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
        }
        (temp as NSString).draw(at: NSPoint(x: 19, y: (height - tSize.height) / 2), withAttributes: attrsT)
        if let r1 = rpm1, let r2 = rpm2 {
            let x = 19 + tSize.width + 5
            (r1 as NSString).draw(at: NSPoint(x: x, y: height / 2 + 0.5), withAttributes: attrsR)
            (r2 as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: attrsR)
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func updateTitle() {
        let temp = String(format: "%.0f°", model.cpu)
        if UserDefaults.standard.bool(forKey: "fanctl.menuRPM") {
            let f1 = readEC(0x57), f2 = readEC(0x59)
            statusItem.button?.image = statusImage(temp: temp, rpm1: compactRPM(f1), rpm2: compactRPM(f2))
        } else {
            statusItem.button?.image = statusImage(temp: temp, rpm1: nil, rpm2: nil)
        }
        statusItem.button?.contentTintColor = model.cpu >= 90 ? .systemRed : nil
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "FanCtl 风扇控制"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isMovableByWindowBackground = true

            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.isEmphasized = true

            let tint = NSView(frame: effect.bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
            effect.addSubview(tint)

            let hosting = NSHostingView(rootView: ContentView(model: model))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            w.contentView = effect
            window = w
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
