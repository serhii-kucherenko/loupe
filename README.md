# Loupe

**Point at your running app. Say what is wrong. An agent gets everything it needs.**

Loupe is an annotation SDK you compile into the dev or staging build of your own app.
You enter annotate mode, pick an element, leave a comment, pick another, leave another.
Each pick is captured automatically: a picture of the exact element, the API calls that
screen just made, the errors, the build it came from. One **Send** ships the batch.

You never take a screenshot. You never write repro steps. You never fill in a ticket.

**macOS, iPad, iPhone, the browser, and Electron.** Two SDKs, one bundle format.

![The comment popover on macOS](docs/screenshots/02-comment-light.png)

## Why this exists

Handing an AI coding agent "the search feels wrong" gets you a guess. Handing it the
element you pointed at, a picture of it, and the exact request that fired behind it gets
you a fix. Loupe is the capture side of that.

## Related: Autopilot

**Loupe captures. [Autopilot](https://github.com/serhii-kucherenko/autopilot) decides what to do about it.**

Loupe hands over a bundle and stops there. Autopilot is the loop on the other side: triage
into tickets, an agent that builds them, staging, and the review that closes it.

The seam between the two is the bundle format, and it is deliberate. Loupe only ever POSTs
to a URL you configure, with no opinion about issue trackers or agents, so you can adopt
the capture without adopting the loop. Autopilot can equally take input from anywhere else.

| | What it is | Where |
|---|---|---|
| **Loupe** | the annotation SDK, in your app | this repo · [Linear](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084) |
| **Autopilot** | the loop the bundles feed | https://github.com/serhii-kucherenko/autopilot · [Linear](https://linear.app/serhii-kucherenko/project/autopilot-0e1846433181) |

Both came out of [SER-601](https://linear.app/serhii-kucherenko/issue/SER-601).

## Install

### Apple platforms

Swift Package Manager:

```swift
.package(url: "https://github.com/serhii-kucherenko/loupe", from: "0.1.0")
```

Pre-1.0 on purpose: the bundle format is settled, but the SDK API has not yet been used
by an app other than the demo, so the shape may still move.

Then add the products you need. `LoupeCore` alone is enough to read or write bundles;
`LoupeUI` brings in the picker and the platform code.

```swift
.product(name: "LoupeCore", package: "loupe"),
.product(name: "LoupeUI", package: "loupe"),
```

Requires Swift 5.9, macOS 13, or iOS 16.

### Web and Electron

```sh
npm install loupe-web
```

[![npm](https://img.shields.io/npm/v/loupe-web)](https://www.npmjs.com/package/loupe-web)
No runtime dependencies. See [`web/README.md`](web/README.md). Electron comes free: its
renderer is Chromium.

## Use

Two calls at launch, in dev and staging builds only. The overlay does the rest.

```swift
import LoupeCore
import LoupeUI

Loupe.start(app: AppInfo(name: "Demo", version: "1.4.0", platform: "macOS"))
Loupe.attach(to: window)
```

Then **⌥⌘L** on macOS, or the floating pill on iPhone and iPad, opens annotate mode.
Point at something, say what is wrong, point at something else, press Send.

On the web it is one call:

```ts
import { start } from "loupe-web";
start({ app: { name: "Demo", platform: "web" }, endpoint: "/loupe/intake" });
```

Driving it yourself instead of using the overlay:

```swift
Loupe.capture(at: point, in: window, comment: "stale results on top", tag: .bug)
try await Loupe.send()
```

By default bundles are written to `~/.loupe/<app-name>/` on macOS, so it works with no server
to run and an agent with filesystem access can read them directly. On a device use
`HTTPTransport`, since nothing outside the app sandbox can read its files.

## What a bundle contains

```
~/.loupe/Demo/<session-id>/
├── bundle.json                  the annotations, elements, traces, build info
├── <annotation-id>.png          the element, cropped
├── <annotation-id>-context.png  the whole window, element outlined
└── <annotation-id>.png
```

Two pictures, because they answer different questions: the crop says *what is this
element*, the context shot says *where is it and what is around it*. A layout complaint
needs the second, and one padded image half-answers both.

Each annotation carries your comment, the element reference (accessibility id, label,
class, CSS selector on the web, on-screen bounds), the recent network events, any error
logs, and which screen you were on. The whole contract is written down in
[`docs/bundle-format.md`](docs/bundle-format.md) - you can write a consumer in any
language from that page alone.

## What it looks like

| | |
|---|---|
| ![Hovering](docs/screenshots/01-hover-light.png) | ![The tray](docs/screenshots/03-tray-dark.png) |
| Point at something. The highlight climbs to the element you *meant*. | Several screens, one tray. Every note carries the endpoint behind it. |

The same thing on the web, in Chromium:

![The web overlay](docs/screenshots/04-web-comment.png)

Every colour, size and duration comes from [`DESIGN.md`](DESIGN.md), through
[`docs/tokens.json`](docs/tokens.json), which both SDKs are tested against.

## Try it

A seeded demo app with two roles - annotate it, then read what an agent receives.

```sh
# macOS
cd Examples/LoupeDemo && swift run LoupeDemo

# web
cd web && npm install && npm run build && python3 -m http.server 8765
# then open http://127.0.0.1:8765/demo/index.html
```

Both are a small stock admin with three things wrong with them on purpose, making real
network calls so the captured trace is genuine rather than mocked.

## How it works

Two pieces, and only one of them is hard.

**The picker.** Hit-testing returns the deepest view under your finger, which is usually
a label inside the thing you meant. Loupe climbs to the nearest *meaningful* ancestor,
one the app has named or one that is an interactive control, and stops before it swallows
a whole container. Then it renders that view directly, so the crop needs no rectangle
maths. Getting this right is the whole correctness burden: a wrong crop makes every
downstream step reason about the wrong element.

**The recorder.** A ring buffer of recent requests, installed as a `URLProtocol`. This is
the linkage that ties a UI element to backend code, instead of leaving an agent to guess
which endpoint a screen calls.

## Status

Pre-1.0, and working end to end on every platform it claims: the picker, the recorders,
the transports, the offline queue, the overlay, the tray, and a seeded two-role demo on
both macOS and the web. Not yet run on real iPad hardware.

The [bundle format](docs/bundle-format.md) is version 1 and has a
[JSON Schema](docs/bundle-format.schema.json). Adding a field is safe; renaming or
removing one is not.

See the [Linear project](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084).

## Licence

MIT. See [LICENSE](LICENSE).
