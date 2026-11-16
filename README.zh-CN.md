# G15 FanCtl — 戴尔 G15 macOS 风扇控制

在 **Dell G15（5511 / i7-11800H + RTX 3060 Laptop）** 上运行 macOS 26（Tahoe），
通过 BIOS 暴露的 AWCC ACPI WMI 接口控制风扇。

![FanCtl](docs/screenshot.png)

> ⚠️ **仅在 Dell G15 5511 上实测。** 其他机型可能不同。写 EC 寄存器有风险，使用后果自负。
> 与 Dell、Apple 无关。

## 功能

- 热模式：平衡 / 性能 / 冷静 / 安静 / G-Mode
- 单风扇占空比（0–100%）
- 风扇转速读取（EC `0x57` / `0x59`）
- GPU 温度（`IOAccelerator` → `PerformanceStatistics`）
- 风扇曲线预设（安静 / 平衡 / 性能）
- `fanctl diag` 一键自检
- 开机恢复上次模式/占空比
- 菜单栏可选显示转速
- App 图标
- SwiftUI 控制面板 + 菜单栏 App，登录自启
- 双风扇大数字 RPM、CPU/GPU 实时温度曲线、手动占空比滑块
- 外观主题：跟随系统 / 深色 / 浅色 + 强调色
- 命令行：`fanctl mode|duty|rpm|status`

## 文档

- [架构说明](docs/ARCHITECTURE.md)：分层、ACPI/kext 接口、sysctl ABI、数据流、构建与发布流程。
- [EC 寄存器表](docs/EC-REGISTERS.md)：寄存器地址、实测值，以及验证这些结论的实验。

## 原理

BIOS 在 ACPI 里暴露了一个 `AMWW` 设备（`_UID = "AWCC"`），带有 WMI 调度方法 `WMAX`：

```
WMAX(0, 0x15, {1, mode, 0})        → AX23 → AX26 → 写 EC 0x22 + 风扇占空比到 EC 0x21/0x23
WMAX(0, 0x15, {2, fanId, duty})    → AX24 → EC 0x21（风扇 0x32）/ 0x23（风扇 0x33）
WMAX(0, 0x25, {2, 0, 0})           → AX28 → 读 EC 0x50
```

热模式值：`0xA0` 平衡、`0xA1` 性能、`0xA2` 冷静、`0xA3` 安静、
`0xAB` G-Mode（双风扇 100%）、`0` 自定义。

风扇转速：EC `0x57`（风扇 1）、`0x59`（风扇 2）。在实测固件上，这两个地址返回 16 位 RPM
值，也是唯一能通过 `RDEC` 可靠读回的与控制相关的寄存器；占空比/模式寄存器是只写路径。
证据和完整寄存器表见 [EC-REGISTERS.md](docs/EC-REGISTERS.md)。

kext（`FanProbe`）通过 `IOACPIPlatformDevice::evaluateObject` 调用 `\_SB.AMWW.WMAX`，
并暴露 `kern.fanprobe.*` 系列 sysctl。另外用 `SSDT-FANEC` 增加了一个 `DSHF.RDEC` 方法，
让 kext 能读取任意 EC 寄存器。

## 安装

### Homebrew（App + 命令行）

Cask 会安装 `FanCtl.app` 和 `fanctl` 命令行，但**不会**把 kext/SSDT 装进 EFI 分区；
这两项仍需按下面的手动步骤处理。

```bash
# 在仓库目录中直接安装
brew install --cask ./Casks/g15-fanctl.rb

# 或者添加 tap 后按名字安装
brew tap 1352714198aaaaa-cmd/dell-g15-black-apple-fan-control https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control
brew install --cask g15-fanctl
```

App 未签名、未公证；Cask 的提示会说明 Gatekeeper 的处理方式，以及 `FanProbe.kext` 和
`SSDT-FANEC.aml` 的暂存位置。

### 手动安装

1. 把 `FanProbe.kext` 放进 `EFI/OC/Kexts/`，并在 `Kernel → Add` 里加一项
   （`BundlePath FanProbe.kext`、`ExecutablePath Contents/MacOS/FanProbe`、
   `PlistPath Contents/Info.plist`）。
2. 把 `SSDT-FANEC.aml` 放进 `EFI/OC/ACPI/`，并在 `ACPI → Add` 里加一项。
3. 重启。
4. 安装命令行：`sudo cp cli/fanctl /usr/local/bin/fanctl && sudo chmod 755 /usr/local/bin/fanctl`
5. 可选：构建 App 并把 `FanCtl.app` 复制到 `/Applications`。

需要开机自动恢复和登录自启时，安装 [`docs/examples/`](docs/examples/) 里的示例任务：

```bash
sudo cp docs/examples/com.dsh.fanctl.restore.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.dsh.fanctl.restore.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.dsh.fanctl.restore.plist

cp docs/examples/com.dsh.fanctl.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dsh.fanctl.plist
```

## 构建

需要 Xcode Command Line Tools（`clang`、`swiftc`），SSDT 需要 ACPICA 的 `iasl`。

```bash
./kext/build.sh     # 生成 kext/FanProbe.kext
./ssdt/build.sh     # 生成 ssdt/SSDT-FANEC.aml
./app/build.sh      # 生成 app/FanCtl.app
```

如果没装 `iasl`，可以从 ACPICA 源码编译或 `brew install acpica`，然后
`IASL=/path/to/iasl ./ssdt/build.sh`。

## 用法

```bash
fanctl mode balanced|perf|cool|quiet|g|auto
fanctl duty 1 50          # 风扇 1 设为 50%
fanctl duty 2 100         # 风扇 2 设为 100%
fanctl rpm                # 读取转速
fanctl status             # 查看最近一次调用结果
```

`kern.fanprobe.lastret` 为 `0` 表示调用成功。

## 限制

- 设置立即生效，重启/断电后丢失（EC 恢复自动）。
- 测试环境下 macOS 系统盘是 USB 的，SSD 温度读不到（USB 不支持 SMART）。
  内置 NVMe 的 SMART 温度需要额外的 CFPlugIn 实现，暂未包含。
- ACPI/EC 接口是机型私有、未公开的，这是逆向实现，不是 Dell 官方 API。

## 致谢

- `app/smcread.c` —— 独立实现的 AppleSMC 读取协议。
- SSDT 使用 Intel ACPICA 的 `iasl` 编译（仅构建时依赖）。
