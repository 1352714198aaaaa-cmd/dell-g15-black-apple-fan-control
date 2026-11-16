import Cocoa
import SwiftUI
import Combine
import IOKit

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

func saveFanState(_ state: String) {
    try? state.write(toFile: "/Users/Shared/fanctl.state", atomically: true, encoding: .utf8)
}
func setDutyValue(fan: UInt32, duty: UInt32) { sysctlSet("kern.fanprobe.duty", Int32((fan << 8) | (duty > 100 ? 100 : duty))) }
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
            result = Double(t)
            IOObjectRelease(service)
            break
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    IOObjectRelease(iterator)
    return result
}

func fanbarTemps() -> (Double, Double) {
    return (smcRead("TC0P"), smcRead("TH0x"))
}

// MARK: - 模型

let curves: [String: [(Double, Double)]] = [
    "silent":      [(50, 20), (60, 30), (70, 45), (80, 60), (90, 85)],
    "balanced":    [(45, 20), (55, 30), (65, 45), (75, 65), (85, 85), (92, 100)],
    "performance": [(45, 55), (55, 70), (65, 85), (75, 95), (85, 100)]
]
func dutyForTemp(_ t: Double, preset: String) -> UInt32 {
    let c = curves[preset] ?? curves["balanced"]!
    if t <= c[0].0 { return UInt32(c[0].1) }
    if t >= c[c.count-1].0 { return UInt32(c[c.count-1].1) }
    for i in 0..<(c.count - 1) {
        let (t0, d0) = c[i], (t1, d1) = c[i+1]
        if t >= t0 && t <= t1 {
            return UInt32(d0 + (d1 - d0) * ((t - t0) / (t1 - t0)))
        }
    }
    return 50
}

let accentChoices: [(String, Color)] = [
    ("blue", .blue), ("green", .green), ("orange", .orange),
    ("pink", .pink), ("purple", .purple), ("red", .red),
    ("graphite", Color(white: 0.5))
]
let appearanceChoices = [("system", "跟随系统"), ("dark", "深色"), ("light", "浅色")]

