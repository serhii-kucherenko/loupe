# The annotate overlay - design and build order

The ordered task list lives in the [Linear project](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084).
This file is the *how*: the decisions behind the overlay, the file map, and the phase order.
It is not a task list. See `AGENTS.md`.

## Where the product stands

Written and tested: the annotation model, the tray (`AnnotationSession`), the network ring
buffer, both transports, and the element picker. 745 lines, 8 tests, CI green on macOS and iOS.

Not written: **all of the UI**. There is no way for a person to point at anything. `Loupe.capture`
takes a `CGPoint` the host app has to supply itself, which means today Loupe is a library with no
product on top of it.

## Decisions

Decided from the code and from `DESIGN.md`, without an interview.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | SwiftUI or AppKit/UIKit for the overlay? | Native window (`NSPanel` / `UIWindow`), SwiftUI content inside it | The window has to layer above someone else's app, which is a native concern. The panels are ordinary layout, and `DESIGN.md` already names SwiftUI type styles. |
| 2 | How is annotate mode entered? | `Loupe.beginAnnotating()`, plus a default `⌥⌘L` on macOS and a floating pill on iOS/iPadOS | The host app must be able to drive it. A default gesture means adopting Loupe needs no UI work from the host. |
| 3 | Does the overlay swallow the host app's input? | Only while *picking*. After a comment is committed it drops to *browsing* and passes clicks through | You have to be able to navigate the app to annotate a second screen. `AnnotationSession` already assumes the tray outlives navigation. |
| 4 | Log capture - in or out? | In. A `LogRecorder` ring buffer shaped exactly like `NetworkRecorder`, fed by a public append API | The README already promises "the errors" in a bundle. Intercepting `os_log` or `stderr` is invasive and fragile; a one-line call from the host's own logger costs us nothing. |
| 5 | Offline queue - in or out? | In, as a `QueuedTransport` decorator that persists first and drains after | `HTTPTransport` throwing is survivable today only because the tray keeps the annotations. Killing the app loses them. |
| 6 | Web SDK - in or out? | Out of this cycle | A second implementation in another language. Finishing Apple platforms beats half-finishing both. Next phase. |
| 7 | Full-screen context shot beside the tight crop? | Out, for now | There is an existing `ponytail:` deferral on this and still no evidence the agent needs it. The Agent role in the demo is what will produce that evidence. |
| 8 | One demo app or two? | One app, two roles | The MVP bar wants a multi-role click-through. Two binaries would double the seams for no gain. |
| 9 | Tag picker shape? | Four chips | `DESIGN.md` already reserves `radius.control` for "buttons, tag chips". |

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
