# The annotate overlay - design and build order

Open work lives in [GitHub issues](https://github.com/serhii-kucherenko/loupe/issues).
This file is the *how*: the decisions behind the overlay, the file map, and the phase
order. It is not a task list. See `AGENTS.md`.

## Where the product stands

**Built, 2026-08-28.** Everything below shipped in one cycle: the overlay on macOS and iOS,
the tray, the theme, the offline queue, log capture, the bundle format, the context shot, a
seeded two-role demo per platform, and a second SDK in TypeScript for the browser and
Electron. 83 Swift tests on macOS, 44 on the iOS Simulator, 39 on the web. CI green on all
three.

Still open: an iPad demo target and a run on real hardware (SER-651), and the first release
(SER-652, blocked on an npm org).

This file is kept as the *why*: the decisions below are what the code did, and the
retrospective at the bottom records where they were wrong.

## Decisions

Decided from the code and from `DESIGN.md`, without an interview.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | SwiftUI or AppKit/UIKit for the overlay? | Native window (`NSPanel` / `UIWindow`), SwiftUI content inside it | The window has to layer above someone else's app, which is a native concern. The panels are ordinary layout, and `DESIGN.md` already names SwiftUI type styles. |
| 2 | How is annotate mode entered? | `Loupe.beginAnnotating()`, plus a default `⌥⌘L` on macOS and a floating pill on iOS/iPadOS | The host app must be able to drive it. A default gesture means adopting Loupe needs no UI work from the host. |
| 3 | Does the overlay swallow the host app's input? | Only while *picking*. After a comment is committed it drops to *browsing* and passes clicks through | You have to be able to navigate the app to annotate a second screen. `AnnotationSession` already assumes the tray outlives navigation. |
| 4 | Log capture - in or out? | In. A `LogRecorder` ring buffer shaped exactly like `NetworkRecorder`, fed by a public append API | The README already promises "the errors" in a bundle. Intercepting `os_log` or `stderr` is invasive and fragile; a one-line call from the host's own logger costs us nothing. |
| 5 | Offline queue - in or out? | In, as a `QueuedTransport` decorator that persists first and drains after | `HTTPTransport` throwing is survivable today only because the tray keeps the annotations. Killing the app loses them. |
| 6 | Web SDK - in or out? | ~~Out of this cycle~~ **In** | Overruled by Serhii mid-session: *"we're global tool, not just one system, but multiple, ipad, iphone, web, etc."* Shipped as `web/`, sharing the bundle format and `docs/tokens.json`. |
| 7 | Full-screen context shot beside the tight crop? | ~~Out~~ **In** | Building the Agent inbox produced the evidence immediately: a crop alone cannot answer a layout complaint. Shipped as `contextPNG`, Apple-only. |
| 8 | One demo app or two? | One app, two roles | The MVP bar wants a multi-role click-through. Two binaries would double the seams for no gain. |
| 9 | Tag picker shape? | Four chips | `DESIGN.md` already reserves `radius.control` for "buttons, tag chips". |
| 10 | Where does the full tray live? | Browsing only; a one-line bar while picking | It covered part of the app, and **anything under it could not be pointed at**. Found by running the web demo, fixed on both platforms. |
| 11 | Shake to annotate on iOS? | No - a floating pill | A shake read from a pass-through window above the app is unreliable. `Loupe.handleShake()` is exposed for a host that wants to wire it from its own responder. |
| 12 | How are the overlay's looks checked? | Rendered offscreen from a real `NSWindow`, committed to `docs/screenshots/` | A design system only checkable by launching an app stops being checked. `ImageRenderer` was tried first and is the wrong tool: it will not draw a live `TextField`. |

## The two roles

The MVP bar is a seeded click-through with at least two roles. Loupe has exactly two, and they
sit on opposite sides of the bundle:

```
   ANNOTATOR                                       AGENT
   a person in the app                             the thing that reads the bundle
        |                                               ^
        | 1. ⌥⌘L                                        |
        v                                               |
   highlight follows pointer                            |
        |                                               |
        | 2. click an element                           |
        v                                               |
   comment popover + tag chips                          |
        |                                               |
        | 3. save -> flies into tray                    |
        v                                               |
   tray (survives navigation)                           |
        |                                               |
        | 4. Send                                       |
        v                                               |
   ~/.loupe/<app>/<session>/  ---------------------------
        bundle.json + one PNG per annotation
```

Both roles ship inside one macOS app, `LoupeDemo`, as two tabs. The Annotator tab is a fake
product screen with seeded rows that makes real requests to a local stub, so the captured trace is
genuine rather than mocked. The Agent tab is a bundle inbox that reads the folder and shows exactly
what an agent receives: the comment, the crop, the element reference, the trace. It ships with one
pre-seeded bundle so it is never empty.

## File map

```
Sources/LoupeCore/
  Annotation.swift          MODIFY  add `logs: [LogEvent]` to Annotation, add LogEvent
  LogRecorder.swift         NEW     ring buffer, same shape as NetworkRecorder
  QueuedTransport.swift     NEW     persist-then-drain decorator around any Transport

Sources/LoupeUI/
  LoupeTheme.swift          NEW     every token in DESIGN.md, as code. Light and dark.
  OverlayWindow.swift       NEW     NSPanel / UIWindow that hosts the SwiftUI overlay
  OverlayRoot.swift         NEW     the mode state machine: picking / commenting / browsing
  HighlightLayer.swift      NEW     the outline + numbered badge over the picked element
  CommentPopover.swift      NEW     text field, four tag chips, Save / Cancel
  TrayPanel.swift           NEW     the list, index badges, delete, Send
  Loupe.swift               MODIFY  beginAnnotating / endAnnotating, shortcut, pill

Sources/LoupeDemo/          NEW     macOS-only executable, two roles
  main.swift, AnnotatorScreen.swift, AgentInbox.swift, StubServer.swift, Seed.swift

Tests/LoupeCoreTests/       MODIFY  LogRecorder, QueuedTransport
Tests/LoupeUITests/         NEW     theme tokens, mode machine
```

## Phase order

1. **Core gaps.** `LogRecorder`, `LogEvent` on `Annotation`, `QueuedTransport`. All testable with
   no UI, so they land first and stay green.
2. **Theme.** `DESIGN.md` turned into `LoupeTheme`. Nothing visible depends on a raw value.
3. **Overlay.** Window, mode machine, highlight, comment popover, tray. In that order: each one is
   visible on its own.
4. **Demo.** Stub server, seeded annotator screen, agent inbox, `swift run LoupeDemo`.
5. **Verify.** `swift test`, an iOS build, and the demo run end to end with screenshots.

## What a cold agent gets wrong here

- `LoupeCore` must not import UIKit or AppKit. Ever. It is the half that stays testable.
- `URLProtocol` subclasses cannot name a property `task`; it clashes with the base class.
- `homeDirectoryForCurrentUser` does not exist on iOS. Anything filesystem-ish needs an
  `#if os(macOS)` split.
- The picker's meaningful-ancestor walk is the correctness core. A wrong crop makes every
  downstream step reason about the wrong element. Changes there need a test.


## What actually went wrong

Six bugs, every one of them found by running the thing rather than reading it. They are
listed because each is a place where the obvious code was wrong in a way review would not
have caught.

| Where | What | Why it mattered |
|---|---|---|
| `ElementPicker.isMeaningful` | In AppKit a static label is an `NSTextField`, which is an `NSControl`. Treating every `NSControl` as interactive stopped the climb on the label. | The crop would have shown the words instead of the card they sit in - the exact failure the walk exists to prevent. |
| `ElementPicker.boundsInWindow` | Bounds came back bottom-left on macOS and top-left everywhere else. | The bundle format promises one space. Every consumer would have had to know which OS wrote the bundle. |
| `OverlayHost` (iOS) | A force-cast of a metatype when the host window had no scene. | A crash, shipped. |
| `picker.labelOf`, `Overlay.isOurs` | `instanceof` on DOM types is false for an element inside an iframe: it is from another realm. | Silent wrong answers on any page with an embedded preview. |
| `Overlay.pickAt` | `elementFromPoint` retargets shadow content to its host, which is not meaningful, so the climb walked out of the overlay and returned `<html>`. | The crop was a picture of the entire page. |
| `TrayPanel` | The tray covered part of the app, and nothing under it could be picked. | The one thing the tool must never take away. Only visible once there was something under the tray worth annotating. |

The pattern is worth naming: **five of the six were in the seams between correct pieces**,
and none of them would have shown up in a unit test written against the piece alone. The
demo, the snapshots and the headless browser run are what found them, which is the argument
for the MVP bar being a click-through rather than a library.
