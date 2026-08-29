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
- **"Executed 0 tests" with exit 0 is a stale test bundle, not a passing run.** After
  a package change `xcodebuild test` can silently run nothing and succeed, and
  whatever artefact you then read - a screenshot, a bundle on a simulator container -
  is the *previous* run's. That very nearly reported a broken fix as working. Check
  the count, and check an artefact's mtime before believing anything you read off a
  container. `build-for-testing` then `test-without-building` clears it.
- **`swift test` is the macOS suite only. Run the other two before pushing.** Both
  have caught things nothing on this machine could:

  ```sh
  swift test -Xswiftc -swift-version -Xswiftc 6      # CI's Swift 6 job
  xcodebuild test -scheme Loupe-Package \
    -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' \
    -skipPackagePluginValidation                      # CI's iOS job
  ```

  The iOS simulator **has no Keychain**, so every write and every delete is refused
  with `errSecMissingEntitlement`. Any test that stores or clears a credential has to
  skip on `LinearError.couldNotStore` - and note that a refusal is *not*
  `errSecItemNotFound`, which is a mistake worth not making twice. Swift 6 mode
  rejects things the package's declared Swift 5 accepts, including a nonisolated
  `setUp` touching a `@MainActor` case's own properties.
- **A failure that says nothing is the bug this project keeps having.** Six in one
  evening shared one shape: an operation that could fail, a result nobody was forced
  to read, and a product that carried on looking fine. A refused Keychain write. A
  discarded `session.start()`, which hung sign-in forever. A `try?` that turned a
  dropped request into "the project was deleted". And a discarded `SecRandomCopyBytes`
  that left sign-in *working* while making the PKCE verifier a constant - **a failure
  with no symptom at all**, which running the product can never find, unlike every
  other bug on this project. `try?` and `@discardableResult` are ergonomic features:
  they exist to let you skip a decision, so they collect exactly where somebody did
  not want to make one. `scripts/check-quiet-failures.py` runs in CI and fails on a
  new one; `scripts/quiet-failures.allow` holds every argued-for case with its reason.
  Writing the reason is the check - if you cannot, that is the finding.
  **And an allow-list entry argues about a case, while a `try?` swallows a type.** The
  eighth one got through the lint on a reason that was true: "not being configured is
  not a failure". True of `.notConfigured`, false of every other error that line could
  throw - so a missing team became a silent skip, and a skip read as success because
  the local write had already happened. Two notes were reported as delivered on a real
  iPad and neither existed in Linear. If the reason does not hold for **every** error
  the expression can throw, the entry is wrong even though every word of it is right.
- A credential belongs in the Keychain and nowhere else. There is a test asserting it
  never reaches `UserDefaults`; keep it passing. **A refused write is an error somebody
  must see, never a `Bool` that gets discarded** - `save(_:)` throws
  `LinearError.couldNotStore`, the panel shows it and stays open, and the message names
  the entitlement, because the fix is in the host's build settings and nobody guesses
  it from a blank field. An adopter lost a key to the old silence: Test connection
  passed, because it validated the value in memory, and the one operation that could
  fail said nothing. Any host taking `LoupeLinear` needs the Keychain Sharing
  capability, or `keychain-access-groups` with `$(AppIdentifierPrefix)` and its bundle
  id. It is not optional on Mac Catalyst.
- Anything written to Linear must be safe to repeat. `QueuedTransport` retries whole
  bundles, so a send that created three issues and then lost the network would
  otherwise create them again. `LinearTransport` searches for the annotation's marker
  before creating.
- `LoupeUI` holds every platform seam, behind `#if canImport(...)`.
- Visible UI follows `DESIGN.md`. A new token goes in that file **and** `docs/tokens.json`
  in the same change, then `cd web && npm run sync-tokens`. A token that means two things
  on two platforms is worse than no token at all, and CI fails on the drift.
- **A test that drives the model proves the model, not the product.** A
  `UIHostingController` is one `UIView`, so "does the touch actually arrive" is a
  question no unit test in this repo can ask - and it has gone wrong twice. Once the
  pill and the whole tray were untappable on iOS with a fully green suite (SER-682).
  Once the drawer's pull moved on about half of drags, because a `Button`'s tap
  recogniser was beating a plain `.gesture`. **Anything the finger has to reach gets a
  case in `Examples/LoupeDemoApp/UITests`**, which runs on a real simulated iPad in CI.
  Name a slow velocity on synthetic drags: XCUITest's default moves the touch in so few
  events that SwiftUI can miss the gesture, and that flakiness hides real bugs.
  **A UI run that times out or restarts mid-suite is usually a wedged simulator, not
  your code** - `Restarting after unexpected exit, crash, or test timeout` in the log,
  a `testmanagerd` snapshot timeout, or a run that takes an hour instead of two
  minutes. `xcrun simctl shutdown` then `boot` clears it. Do not go looking for a
  gesture bug first; both agents on this project have lost time to it.
  **One label per element, never one on the container.** A label on a stack that holds
  buttons makes two things answer to one name, and XCUITest fails with "multiple
  matching elements" rather than anything that names the cause. Same mistake as
  SER-685, one level up.
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
- **Adding a file to `Sources/` and getting "cannot find type X in scope" from
  `Examples/LoupeDemo`?** That is a stale `.build`, not your code. SwiftPM misses a new
  source file in a path dependency. `rm -rf Examples/LoupeDemo/.build` and build again.
  It has cost two debugging detours already, and the error it produces points at
  perfectly good code.
- Never use `instanceof` on DOM types in `web/`. An element inside an iframe is from
  another realm and the check silently fails. Check `tagName` or duck-type instead.
- **Every screenshot is of this repo's own demo app. Never of a host that adopted
  Loupe.** `Examples/LoupeDemo` exists precisely so there is something to photograph.
  An adopter's app is somebody's real product and, on a device, their real data - a
  screenshot run once picked up the adopter's book library because another agent had
  it in the simulator's foreground, on its way into a public README. `scripts/
  screenshots.sh` names its simulators and checks the demo is the app in front before
  it believes the picture; do not loosen either.
- **A screenshot nothing points at is deleted, not left lying there.** The moment a
  shot stops showing something real - the UI moved on, or the README stopped linking
  it - it is either regenerated, re-linked, or removed in that same commit. Dead
  images are not free: they are read as current by anyone browsing the repo, and they
  are the ones that quietly go stale because nobody is looking at them.
  `bash scripts/screenshots.sh` lists any file in `docs/screenshots/` that no
  Markdown or source file mentions.
- **Change the UI, change the screenshots, in the same commit.** Not a follow-up, not a
  ticket. `bash scripts/screenshots.sh` regenerates every macOS, iPad and iPhone shot in
  `docs/screenshots/`; `mac` or `ios` does half. **Then open them and look**, because the
  script cannot tell a correct screenshot from a wrong one. A stale screenshot is worse
  than no screenshot: it is a confident picture of a product that no longer exists, and
  it is what somebody judges this by before they ever run it. The web shots are the one
  exception and are taken by hand, for the reason two bullets down.
- Snapshots only cover macOS. For iPad and iPhone, build the app and drive it with the
  scene hook, which is the only way those states are ever seen:
  `cd Examples/LoupeDemoApp && xcodegen generate && xcodebuild -scheme LoupeDemo ...`,
  then `xcrun simctl launch --console-pty <device> dev.loupe.demo scene=tray`
  (`hover`, `pick`, `tray`, `drag`, `dragging`, `key`, `queue`, `drain`, `repick`,
  `occlusion`, `lowpick`, `settings`, `zero`, `emptytray`).
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
