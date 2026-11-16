# EC register reference

Reverse-engineered map of the embedded controller (EC) registers used by FanCtl on a
**Dell G15 5511** (i7-11800H + RTX 3060 Laptop) running macOS 26.7.3. The values below were
read through the project's own kernel interface; they are **not** from a Dell datasheet.

> **Safety:** the only supported write path is the AWCC `WMAX` command used by `fanctl` and
> the app. There is no generic EC write sysctl. Do not poke arbitrary EC addresses: some EC
> registers have side effects, and a bad write can hang or damage the machine. Reading is
> also not guaranteed side-effect-free on every firmware revision.

Confidence labels used below:

| Label | Meaning |
| --- | --- |
| **verified** | Reproduced by a live experiment described in §8 |
| **inferred** | Taken from the original reverse-engineering notes / DSDT behaviour, not confirmed by readback |
| **unknown** | Observed value, no reliable interpretation |

## 1. Access paths

There are two independent paths to the EC, and they do **not** necessarily see the same
register bank:

```text
userspace                 kernel                    ACPI                    firmware
---------                 ------                    ----                    --------
sysctl ecread=N  ---->  FanProbe  ---->  DSHF.RDEC(N)  ---->  ECDV.ECR1(N)  ---->  EC
sysctl mode/duty ---->  FanProbe  ---->  AMWW.WMAX(...) ---->  AWCC mailbox  ---->  EC
```

- `kern.fanprobe.ecread` → `DSHF.RDEC` → `\_SB.PC00.LPCB.ECDV.ECR1` is the **read path**.
- `kern.fanprobe.mode` / `duty` → `\_SB.AMWW.WMAX` is the **write path**.
- `kern.fanprobe.ec50` uses `WMAX(0x25, {2,0,0})`, a third, command-specific read path.

The read path returns a 16-bit value for the tachometer addresses (`0x57`, `0x59`) and an
8-bit value elsewhere. The write path is documented by the BIOS/firmware notes as touching
`0x21`/`0x22`/`0x23`, but those addresses do not reflect the writes when read back through
`RDEC` (see §8).

## 2. Control registers (write path)

| Address | Name | Width | Access | Values | Confidence | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `0x21` | Fan 1 duty | 8-bit | W via `WMAX` | 0–100 | inferred | Readback constant `28`; not updated by `fanctl duty` |
| `0x23` | Fan 2 duty | 8-bit | W via `WMAX` | 0–100 | inferred | Readback constant `44`; not updated by `fanctl duty` |
| `0x22` | Thermal mode | 8-bit | W via `WMAX` | `0xA0`–`0xA3`, `0xAB`, `0` | inferred | Readback constant `136` (`0x88`), even after mode changes |
| `0x50` | Telemetry / status | unknown | R via `WMAX(0x25)` | observed `0` | unknown | `kern.fanprobe.ec50` triggers this read; always `0` in tests |

The `WMAX` payloads that drive these registers are:

```text
WMAX(0, 0x15, {1, mode, 0})       -> mode register + fan duty defaults
WMAX(0, 0x15, {2, fanId, duty})   -> fanId 0x32 = fan 1, 0x33 = fan 2
WMAX(0, 0x25, {2, 0, 0})          -> read EC 0x50
```

Because the control registers are not readable through `RDEC`, the reliable way to confirm a
write is to watch the tachometers (`0x57`/`0x59`) respond, or to read `kern.fanprobe.lastret`
(`0` = the ACPI call succeeded).

## 3. Fan tachometers (read path)

| Address | Name | Width | Access | Observed range | Confidence | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `0x57` | Fan 1 RPM | 16-bit | R via `RDEC` | ~2,000–5,200 | verified | Returned directly as a 16-bit word |
| `0x58` | — | 8-bit | R via `RDEC` | `0` | verified | Adjacent byte is zero; **not** the high byte of `0x57` |
| `0x59` | Fan 2 RPM | 16-bit | R via `RDEC` | ~2,000–5,200 | verified | Returned directly as a 16-bit word |
| `0x5A` | — | 8-bit | R via `RDEC` | `0` | verified | Adjacent byte is zero; **not** the high byte of `0x59` |

`ECR1` returns the full RPM value for `0x57`/`0x59`; the value can exceed 255
(e.g. `2254`, `4411`). Do not reconstruct the value from two byte reads — `0x58`/`0x5A` read
`0` on this firmware.

The app samples both registers every 2 seconds. The fans are reported to top out around
5,200 RPM in the UI scale, but the actual maximum depends on the firmware and fan curve.

## 4. Temperature and telemetry registers

