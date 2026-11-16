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
let appearanceChoices = [("system", "自动"), ("dark", "深色"), ("light", "浅色")]
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

    private var lastNotify = Date.distantPast
    private var lastCurveDuty: UInt32 = 0

    var accentColor: Color { accentChoices.first(where: { $0.0 == accentName })?.1 ?? .blue }
    private var timer: Timer?
    private var lastAppliedDuty: UInt32 = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "fanctl.customCurve"),
           let arr = try? JSONDecoder().decode([[Double]].self, from: data), arr.count >= 2 {
            customPoints = arr.map { ($0[0], $0[1]) }
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
                let d = dutyForTemp(t.0, preset: self.preset, custom: self.customPoints)
                if abs(Int(d) - Int(self.lastCurveDuty)) >= 3 {
                    setDutyValue(fan: 0x32, duty: d)
                    setDutyValue(fan: 0x33, duty: d)
                    self.lastCurveDuty = d
                }
                self.duty = Int(d)
                self.fan1Duty = Int(d); self.fan2Duty = Int(d)
                self.manualMode = "曲线 · " + self.presetName(self.preset)
            }
            if t.0 >= 92 && Date().timeIntervalSince(self.lastNotify) > 300 {
                self.lastNotify = Date()
                notifyHighTemp(t.0)
            }
        }
    }

    func presetName(_ key: String) -> String {
        switch key { case "silent": return "安静"; case "performance": return "性能"; case "custom": return "自定义"; default: return "平衡" }
    }
    func applyMode(_ name: String, _ v: Int32) {
        setModeValue(v); saveFanState("mode=\(v)")
        curveOn = false; manualMode = name
        lastMsg = "已切换：\(name)（返回码 \(sysctlGet("kern.fanprobe.lastret"))）"
    }
    func applyDuty(fan: Int, _ d: Int) {
        let v = min(max(d, 0), 100)
        curveOn = false
        if fan == 1 { fan1Duty = v } else { fan2Duty = v }
        setDutyValue(fan: fan == 1 ? 0x32 : 0x33, duty: UInt32(v))
        saveFanState("duty1=\(fan1Duty);duty2=\(fan2Duty)")
        manualMode = "手动 \(fan1Duty)% / \(fan2Duty)%"
        lastMsg = "手动：风扇1 \(fan1Duty)% · 风扇2 \(fan2Duty)%"
    }

    func saveCustomCurve() {
        let arr = customPoints.map { [$0.0, $0.1] }
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: "fanctl.customCurve")
        }
        preset = "custom"; curveOn = true; saveFanState("mode=160")
        lastCurveDuty = 0; refresh()
    }
    func setCurve(_ on: Bool) {
        curveOn = on
        if on { saveFanState("mode=160"); lastAppliedDuty = 0; refresh() }
        else { setModeValue(160); saveFanState("mode=160"); manualMode = "自动" }
    }
    func setPreset(_ key: String) {
        preset = key; curveOn = true; saveFanState("mode=160")
        lastAppliedDuty = 0; lastMsg = "曲线预设：\(presetName(key))"; refresh()
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
    @Binding var points: [(Double, Double)]
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragIdx: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自定义风扇曲线").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("恢复默认") { points = defaultCustomCurve }
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
            Text("拖动圆点调整：横轴温度，纵轴占空比").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并启用") { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var model: FanModel
    let modes = [("自动", Int32(160)), ("性能", Int32(161)), ("冷静", Int32(162)), ("安静", Int32(163)), ("G-Mode", Int32(171))]
    let presets = [("silent", "安静"), ("balanced", "平衡"), ("performance", "性能")]

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
                        Text("风扇正常 · Dell G15 · macOS 26").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.manualMode).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }

            // fans
            HStack(alignment: .top, spacing: 22) {
                FanColumn(title: "风扇 1", rpm: model.fan1, maxRPM: 5200)
                FanColumn(title: "风扇 2", rpm: model.fan2, maxRPM: 5200)
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
                    Text("手动占空比").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.fan1Duty)% / \(model.fan2Duty)%").font(.system(size: 11, weight: .medium))
                }
                HStack(spacing: 8) {
                    Text("风扇1").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.fan1Duty) },
                                          set: { model.applyDuty(fan: 1, Int($0)) }), in: 0...100, step: 5)
                        .controlSize(.mini)
                }
                HStack(spacing: 8) {
                    Text("风扇2").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
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
                    Text("温度").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("最近 10 分钟").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                TempChart(cpu: model.cpuHistory, gpu: model.gpuHistory)
                HStack(spacing: 12) {
                    legend("CPU", .blue); legend("GPU", .purple)
                    Spacer()
                }
            }

            // curve presets
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { p in
                    PillButton(title: p.1, active: model.curveOn && model.preset == p.0) { model.setPreset(p.0) }
                }
                PillButton(title: "自定义…", active: model.curveOn && model.preset == "custom") { model.showCurveEditor = true }
            }

            // appearance (compact)
            HStack(spacing: 8) {
                ForEach(appearanceChoices, id: \.0) { a in
                    PillButton(title: a.1, active: model.appearance == a.0) { model.setAppearance(a.0) }
                }
                Spacer()
                ForEach(accentChoices.prefix(5), id: \.0) { c in
                    Circle().fill(c.1).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(model.accentName == c.0 ? 0.9 : 0), lineWidth: 1.5))
                        .onTapGesture { model.setAccent(c.0) }
                }
            }

            Spacer(minLength: 0)

            // footer
            HStack {
                Button("活动监视器") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $model.showCurveEditor) {
            CurveEditor(points: $model.customPoints, onSave: { model.saveCustomCurve() })
        }
        .padding(18)
        .padding(.top, 10)
        .frame(width: 460, height: 760)
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
    var model = FanModel()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🌡 --"
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开控制面板…", action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        let rpmItem = NSMenuItem(title: "菜单栏显示转速", action: #selector(toggleMenuRPM), keyEquivalent: "")
        rpmItem.target = self
        rpmItem.state = UserDefaults.standard.bool(forKey: "fanctl.menuRPM") ? .on : .off
        menu.addItem(rpmItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 FanCtl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateTitle() }
        RunLoop.current.add(timer!, forMode: .common)
        updateTitle()
        showWindow()
    }

    @objc func toggleMenuRPM(_ sender: NSMenuItem) {
        let on = !UserDefaults.standard.bool(forKey: "fanctl.menuRPM")
        UserDefaults.standard.set(on, forKey: "fanctl.menuRPM")
        sender.state = on ? .on : .off
        updateTitle()
    }

    func updateTitle() {
        if UserDefaults.standard.bool(forKey: "fanctl.menuRPM") {
            let f1 = readEC(0x57), f2 = readEC(0x59)
            statusItem.button?.title = String(format: "🌡 %.0f°C  %d/%d", model.cpu, f1, f2)
        } else {
            statusItem.button?.title = String(format: "🌡 %.0f°C", model.cpu)
        }
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
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
