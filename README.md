# wacomd — Wacom Intuos Pro Small (PTH-451) driver for macOS 26 Tahoe

A small Swift userspace daemon that brings the **Wacom Intuos Pro Small
(PTH-451)** back to life on **macOS 26 Tahoe**, where Wacom's official driver
no longer ships a supported version for this model.

No kernel extension, no DriverKit, no entitlements from Apple. The whole thing
sits in userspace: `IOHIDManager` reads raw HID reports, a parser ported from
the Linux kernel decodes the Wacom vendor protocol, and `CGEvent` injects pen
moves / clicks / pressure into the event tap. Same approach as
[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver) and
[Hawku](https://github.com/poiuyt9876/hawku-userspace).

🇫🇷 Une version française du README est disponible : [README.fr.md](README.fr.md).

## ⚠️ Scope — what this driver does NOT do

The following are **not implemented yet** :

- ❌ The 6 **ExpressKeys** (the pad buttons on the side of the tablet)
- ❌ The **Touch Ring** (the wheel)
- ❌ Multi-touch gestures beyond **2-finger scroll** (pinch / rotate / 3-finger
  swipe require private SPI and are out of scope)

If your workflow depends on any of those, this driver is not enough for you
yet. They're all on the roadmap — see [Roadmap](#roadmap).

## 🛑 If you have the official Wacom driver installed: disable it first

Even when Wacom's driver no longer supports your tablet, its installer
puts a `TabletEvents` framework and several background daemons in place
that **intercept tablet events at the system level**. Pressure-aware apps
(Photoshop, Affinity Photo, Procreate, Krita, …) prefer that pipeline over
the standard NSEvent tablet API, so they will receive **zero pressure**
even when wacomd is correctly posting events.

Disable the Wacom daemons (reversible, no files deleted) :

```bash
./packaging/disable-wacom-driver.sh
```

Then quit and reopen your drawing app so it reloads without the Wacom
framework. Restore later with :

```bash
./packaging/restore-wacom-driver.sh
```

## Status — v0.3 (tested live on macOS 26.3, Apple Silicon)

| Feature                                          | Status |
| ------------------------------------------------ | ------ |
| Auto-detect plug / unplug                        | ✅     |
| Pen position → cursor                            | ✅     |
| Tip switch → left click                          | ✅     |
| Barrel button → right click                      | ✅     |
| Pressure (2048 levels) for Photoshop/Procreate/Krita/Affinity/Clip Studio | ✅     |
| Tilt X / Y                                       | ✅     |
| Eraser flag                                      | ✅ (signalled) |
| **2-finger touch scroll**                        | ✅ **new** |
| Multi-monitor configurable mapping               | ❌ primary screen |
| ExpressKeys (6 buttons)                          | ❌ TODO v0.4 |
| Touch Ring                                       | ❌ TODO v0.5 |
| Multi-touch gestures (pinch / rotate)            | ❌ private SPI required |
| Configuration UI                                 | ❌ TODO |

Roughly **200 events/s sustained** in the live test, which matches the
PTH-451's native HID rate.

## Why this exists

The Intuos Pro Small (PTH-451, 2013) is a fantastic piece of hardware that
Wacom quietly stopped supporting on recent macOS. Their current driver
installer either refuses to recognise the device, or installs but produces no
events. This project is a 700-line drop-in replacement that handles pen input
properly. ExpressKeys and the Touch Ring are next on the list.

## Build

Requires Xcode Command Line Tools (Swift 5.9+). Tested on Swift 6.3 / macOS 26.3.

```bash
git clone https://github.com/yanickb/wacomd.git
cd wacomd
swift build -c release
```

The binary lands at `.build/release/wacomd`.

## Permissions (the macOS 26 trap)

The daemon needs **Accessibility** (to post pen events) and **Input
Monitoring** (to read HID reports). On macOS 26 Tahoe these two privacy
panels **are not in the System Settings sidebar** — you have to click into
*Privacy & Security* and scroll down past Location, Contacts, Calendars, etc.

Jump directly to them:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
```

The daemon self-reports its permission state at startup:

```
[wacomd] Accessibility ........... granted
[wacomd] Input Monitoring ........ granted
```

If you launch it from a Terminal that already has those two permissions, it
inherits them — no need to register `wacomd` itself.

## Run manually

```bash
.build/release/wacomd
```

Move the pen → cursor follows. Press → click with pressure. `Ctrl+C` to quit.

Verbose mode (HID dumps, throughput counter) :

```bash
.build/release/wacomd -v
# or
WACOMD_VERBOSE=1 .build/release/wacomd
```

## Install as a LaunchAgent (auto-start on login)

```bash
INSTALL_DIR="$HOME/Library/Application Support/wacomd"
mkdir -p "$INSTALL_DIR"
cp .build/release/wacomd "$INSTALL_DIR/"
cp packaging/com.local.wacomd.plist "$HOME/Library/LaunchAgents/"

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.wacomd.plist
launchctl enable    gui/$(id -u)/com.local.wacomd
launchctl kickstart -k gui/$(id -u)/com.local.wacomd
```

Logs go to `/tmp/wacomd.log`.

⚠️ When launched by `launchd` (rather than from a Terminal) the daemon has its
**own privacy identity** — you'll have to grant Accessibility and Input
Monitoring to the installed binary at
`/Users/<you>/Library/Application Support/wacomd/wacomd` explicitly.

To uninstall :

```bash
launchctl bootout gui/$(id -u)/com.local.wacomd
rm ~/Library/LaunchAgents/com.local.wacomd.plist
rm -rf "$HOME/Library/Application Support/wacomd"
```

## How it works — the interesting bit

My first attempt registered an `IOHIDDeviceRegisterInputValueCallback` on
the standard HID usages (`GenericDesktop.X`, `Digitizer.TipPressure`, …)
and got **zero events** despite 2200 HID reports per second arriving from
the tablet.

The reason : **Wacom Intuos Pro devices don't expose pen data on standard
HID pages.** Everything arrives on the vendor-defined page **`0xff0d`** as
raw 10-byte reports, Report ID 2. The fix is to register an
`IOHIDDeviceRegisterInputReportCallback` and parse the bytes manually,
following the Linux kernel's `drivers/hid/wacom_wac.c` :

```
data[0] = 0x02  (Report ID)
data[1] = status (proximity, buttons, LSB of pressure)
data[2..3] = X high bytes (combined with bit 1 of data[9])
data[4..5] = Y high bytes (combined with bit 0 of data[9])
data[6..7] = 11-bit pressure (10 high + 1 LSB in status)
data[7..8] = tilt X, tilt Y (-64..63)
data[9]   = distance (6 bits) + LSB X/Y (2 bits)
```

The parser lives in
[`Sources/wacomd/IntuosProParser.swift`](Sources/wacomd/IntuosProParser.swift)
and is unit-tested with real frames captured from a live device.

Data flow :

```
USB HID raw report  →  IOHIDDeviceRegisterInputReportCallback
                                ↓
                       IntuosProParser.decode()
                                ↓
                            PenSample
                                ↓
                     WacomDevice.handle(report:)
                                ↓
                            PenState
                                ↓
                     EventInjector.update()
                                ↓
            CGEvent (mouseMoved/Down/Up + tabletEventPoint*)
                                ↓
                          cghidEventTap
                                ↓
                  WindowServer → apps (Photoshop, Procreate, …)
```

## Project layout

```
Sources/wacomd/
├── main.swift             ── entry point, RunLoop, signal handlers
├── Permissions.swift      ── Accessibility prompt + Input Monitoring SPI
├── HIDMonitor.swift       ── IOHIDManager, VID/PID matching
├── WacomDevice.swift      ── opens the pen interface (page 0xff0d)
├── IntuosProParser.swift  ── 10-byte vendor report decoder
├── IntuosPro.swift        ── physical specs (max X/Y, pressure, dimensions)
├── PenState.swift         ── current pen state
├── EventInjector.swift    ── screen mapping + CGEvent + tablet fields
└── Verbose.swift          ── -v / WACOMD_VERBOSE=1
```

## Device

| Field        | Value                  |
| ------------ | ---------------------- |
| Vendor ID    | `0x056a` (Wacom)       |
| Product ID   | `0x0314`               |
| Marketing    | Intuos Pro Small       |
| Part number  | PTH-451 / PTH-451/K0   |
| Pressure     | 2048 levels (11-bit)   |
| Resolution   | 5080 lpi               |
| Active area  | 157 × 98 mm            |
| Coordinates  | 31496 × 19685          |

Other PTH-XXX models very likely use the same protocol (the Linux Wacom
driver treats the whole Intuos5 / Intuos Pro family with one parser).
Adding them is just a matter of registering the new VID/PID in
`KnownModels` in [`IntuosPro.swift`](Sources/wacomd/IntuosPro.swift) —
**PRs welcome**.

## Roadmap

- ExpressKeys + Touch Ring (Report ID 12 on the pad interface — same vendor
  page, different layout, parser ported from `wacom_intuos_pad` in Linux)
- Multi-touch surface (Report ID 13)
- Per-application profiles via `NSWorkspace.frontmostApplication`
- TOML / YAML config for screen mapping & active area
- Real tablet proximity events (`.tabletProximity`) so apps show the pen
  indicator
- Bluetooth variants (PTH-451 has a wireless kit)

## Contributing

Pull requests welcome. If you have a different Wacom model and want to
contribute support, run the daemon in verbose mode for a few seconds while
moving the pen and open an issue with the hex dump — the protocol is the
same family across the Intuos5 / Pro line.

## References

- Linux kernel : [`drivers/hid/wacom_wac.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c)
  — authoritative source for the Wacom protocol.
- [linuxwacom](https://github.com/linuxwacom/) — historical documentation
  project.
- [OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver) —
  reference for cross-platform userspace approach.

## License

MIT — see [LICENSE](LICENSE).
