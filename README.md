# Loupe

**Point at your running app. Say what is wrong. An agent gets everything it needs.**

Loupe is an annotation SDK you compile into the dev or staging build of your own app.
You enter annotate mode, pick an element, leave a comment, pick another, leave another.
Each pick is captured automatically: a picture of the exact element, the API calls that
screen just made, the errors, the build it came from. One **Send** ships the batch.

You never take a screenshot. You never write repro steps. You never fill in a ticket.

Apple platforms first: **macOS and iPad/iPhone**. Web and Electron are next.

## Why this exists

Handing an AI coding agent "the search feels wrong" gets you a guess. Handing it the
element you pointed at, a picture of it, and the exact request that fired behind it gets
you a fix. Loupe is the capture side of that.

## Related: Autopilot

**Loupe captures. [Autopilot](../../autopilot/repo) decides what to do about it.**

Loupe hands over a bundle and stops there. Autopilot is the loop on the other side: triage
into tickets, an agent that builds them, staging, and the review that closes it.

The seam between the two is the bundle format, and it is deliberate. Loupe only ever POSTs
to a URL you configure, with no opinion about issue trackers or agents, so you can adopt
the capture without adopting the loop. Autopilot can equally take input from anywhere else.

| | What it is | Where |
|---|---|---|
| **Loupe** | the annotation SDK, in your app | this repo · [Linear](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084) |
| **Autopilot** | the loop the bundles feed | `../../autopilot/repo` · [Linear](https://linear.app/serhii-kucherenko/project/autopilot-0e1846433181) |

Both came out of [SER-601](https://linear.app/serhii-kucherenko/issue/SER-601).

## Install

Not published yet, so point at the checkout:

```swift
.package(path: "../loupe")
```

Once it is on GitHub:

```swift
.package(url: "https://github.com/serhii-kucherenko/loupe", from: "0.1.0")
```

## Use

```swift
import LoupeCore
import LoupeUI

// once, at launch, in dev and staging builds only
Loupe.start(app: AppInfo(name: "Demo", version: "1.4.0", platform: "macOS"))

// each time the person picks an element and types a comment
Loupe.capture(at: point, in: window, comment: "stale results on top", tag: .bug)
Loupe.capture(at: otherPoint, in: window, comment: "empty state has no CTA", tag: .polish)

// ship the whole tray
try await Loupe.send()
```

By default bundles are written to `~/.loupe/<app-name>/`, so it works with no server to
run and an agent with filesystem access can read them directly. Point it somewhere else
with `HTTPTransport`.

## What a bundle contains

```
~/.loupe/Demo/<session-id>/
├── bundle.json          the annotations, elements, traces, build info
├── <annotation-id>.png  the element, cropped
└── <annotation-id>.png
```

Each annotation carries your comment, the element reference (accessibility id, label,
class, on-screen bounds), the recent network events, and which screen you were on.

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

Early. The core, the recorder, the transports, and the picker work and are tested. The
on-screen overlay and the tray UI are the next piece. See the
[Linear project](https://linear.app/serhii-kucherenko/project/loupe-8fd34fb80084).

## Licence

MIT. See [LICENSE](LICENSE).
