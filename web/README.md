# @loupe/web

**Point at your running web app. Say what is wrong. An agent gets everything it needs.**

The web and Electron half of [Loupe](https://github.com/serhii-kucherenko/loupe). Same
[bundle format](../docs/bundle-format.md) as the Swift SDK, same intake endpoint. Electron
comes free: its renderer is Chromium.

No runtime dependencies.

## Install

```sh
npm install @loupe/web
```

## Use

One call, in dev and staging builds only:

```ts
import { start } from "@loupe/web";

start({
  app: { name: "Acme", version: "1.4.0", commitSHA: __GIT_SHA__, platform: "web" },
  endpoint: "/loupe/intake",
});
```

After that **⌥⌘L** (Alt+Ctrl+L off a Mac) opens annotate mode. Point at something, say
what is wrong, point at something else, press Send. Nothing else in your app has to know
Loupe is there.

| Option | Default | What it does |
|---|---|---|
| `app` | — | Which build this is. `commitSHA` is the field an agent uses to check out the right code. |
| `endpoint` | `/loupe/intake` | Where bundles are POSTed. |
| `transport` | HTTP to `endpoint` | Anything with `send(bundle)`. |
| `headers` | `{}` | Sent with each POST, e.g. an auth token. |
| `captureConsole` | `false` | Capture `console.*` as well as unhandled errors. See below. |
| `captureScreenshots` | `true` | Draw the picked element into the bundle. |
| `screen` | `location.pathname` | What to call the current screen. |

## What it captures

- **The element you pointed at**, climbed to the one you *meant*. `elementFromPoint`
  returns the deepest node under the pointer, which is almost always a `<span>` inside
  the thing you were pointing at, so the picker climbs to the nearest element the app
  named or that a person can interact with.
- **A CSS selector** that finds it again, stopping as soon as it is unique. A fourteen-step
  `div > div > div` chain is not something anyone can act on.
- **The requests behind it.** `fetch` and `XMLHttpRequest` are both wrapped, because a
  trace that silently misses one reads as "the screen made no calls".
- **Errors**, and optionally your console.
- **A picture of the element**, when the browser allows one. See the limits below.

## Two decisions worth knowing about

**Console capture is off by default.** Console output carries whatever your app decided to
print, and quietly shipping all of it to an intake endpoint is not a decision an SDK gets
to make for its host. Unhandled errors are always captured; `console.*` needs
`captureConsole: true`.

**Screenshots are best-effort.** There is no browser API for "screenshot this element", so
Loupe uses the SVG `foreignObject` route. It returns nothing rather than something wrong
when: an image inside the element is cross-origin, a custom font is not same-origin, or
the content lives in a shadow root or an iframe. `screenshotPNG` is an optional field in
the format precisely so a missing picture degrades quality and never correctness.

## Offline

Every bundle is written to `localStorage` before the network is tried, and the tray itself
is written on every change. Closing a tab is not a deliberate act the way quitting an app
is, so a reload restores what you had typed, and anything undelivered goes out on the next
page load.

## Demo

```sh
npm install && npm run build
python3 -m http.server 8765
open http://127.0.0.1:8765/demo/index.html
```

A small stock admin with three things wrong with it on purpose, and an **Agent inbox** tab
showing exactly what came out the other side.

## Develop

```sh
npm test          # sync tokens, typecheck, then the suite, against the built output
npm run build
```

`docs/tokens.json` is `DESIGN.md` in machine-readable form. It is the one thing both this
SDK and the Swift one are tested against, so a token cannot come to mean two different
things on two platforms. Change `DESIGN.md`, change `docs/tokens.json`, then
`npm run sync-tokens`.

## Licence

MIT.
