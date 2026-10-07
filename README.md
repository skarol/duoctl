# duoctl

Fold, rotate and touch the **iPhone Duo simulator** from the command line — built for
scripts and AI coding agents.

```bash
duoctl close                     # fold shut: the cover screen takes over
duoctl open                      # unfold flat: the inner screen takes over
duoctl rotate portrait           # rotate the active screen's interface
duoctl tap --label "Continue"    # tap — on the inner screen too
duoctl swipe 330 800 330 300     # scroll
duoctl screenshot shot.png       # capture whichever screen is showing
duoctl state                     # hinge angle, active screen, orientation, size
```

Xcode 27.1's Device Hub can fold and rotate the Duo, but nothing scriptable can:
`simctl` has no hinge or rotation command, `devicectl device orientation set` reports
success and changes nothing, and `XCUIDevice.shared.orientation` is ignored. Taps are
worse: AXe, idb, XcodeBuildMCP and similar tools deliver every touch to the cover
screen's touchscreen, so on an unfolded Duo they report success and nothing happens.
`duoctl` fixes all three.

## Requirements

- macOS with Xcode 27.1 or later and the iOS 27.1 simulator runtime
- A booted iPhone Duo simulator
- Python 3 (ships with the Xcode command line tools)
- Optional: [AXe](https://github.com/cameroncooke/AXe) for `--label`, `--id` and `elements`

## Installation

**For AI agents** — install the [agent skill](skills/duoctl) with [skills.sh](https://skills.sh) or [openskills](https://github.com/numman-ali/openskills).
It bundles the CLI, so nothing else is needed:

```bash
npx skills add skarol/duoctl
# or
npx openskills install skarol/duoctl
```

**On your `PATH`** — from source:

```bash
git clone https://github.com/skarol/duoctl.git
ln -s "$PWD/duoctl/bin/duoctl" /usr/local/bin/duoctl
```

The first run compiles a small helper for the simulator with Xcode's clang and caches it
in `~/.cache/duoctl`.

## Usage

```
duoctl [-d <udid|name>] <command>

state                                   print state as JSON
open | close | half                     set the hinge to 180° / 0° / 90°
hinge <degrees>                         set any hinge angle, 0 (closed) to 180 (flat)
rotate <orientation>                    portrait | landscape | portrait-upside-down | landscape-flipped
tap <x> <y> | --label L | --id I        tap (interface points of the active screen)
long-press <x> <y> [--duration s]       press and hold
swipe <x1> <y1> <x2> <y2> [--duration]  drag between two points
screenshot <path>                       PNG of the screen showing the interface
elements                                labelled accessibility elements with frames
```

With one iPhone Duo booted, `duoctl` uses it. With several, pass `-d` or set
`DUOCTL_UDID` — it never guesses.

Orientation names describe the **interface**, not the device: the inner screen sits a
quarter turn from the cover, so its default unfolded orientation is `landscape`.

## How it works

Everything runs through a small helper that `duoctl` starts inside the simulator with
`xcrun simctl spawn`.

**Hinge and orientation.** Device Hub's hinge slider and orientation picker both send a
vendor-defined HID event (usage page `0xFF61`, usage `0x5B`) whose payload is a
binary-serialized dictionary. `locationd` turns it into a hinge angle or a device
orientation:

| Control | `source` | `type` | `value` |
|---|---|---|---|
| Hinge | `hinge-slider-control` | `range` | degrees, 0–180 |
| Orientation | `orientation-picker-control` | `enum` | `portrait`, `pud`, `landscape-left`, `landscape-right`, `faceup`, `facedown` |

Both carry `provider = "com.apple.Virtualization"`. `duoctl rotate` tries device
orientations until the active screen reports the rotation you asked for, because the
same device orientation rotates the cover and inner screens differently.

**Touches.** The simulator exposes one CoreDevice touchscreen HID service per display,
each tagged with its display's UUID. Existing tools inject touches through the legacy
simulator HID path, which always lands on the main (cover) touchscreen. `duoctl` reads the
active display's UUID from `devicectl`, clones that display's touchscreen as a virtual
HID service, and dispatches digitizer events through the clone, converting your
interface coordinates to the panel's native axes for the current rotation.

State is read back with `xcrun devicectl device info displays` and
`xcrun devicectl device motion hinge-angle`.

## Limitations

- Simulator only.
- Relies on private, undocumented interfaces verified with Xcode 27.1 and the iOS 27.1
  runtime. A future release may change them; `duoctl` checks state after every change so a
  break shows up as an error rather than a silent no-op.
- Device Hub's hinge slider and rotation indicator don't follow changes made by `duoctl`.

## Credits

The hinge event format was first documented by Artem Novichkov's
[hinge](https://github.com/artemnovichkov/hinge).

## License

MIT — see [LICENSE](LICENSE).
