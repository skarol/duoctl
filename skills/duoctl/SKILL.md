---
name: duoctl
description: Fold, unfold, rotate, tap, swipe and screenshot the iPhone Duo simulator (Xcode 27.1+) from the command line. Use whenever you drive or verify an app on an iPhone Duo simulator — changing the hinge angle or posture, rotating either screen, tapping or scrolling on the inner (unfolded) screen where AXe/idb/XcodeBuildMCP taps silently miss, or capturing the screen that is actually showing.
---

# duoctl

Run `scripts/duoctl` (relative to this skill's directory), or `duoctl` if it is on `PATH`.
It picks the only booted iPhone Duo automatically; when several are booted, pass
`-d <udid>` or set `DUOCTL_UDID`. Never guess between simulators.

## Commands

```bash
scripts/duoctl state                       # JSON: hingeAngle, activeScreen (cover|inner), orientation, sizePoints
scripts/duoctl close | open | half         # 0° / 180° / 90°; waits until the right screen is active
scripts/duoctl open --duration 1.5         # animate the fold instead of jumping (for recordings)
scripts/duoctl hinge 120                   # any angle 0…180, also takes --duration
scripts/duoctl rotate portrait             # portrait | landscape | portrait-upside-down | landscape-flipped
scripts/duoctl tap 120 340                 # interface points of the active screen
scripts/duoctl tap --label "Done" --type Button
scripts/duoctl tap --id settings.closeButton
scripts/duoctl long-press 120 340 --duration 1
scripts/duoctl swipe 330 800 330 300 --duration 0.4
scripts/duoctl screenshot out.png          # the screen that is showing the interface
scripts/duoctl elements                    # labelled accessibility elements with frames
```

Every command that changes state prints `state` afterwards — read it instead of assuming.

## Workflow

1. `scripts/duoctl state` to see which screen is active and its size in points.
2. Change posture or orientation; the JSON confirms the result.
3. Find targets with `scripts/duoctl elements` (frames are in the active screen's
   interface points, the same space `tap` and `swipe` use), then `tap`.
4. Verify with `scripts/duoctl elements` or `scripts/duoctl screenshot` — never trust
   that a touch landed without checking the screen changed.

## Things to know

- **Use `duoctl tap`/`duoctl swipe` on the inner screen.** Other simulator touch tools
  (AXe, idb, XcodeBuildMCP `tap`, RocketSim `interact tap`) always deliver to the
  cover screen's touchscreen, so on an unfolded Duo they report success and do nothing.
- `orientation` names describe the interface, not the device. The inner screen sits a
  quarter turn from the cover, so its default unfolded orientation is `landscape`.
- An app that doesn't support an orientation won't rotate; `rotate` then fails with an error.
- `--label`/`--id`/`elements` need the AXe CLI (bundled with XcodeBuildMCP, or
  `brew install cameroncooke/axe/axe`). Coordinate taps don't.
- `simctl io <udid> screenshot` without `--display` captures the inner screen even
  while folded (a black image). Use `duoctl screenshot`.
- The first run compiles a small in-simulator helper with Xcode's clang and caches it in
  `~/.cache/duoctl`.
- Built on private, undocumented simulator interfaces verified with Xcode 27.1 and the
  iOS 27.1 runtime. If a command succeeds but `state` doesn't change, report that the
  interface has likely changed rather than retrying.