| Address | Name | Width | Access | Observed | Confidence | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `0x34` | CPU temperature | 8-bit °C | R via `RDEC` | `80`–`83` | verified | Tracks SMC `TC0P` within 1 °C over 5 samples |
| `0x14` | Thermal proxy | 8-bit | R via `RDEC` | `232`–`237` | unknown | Changes with CPU load/mode; not a plain °C value |
| `0x50` | Unknown | unknown | R via `WMAX(0x25)` | `0` | unknown | Read path works (`lastret = 0`), meaning unknown |

`0x34` is a useful independent check of the SMC reading: on the tested machine it followed
`TC0P` from 80 °C to 83 °C exactly. `0x14` moved by a few counts in the same tests, but its
encoding is not understood (possibly a raw diode/ADC value or an uncalibrated sensor).

## 5. Firmware / configuration block

These addresses were stable across all tests and are most likely firmware configuration,
calibration, or status bytes. Their meanings are unknown; they are listed so that future
dumps can be compared.

| Address | Observed (hex) | Observed (dec) | Guess |
| --- | --- | --- | --- |
| `0x20` | `E2` | 226 | config/status |
| `0x24` | `C2` | 194 | config/status |
| `0x25` | `52` | 82 | target/threshold? |
| `0x26` | `7F` | 127 | config |
| `0x27` | `0B` | 11 | config |
| `0x28` | `0B` | 11 | config |
| `0x29` | `08` | 8 | config |
| `0x2E` | `D1` | 209 | config/status |
| `0x2F` | `FF` | 255 | sentinel |
| `0x31` | `01` | 1 | flag |
| `0x35`–`0x37` | `FF FF FF` | 255 | sentinel |
| `0x3E` | `31` | 49 | counter/status |
| `0x80` | `10` | 16 | possible bank/page or status |
| `0x81` | `01` | 1 | possible bank/page or status |

Other addresses in the `0x00`–`0x7F` range read `0`, except the low-numbered bytes listed in
the snapshot below (`0x00`–`0x06`, `0x11`–`0x1C`, `0x1E`–`0x1F`). Addresses `0x82`–`0xFF`
read `0` on this firmware.

## 6. Snapshot (2026-11-16)

Conditions: FanCtl quit, thermal mode `0xA0` (balanced), CPU ≈`75 °C` (per `0x34`),
GPU ≈`61 °C`, fans ~2,254 / 2,516 RPM. Only non-zero registers are shown.

| Address | Hex | Dec | Note |
| --- | --- | --- | --- |
| `0x00` | `33` | 51 | unknown |
| `0x01` | `04` | 4 | unknown |
| `0x02` | `04` | 4 | unknown |
| `0x05` | `01` | 1 | unknown |
| `0x06` | `03` | 3 | unknown |
| `0x11` | `62` | 98 | unknown |
| `0x14` | `E8` | 232 | thermal proxy |
| `0x15` | `2C` | 44 | unknown |
| `0x16` | `FB` | 251 | unknown |
| `0x17` | `17` | 23 | unknown |
| `0x18` | `DC` | 220 | unknown |
| `0x19` | `0B` | 11 | unknown |
| `0x1A` | `88` | 136 | unknown |
| `0x1B` | `47` | 71 | unknown |
| `0x1C` | `0E` | 14 | unknown |
| `0x1E` | `FB` | 251 | unknown |
| `0x1F` | `17` | 23 | unknown |
| `0x20` | `E2` | 226 | config/status |
| `0x21` | `1C` | 28 | fan 1 duty (write path) |
| `0x22` | `88` | 136 | thermal mode (write path) |
| `0x23` | `2C` | 44 | fan 2 duty (write path) |
| `0x24` | `C2` | 194 | config/status |
| `0x25` | `52` | 82 | config/threshold |
| `0x26` | `7F` | 127 | config |
| `0x27` | `0B` | 11 | config |
| `0x28` | `0B` | 11 | config |
| `0x29` | `08` | 8 | config |
| `0x2E` | `D1` | 209 | config/status |
| `0x2F` | `FF` | 255 | sentinel |
| `0x31` | `01` | 1 | flag |
| `0x34` | `4B` | 75 | CPU temperature |
| `0x35` | `FF` | 255 | sentinel |
| `0x36` | `FF` | 255 | sentinel |
| `0x37` | `FF` | 255 | sentinel |
| `0x3E` | `31` | 49 | counter/status |
| `0x57` | `08CE` | 2254 | fan 1 RPM (16-bit) |
| `0x59` | `09D4` | 2516 | fan 2 RPM (16-bit) |
| `0x80` | `10` | 16 | possible bank/page |
| `0x81` | `01` | 1 | possible bank/page |

The five-sample correlation in §8 recorded `0x34` = `80`–`83` while `TC0P` was `80`–`83`
under a slightly higher load.