final class FanModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var gpu: Double = 0
    @Published var ssd: Double = 0
    @Published var fan1: Int = 0
    @Published var fan2: Int = 0
    @Published var duty: Int = 45
    @Published var curveOn: Bool = true
    @Published var preset: String = "balanced"
    @Published var lastMsg: String = ""
    @Published var manualMode: String = ""
    @Published var appearance: String = UserDefaults.standard.string(forKey: "fanctl.appearance") ?? "system"
    @Published var accentName: String = UserDefaults.standard.string(forKey: "fanctl.accent") ?? "blue"

    var accentColor: Color { accentChoices.first(where: { $0.0 == accentName })?.1 ?? .blue }

    private var timer: Timer?
    private var lastAppliedDuty: UInt32 = 0

    init() {
        applyAppearance()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func setAppearance(_ v: String) {
        appearance = v
        UserDefaults.standard.set(v, forKey: "fanctl.appearance")
        applyAppearance()
    }

    func applyAppearance() {
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func setAccent(_ v: String) {
        accentName = v
        UserDefaults.standard.set(v, forKey: "fanctl.accent")
    }

    func refresh() {
        let t = fanbarTemps()
        let f1 = readEC(0x57), f2 = readEC(0x59)
        DispatchQueue.main.async {
            self.cpu = t.0
            self.gpu = gpuTemperature()
            self.fan1 = Int(f1); self.fan2 = Int(f2)
            if self.curveOn {
                let d = dutyForTemp(t.0, preset: self.preset)
                if d != self.lastAppliedDuty {
                    setDutyValue(fan: 0x32, duty: d)
                    setDutyValue(fan: 0x33, duty: d)
                    self.lastAppliedDuty = d
                }
                self.duty = Int(d)
                self.manualMode = "曲线 · " + self.presetName(self.preset)
            }
        }
    }

    func presetName(_ key: String) -> String {
        switch key { case "silent": return "安静"; case "performance": return "性能"; default: return "平衡" }
    }

    func applyMode(_ name: String, _ v: Int32) {
        setModeValue(v)
        saveFanState("mode=\(v)")
        curveOn = false
        manualMode = name
        lastMsg = "已切换：\(name)（返回码 \(sysctlGet("kern.fanprobe.lastret"))）"
    }

    func applyDuty(_ d: Int) {
        let v = min(max(d, 0), 100)
        duty = v
        curveOn = false
        manualMode = "手动 \(v)%"
        setDutyValue(fan: 0x32, duty: UInt32(v))
        setDutyValue(fan: 0x33, duty: UInt32(v))
        saveFanState("duty=both:\(v)")
        lastMsg = "手动占空比 \(v)%"
    }

    func setCurve(_ on: Bool) {
        curveOn = on
        if on { saveFanState("mode=160"); lastAppliedDuty = 0; refresh() }
        else { setModeValue(160); saveFanState("mode=160"); manualMode = "自动" }
    }

    func setPreset(_ key: String) {
        preset = key
        curveOn = true
        saveFanState("mode=160")
        lastAppliedDuty = 0
        lastMsg = "曲线预设：\(presetName(key))"
        refresh()
    }
}

// MARK: - 界面

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 11)); Text(title).font(.system(size: 11)) }
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct ModeButton: View {
    let title: String
    let active: Bool
    let accent: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(active ? accent : Color(nsColor: .controlBackgroundColor)))
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @ObservedObject var model: FanModel
    let presets = [("silent", "安静"), ("balanced", "平衡"), ("performance", "性能")]
    let modes = [("自动", Int32(160)), ("性能", Int32(161)), ("冷静", Int32(162)), ("安静", Int32(163)), ("G-Mode", Int32(171))]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "fanblades.fill").font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FanCtl").font(.system(size: 18, weight: .bold))
                    Text("Dell G15 · macOS 26").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.manualMode).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatCard(icon: "thermometer.medium", title: "CPU 温度", value: String(format: "%.0f", model.cpu), unit: "°C")
                    StatCard(icon: "cpu", title: "GPU 温度", value: String(format: "%.0f", model.gpu), unit: "°C")
                }
                HStack(spacing: 10) {
                    StatCard(icon: "fanblades", title: "风扇 1", value: "\(model.fan1)", unit: "RPM")
                    StatCard(icon: "fanblades", title: "风扇 2", value: "\(model.fan2)", unit: "RPM")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("模式").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(modes, id: \.0) { m in
                        ModeButton(title: m.0, active: false, accent: model.accentColor) { model.applyMode(m.0, m.1) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("手动占空比").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.duty)%").font(.system(size: 12, weight: .medium))
                }
                Slider(value: Binding(get: { Double(model.duty) }, set: { model.applyDuty(Int($0)) }), in: 0...100, step: 5)
                    .tint(.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("风扇曲线").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.curveOn }, set: { model.setCurve($0) })).toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { p in
                        ModeButton(title: p.1, active: model.curveOn && model.preset == p.0, accent: model.accentColor) { model.setPreset(p.0) }
                    }
                }
                Text("曲线：45°C→20% · 55→30 · 65→45 · 75→65 · 85→85 · 92→100（平衡）")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("外观").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(appearanceChoices, id: \.0) { a in
                        ModeButton(title: a.1, active: model.appearance == a.0, accent: model.accentColor) { model.setAppearance(a.0) }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(accentChoices, id: \.0) { c in
                        Circle().fill(c.1).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(model.accentName == c.0 ? 0.9 : 0), lineWidth: 2))
                            .onTapGesture { model.setAccent(c.0) }
                    }
                }
            }

            if !model.lastMsg.isEmpty {
                Text(model.lastMsg).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .tint(model.accentColor)
        .frame(width: 480, height: 620)
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
        let quit = NSMenuItem(title: "退出 FanCtl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "FanCtl 风扇控制"
            w.contentView = NSHostingView(rootView: ContentView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
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
