# loupe-web

**Point at your running web app. Say what is wrong. An agent gets everything it needs.**

The web and Electron half of [Loupe](https://github.com/serhii-kucherenko/loupe). Same
[bundle format](../docs/bundle-format.md) as the Swift SDK, same intake endpoint. Electron
comes free: its renderer is Chromium.

No runtime dependencies.

## Install

```sh
npm install loupe-web
```

[![npm](https://img.shields.io/npm/v/loupe-web)](https://www.npmjs.com/package/loupe-web)

## Use

One call, in dev and staging builds only:

```ts
import { start } from "loupe-web";

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
| `theme` | Loupe's own look | Your design tokens. See below. |

### It can wear your design system

Loupe's own look is a warm orange, on purpose: an overlay has to read as a tool, not
as part of the page underneath it. But a page with an accent of its own gets to say
so, and then the overlay stops looking like a visitor:

```ts
start({
  app,
  theme: {
    accent: "var(--brand)",
    panelRadius: 28,
    fontFamily: "Inter, system-ui, sans-serif",
  },
});
```

Colours are any CSS colour - a hex, `oklch(...)`, or `var(--brand)` to point straight
at a variable your page already has, so the value is never written down twice. One
string means both schemes; `{ light, dark }` says them separately. The wash inside a
picked element follows your accent without being asked.

**The overlay lives in a shadow root, so your stylesheet cannot reach in.** That is
deliberate - a global `* { box-sizing }` reset would otherwise reshape the tool
sitting on your page - and it is why this option exists at all.

**It is not a styling API.** Colours, three radii and a font stack. Sizes stay
Loupe's, because they are hit targets as much as type. `DESIGN.md` lists every token,
and the Swift SDK takes the same tokens by the same names.

## Where bundles go

This SDK POSTs to an endpoint you run. **It cannot deliver into Linear directly, and
that is Linear's doing rather than a gap here:** Linear's Content Security Policy
blocks the signed upload `PUT` from browser JavaScript, so a page can create the issue
but cannot attach the screenshots - and an issue without the picture is most of the
value gone.

So the web shape is: page → your intake endpoint → wherever you want it. Your service
files into Linear server-side, where no CSP applies. The Apple SDKs can talk to Linear
directly, which is why `LoupeLinear` exists there and not here.

**If you just want somewhere for bundles to land right now**, this package ships a
receiver so that is one command rather than a snippet you have to wire in first:

```sh
npx loupe-intake                  # http://127.0.0.1:7423/loupe/intake
npx loupe-intake --host 0.0.0.0   # so an iPad on the same network can reach it
```

It writes `.loupe/<sessionID>/bundle.json` with the screenshots beside it as PNGs -
the same shape the Swift SDK writes on disk, so anything that reads one reads the
other. Add `.loupe/` to `.gitignore`.

It is deliberately not a framework: no auth, no queue, no delivery. It refuses to
start with `NODE_ENV=production`, and it says so on the console when you point it at
`0.0.0.0`, because it has no authentication at all. For anything beyond reading
bundles on your own machine, put your own service in front. `docs/agent-install.md`
has a handler for Next.js and Express if you would rather mount it in the app you
already run.

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