## 7. How to read registers

Any local user can read through the sysctl (the kext registers the entries with
`CTLFLAG_ANYBODY`):

```bash
# Read one address
sysctl -w kern.fanprobe.ecread=0x57
sysctl -n kern.fanprobe.lastret   # 0 = ACPI call succeeded
sysctl -n kern.fanprobe.lastval   # value

# CLI shortcuts
fanctl rpm                        # 0x57 and 0x59
fanctl diag                       # kext, sysctls, tach, state
```

A full dump:

```bash
for i in $(seq 0 255); do
  reg=$(printf "0x%02x" "$i")
  sysctl -w kern.fanprobe.ecread="$reg" >/dev/null 2>&1
  printf "%s %s\n" "$reg" "$(sysctl -n kern.fanprobe.lastval)"
  sleep 0.05
done
```

**Quit FanCtl before dumping.** The app polls `0x57`/`0x59` every 2 seconds and writes the
result to the same global `kern.fanprobe.lastval` mailbox; concurrent CLI reads can capture
the app's value instead of their own. This is a property of the v1/v2 sysctl ABI, not of the
EC.

## 8. Verification experiments

All tests were run on the machine described above with FanCtl quit, unless noted.

### 8.1 Tachometer readback

`0x57` and `0x59` returned values above 255 (e.g. `2254`, `4411`, `4694`) while `0x58` and
`0x5A` returned `0`. Setting `fanctl duty 1 30` / `2 30` versus `80` / `80` changed `0x57`
from `2744` to `3696` and `0x59` from `3627` to `4604`, confirming the tach semantics and
the 16-bit read width.

### 8.2 Duty writes vs readback

A full 0x00–0xFF dump was taken at 30 % / 30 % and again at 80 % / 80 %. The diff was:

```text
0x14 233 -> 237   (thermal proxy)
0x34  80 ->  81   (CPU temperature)
0x57 2744 -> 3696 (fan 1 RPM)
0x59 3627 -> 4604 (fan 2 RPM)
```

`0x21`/`0x23` did not change. The fans audibly responded, and `lastret` stayed `0`, so the
write path worked even though the read path did not expose the duty value.

### 8.3 Mode writes vs readback

A dump at `0xA0` (balanced) and `0xA1` (performance) differed only in `0x14`, `0x34`,
`0x57`, and `0x59` (temperatures and tachometers). `0x22` stayed at `0x88` (`136`). Again,
the mode change was confirmed by the system's behaviour, not by an EC readback.

### 8.4 CPU temperature correlation

Five samples comparing SMC `TC0P` with EC `0x34`:

| Sample | `TC0P` | `0x34` |
| --- | --- | --- |
| 1 | 81 | 82 |
| 2 | 83 | 83 |
| 3 | 81 | 81 |
| 4 | 80 | 81 |
| 5 | 83 | 82 |

The EC byte tracks the SMC sensor within 1 °C. This makes `0x34` a useful cross-check when
debugging the SMC helper.

### 8.5 `WMAX(0x25)` / EC `0x50`

`sysctl -w kern.fanprobe.ec50=1` returned `lastret = 0` and `lastval = 0` on every attempt.
The call succeeds; the register value was always zero in the tested states.

### 8.6 Startup sanity call

At kext load, `WMAX(0x21, {0,0,0})` returned `2`, stored as `Sanity21 = 2` with
`SanityRet = 0`. This is a liveness check for the AWCC mailbox, not an EC `0x21` read.

## 9. Interpretation and open questions

- The control registers (`0x21`, `0x22`, `0x23`) are probably written by the BIOS through a
  different EC page/bank than the one `RDEC` reads. The original reverse-engineering notes
  and the DSDT's `AX23`/`AX24`/`AX26`/`AX28` paths are the source for the "duty"/"mode"
  labels; the live readback does not confirm them.
- `0x50` may be a status/acknowledge byte rather than telemetry; the AWCC call succeeds but
  returns zero.
- The `0x20`–`0x2F` block looks like firmware configuration (thresholds, calibration, or
  curve points). `0x25 = 82` is suspiciously close to a temperature threshold, but this is
  not proven.
- `0x80`/`0x81` (`0x10`/`0x01`) could be a bank/page selector or status flags. Do not write
  them blindly.
- The exact EC page used by `WMAX` is the main missing piece. A DSDT/EC disassembly or a
  firmware-level trace would settle it.

## 10. References

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the kext, SSDT, CLI, and app fit together.
- `kext/FanProbe.cpp` — sysctl handlers and `WMAX`/`RDEC` marshalling.
- `ssdt/SSDT-FANEC.dsl` — `DSHF.RDEC`.
- `cli/fanctl` — `rpm`, `diag`, and state handling.
