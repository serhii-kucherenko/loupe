# Loupe - agent instructions

`project_tracker: linear`

The ordered list of work lives in the [Linear project](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084).
Do not create a ROADMAP.md or a plans directory here: two lists mean two truths and both rot.

## What this is
An annotation SDK compiled into the dev/staging build of a host app. **Two SDKs, one
format**: Swift for macOS/iPad/iPhone, TypeScript in `web/` for the browser and Electron.
Open source, MIT. It is meant to be adopted by other people's apps, so the public API is a
contract: additive changes only, no breaking renames without a major.

## Layout
| Path | What |
|---|---|
| `Sources/LoupeCore` | the bundle model, recorders, transports. No UIKit, no AppKit. |
| `Sources/LoupeUI` | the picker, the theme, the overlay. Every platform seam lives here. |
| `Sources/LoupeLinear` | delivery into Linear. Opt-in, and **nothing depends on it**. |
| `web/` | the TypeScript SDK. Its own package, its own tests. |
| `Examples/LoupeDemo` | the seeded two-role demo, plus the snapshot renderer. |
| `Examples/LoupeDemoApp` | the same demo sources, built as an iPad/iPhone app. XcodeGen input only. |
| `docs/bundle-format.md` | the contract between the SDKs and anything that reads bundles. |
| `docs/tokens.json` | `DESIGN.md`, machine-readable. Both SDKs are tested against it. |

## Rules
- `LoupeCore` stays free of UIKit and AppKit. It is the testable half; keep it that way.
- `LoupeCore` also stays free of any opinion about issue trackers. `LoupeLinear`
  depends on `LoupeUI`, never the reverse: a host that wants capture only takes
  `LoupeUI` and never compiles a line of Linear. The dependency that matters is the
  one that does not exist.
- A credential belongs in the Keychain and nowhere else. There is a test asserting it
  never reaches `UserDefaults`; keep it passing.
- Anything written to Linear must be safe to repeat. `QueuedTransport` retries whole
  bundles, so a send that created three issues and then lost the network would
  otherwise create them again. `LinearTransport` searches for the annotation's marker
  before creating.
- `LoupeUI` holds every platform seam, behind `#if canImport(...)`.
- Visible UI follows `DESIGN.md`. A new token goes in that file **and** `docs/tokens.json`
  in the same change, then `cd web && npm run sync-tokens`. A token that means two things
  on two platforms is worse than no token at all, and CI fails on the drift.
- **Nothing Loupe draws may sit over the app while picking.** Anything with a
  `.loupeInteractive()` region *takes* the touches that land on it, so a panel in the
  way is not merely ugly - whatever is under it cannot be annotated, which is the one
  thing this tool must never take away. `scene=occlusion` is the guard: it asserts a
  point where chrome used to be is not inside any interactive region and still
  resolves to a real element.
- Two gestures, not one: a tap picks an element, a drag picks a region. A region is a
  first-class answer (`element.kind: "region"`), not a failure - a gap between two rows
  is real feedback and no view corresponds to it. On the web a region carries no crop:
  the capture works by cloning an element into an SVG `foreignObject`, and there is no
  element to clone.
- The bundle format is a contract. Adding a field is safe; renaming or removing one is not.
  Decoders are hand-written on the Swift side precisely so an older bundle still reads.
- Non-trivial logic leaves one runnable test behind. `swift test` and `cd web && npm test`
  must both pass before any commit.
- The meaningful-ancestor walk is the correctness core, on both platforms. Changes there
  need a test. Two bugs have already come out of it: AppKit's static labels are
  `NSControl`s, and `elementFromPoint` retargets shadow content to the host.
- The size ceiling on the walk is `maxWindowAreaFraction`, one third. It is a
  measurement rather than a list of framework class names on purpose: a rule keyed on
  a private type like `PlatformGroupContainer` goes quiet instead of failing when the
  OS renames it. Reported bounds are clipped to the viewport, because a scrolling
  container can report a frame wider than the window with a negative origin.
- A point the framework cannot resolve still captures: `ElementPicker.capture` falls back
  to a fixed box around it (`region`), and every capture path goes through that one call
  so the fallback cannot be wired into one platform and forgotten in another. A reference
  with no `className` is a region.
- A picked element on iOS under SwiftUI has **no name**: SwiftUI draws a row into one
  layer and leaves its accessibility tree unbuilt until VoiceOver runs, so no `UILabel`,
  accessible name, or identifier exists at the UIKit level. Verified by probe on an iPad
  simulator. Do not go looking for it again. The crop and the context shot carry the
  meaning there, which is why both are always captured.
- Never use `instanceof` on DOM types in `web/`. An element inside an iframe is from
  another realm and the check silently fails. Check `tagName` or duck-type instead.
- After changing anything visible, re-run the snapshots and look at them:
  `cd Examples/LoupeDemo && swift run LoupeSnapshots ../../docs/screenshots`.
- Snapshots only cover macOS. For iPad and iPhone, build the app and drive it with the
  scene hook, which is the only way those states are ever seen:
  `cd Examples/LoupeDemoApp && xcodegen generate && xcodebuild -scheme LoupeDemo ...`,
  then `xcrun simctl launch --console-pty <device> dev.loupe.demo scene=tray`
  (`hover`, `pick`, `tray`, `drag`, `dragging`, `key`, `queue`, `drain`, `repick`,
  `occlusion`).
  **A scene that must observe the mode it starts in has to run before the shared
  `beginAnnotating()`**, or it measures the wrong one - that cost three wrong fixes to
  a bug that was never there. `simctl terminate` often does not take: `uninstall` and
  reinstall between runs, or the tray still holds the previous run's notes.
- The offline queue across a real process boundary:
  `scene=queue endpoint=dead`, then `simctl terminate` (never `uninstall`, which wipes
  the queue), then `scene=drain endpoint=stub`. One send is one bundle, so three notes
  queue as one pending file.
- For the web, headless Chrome `--screenshot` **races the page** even at
  `--virtual-time-budget=15000`: roughly one run in three captures before the module
  script has finished, and the result looks exactly like the overlay failing to
  appear. Confirm with `--dump-dom` (the scene hook sets `<title>ready`) before
  believing a blank one, and take the screenshot again rather than chasing it.
