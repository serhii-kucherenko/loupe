# Installing Loupe, for an agent

**This page is written for a coding agent, not for a person.** Point your agent at it and
it can wire Loupe into a project without further instruction.

Paste this at your agent:

> Install Loupe into this project by following
> https://raw.githubusercontent.com/serhii-kucherenko/loupe/main/docs/agent-install.md
> Do not skip the verification section.

---

## What you are installing

Loupe is an annotation SDK for the **dev or staging build** of an app. A person enters
annotate mode, points at an element, and types what is wrong. Each pick captures the
element, a picture of it, the API calls that screen just made, the errors, and the build
it came from. One **Send** writes a bundle.

**You are the consumer.** Once it is installed, the person stops writing repro steps and
you start reading bundles.

## The one rule

**Never ship Loupe to production users.** It draws an overlay over the app and records
network activity. Every snippet below is guarded; keep the guard.

If the project has no notion of environment, add one rather than dropping the guard.

---

## Step 1 — which half

| The app is | Use |
|---|---|
| a website, a web app, a Chrome extension page, or **Electron** | [Web](#web) |
| macOS, iPad or iPhone, native Swift | [Apple](#apple) |
| React Native | Neither yet. Say so and stop; do not improvise. |

An Electron app uses the **web** half in its renderer. Its renderer is Chromium.

---

## Web

### 1. Install

```sh
npm install loupe-web
```

No runtime dependencies. Requires a browser or an Electron renderer; it does nothing in Node.

### 2. Start it, guarded

Call `start` exactly once, as early as the app has a DOM. Find the project's real entry
point rather than creating a new one.

```ts
// Vite / plain bundlers: src/main.ts, src/index.tsx, wherever the app boots.
if (import.meta.env.DEV || import.meta.env.MODE === "staging") {
  const { start } = await import("loupe-web");
  start({
    app: {
      name: "<the project's name>",
      version: __APP_VERSION__,       // if the project has one; otherwise omit
      commitSHA: __GIT_SHA__,         // see "Wire the commit SHA" below
      platform: "web",
      environment: "staging",
    },
    endpoint: "/loupe/intake",
  });
}
```

Next.js App Router, as a client component rendered once in the root layout:

```tsx
// app/loupe.tsx
"use client";
import { useEffect } from "react";

export function Loupe() {
  useEffect(() => {
    if (process.env.NODE_ENV === "production") return;
    void import("loupe-web").then(({ start }) =>
      start({
        app: { name: "<project>", commitSHA: process.env.NEXT_PUBLIC_GIT_SHA,
               platform: "web", environment: "staging" },
        endpoint: "/loupe/intake",
      }));
  }, []);
  return null;
}
```

The dynamic `import()` matters: it keeps Loupe out of the production bundle entirely.

Electron is the same, in the renderer entry point. Use `platform: "electron"`.

### 3. Give it somewhere to send to

`endpoint` is a URL you own. **Point it at the repository you are working in**, so a bundle
lands as files you can read.

Next.js App Router — `app/loupe/intake/route.ts`:

```ts
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Dev and staging only. This writes to the repository.
export async function POST(request: Request) {
  if (process.env.NODE_ENV === "production") return new Response(null, { status: 404 });

  const bundle = await request.json();
  const folder = join(process.cwd(), ".loupe", bundle.sessionID);
  await mkdir(folder, { recursive: true });

  // Screenshots go beside the JSON rather than inside it, so the JSON stays readable
  // and an agent can open the images directly. Same shape the Swift SDK writes.
  for (const annotation of bundle.annotations ?? []) {
    for (const [field, suffix] of [["screenshotPNG", ""], ["contextScreenshotPNG", "-context"]]) {
      const data = annotation[field];
      if (!data) continue;
      await writeFile(join(folder, `${annotation.id}${suffix}.png`), Buffer.from(data, "base64"));
      delete annotation[field];
    }
  }

  await writeFile(join(folder, "bundle.json"), JSON.stringify(bundle, null, 2));
  return new Response(null, { status: 204 });
}
```

Express or any Node server — the same body, mounted at `POST /loupe/intake`.

Then add `.loupe/` to `.gitignore`. Bundles are working notes, not source.

**If the project has no server at all** (a static site), say so and use the local transport
instead of an endpoint, then read the bundles from the browser's storage:

```ts
start({
  app: { name: "<project>", platform: "web" },
  transport: {
    async send(bundle) {
      const all = JSON.parse(localStorage.getItem("loupe:inbox") ?? "[]");
      all.unshift(bundle);
      localStorage.setItem("loupe:inbox", JSON.stringify(all.slice(0, 20)));
    },
  },
});
```

Tell the person they will need to paste the contents of `localStorage["loupe:inbox"]` to
you, because you cannot read their browser.

### 4. Wire the commit SHA

`commitSHA` is the single most useful field in a bundle: it is how you check out the code
that produced the screenshot. Set it from the build.

Vite — in `vite.config.ts`:

```ts
import { execSync } from "node:child_process";
export default defineConfig({
  define: {
    __GIT_SHA__: JSON.stringify(execSync("git rev-parse --short HEAD").toString().trim()),
  },
});
```

Next.js — set `NEXT_PUBLIC_GIT_SHA` in the build environment. If neither is possible, omit
the field rather than inventing a value.

---

## Apple

### 1. Add the package

`Package.swift`:

```swift
.package(url: "https://github.com/serhii-kucherenko/loupe", from: "0.1.2"),
```

```swift
.product(name: "LoupeCore", package: "loupe"),
.product(name: "LoupeUI", package: "loupe"),
```

In Xcode: **File → Add Package Dependencies**, the same URL. Requires Swift 5.9, macOS 13 or
iOS 16.

### 2. Start and attach, guarded

Two calls. `start` installs the recorder; `attach` puts the overlay above a window, and is
separate because a window rarely exists yet when an app wants to start recording.

```swift
import LoupeCore
import LoupeUI

#if DEBUG
Loupe.start(app: AppInfo(
    name: "<project>",
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    commitSHA: "<injected at build time>",
    platform: "macOS",          // or "iOS" / "iPadOS"
    environment: "staging"))
#endif
```

Then, once there is a window:

```swift
#if DEBUG
Loupe.attach(to: window)
#endif
```

- **AppKit:** in `applicationDidFinishLaunching`, or from a `NSViewRepresentable` that
  reports `view.window` for a SwiftUI app.
- **UIKit:** in `scene(_:willConnectTo:options:)`, passing the scene's window.

**Do not** put `Loupe.attach` somewhere that runs more than once.

### 3. Where bundles land

By default `~/.loupe/<app name>/` on a Mac, Catalyst included - nothing to run, and you
can read it directly. A **sandboxed** app cannot write there and gets
`Application Support/Loupe/<app name>/` in its container instead. Check which one you
have before concluding nothing was captured.

On a device the app is sandboxed, so no file outside it is readable. Use `HTTPTransport`
there and point it at something you can read:

```swift
Loupe.start(app: app, transport: QueuedTransport(
    wrapping: HTTPTransport(endpoint: URL(string: "http://<your machine>:3000/loupe/intake")!),
    directory: FileTransport.defaultDirectory(appName: app.name)))
```

`QueuedTransport` persists every bundle before it tries the network, so annotating on a
train and sending later works.

### 4. How the person opens it

- **macOS:** ⌥⌘L.
- **iPhone and iPad:** a floating pill appears in dev builds. To use a shake instead, call
  `Loupe.handleShake()` from your own `motionEnded`.

---

## How you read what the person sent

One folder per Send:

```
.loupe/<sessionID>/                (web, via the intake route)
~/.loupe/<app name>/<sessionID>/   (a Mac app that is not sandboxed, by default)
├── bundle.json
├── <annotation-id>.png            the element, cropped
└── <annotation-id>-context.png    the whole window, element outlined
```

Newest first:

```sh
ls -t .loupe/*/bundle.json | head -1
```

What to do with one, in order:

1. **Read the comment.** It is the only human-authored field. Everything else is context.
2. **Look at both PNGs.** The crop says *what* the element is; the context shot says where
   it sits. A layout complaint needs the second.
3. **Find the element in source** by `element.accessibilityID`, then `element.selector`,
   then `element.label`. Those are the app's own names for it.
4. **Read `trace`.** These are the requests that fired just before the pick, and they are
   what ties the element to backend code. A non-2xx here is usually the bug.
5. **Read `logs`.** Errors are kept preferentially over debug noise.
6. **Check out `app.commitSHA`** before reasoning about the code.

Every field is documented in [`bundle-format.md`](bundle-format.md), with a JSON Schema
beside it. **Fields are best-effort except `comment`, `element.bounds` and `capturedAt`** —
a web bundle often has no picture at all, because a cross-origin image taints the canvas.
A missing field degrades quality, never correctness.

---

## Verification — do not report this installed until all of it passes

1. **It builds.** Run the project's own build and test commands.
2. **No Loupe code runs in production.** What you can check differs by platform, and
   the difference is real rather than a technicality.

   **Web.** The dynamic `import()` genuinely keeps it out of the bundle, so grep and
   expect nothing:
   ```sh
   grep -r "loupe" dist/ build/ .next/ 2>/dev/null | grep -v ".map" | head
   ```
   Any hit means the guard is wrong. Fix it before continuing.

   **Apple.** Do **not** grep the binary. Xcode links a Swift package product whole
   rather than pulling in only what is referenced, so the symbols are present in a
   Release build even when every call site is behind `#if DEBUG` and nothing can
   reach them. Measured in a real app: 782 Loupe symbols in a Release build whose
   guard was correct. An agent that greps here will fail a gate it cannot pass and
   then go hunting for a mistake it did not make.

   Check reachability instead, which is what actually matters:
   ```sh
   grep -rn "Loupe\." --include="*.swift" . | grep -v "#if DEBUG" | head
   ```
   Every call site must sit inside a `#if DEBUG` (or your own staging flag). No
   `Loupe.start`, no `Loupe.attach`, no `NetworkRecorder.install()` outside one.
   Nothing observes anything, no window is created, and no behaviour ships.

   To remove the symbols too, the host needs a build configuration or target that
   omits the package dependency entirely. Say so rather than pretending the guard
   does it.

   One trap while checking: a Debug build puts the app's own code in
   `<App>.debug.dylib`, so grepping the main binary of a Debug build finds nothing
   and looks like the opposite result.
3. **The overlay opens.** Run the app, press ⌥⌘L (or tap the pill). A bar reading
   "Point at something that looks wrong." must appear.
4. **A pick lands on the right element.** Point at something with text inside it, like a
   row or a card. The highlight must outline the **whole row**, not the words inside it.
   If it outlines the text, the element needs a `data-testid` or an
   `accessibilityIdentifier`.
5. **A round trip works.** Type a comment, press Send, then confirm a folder appeared and
   read it back:
   ```sh
   cat "$(ls -t .loupe/*/bundle.json | head -1)"
   ```
   It must contain your comment and a non-empty `trace`.
6. **Tell the person the two things they need to know:** the shortcut, and where bundles
   land.

If step 5 produces an empty `trace` on a screen that definitely makes requests, the app is
making them through something Loupe did not wrap. Say so rather than ignoring it.

---

## What goes wrong

| Symptom | Cause |
|---|---|
| The highlight outlines the text, not the row | Nothing named the row. Add `data-testid` (web) or `accessibilityIdentifier` (Apple) to the container. |
| No overlay at all | `start` never ran, or it ran before the DOM existed. Check the console. |
| The tray covers something you want to pick | It only covers while browsing. Press "Pick another" and it collapses to one line. |
| `trace` is empty | The app uses a transport Loupe did not wrap, or the requests fired more than 30 seconds before the pick. |
| No picture in a web bundle | Expected. A cross-origin image, a non-same-origin font, or shadow DOM content will all defeat the capture. The element reference and the trace still carry the annotation. |
| Nothing arrives at the intake | Check the endpoint path matches, and that the route is not guarded off in the mode you are running. |
| Nothing in `~/.loupe/` on a Mac | The app is sandboxed, so it cannot write there. Look in `Application Support/Loupe/<app name>/` inside its container. Mac Catalyst used to land there even unsandboxed; that was fixed after 0.1.1. |
| SwiftPM refuses to resolve Loupe, naming a revision that "does not match previously recorded value" | The `v0.1.0` tag was moved once, before anyone depended on it, and SwiftPM remembers the commit a tag pointed at the first time it saw one. No clean or cache reset clears it. Delete `~/Library/org.swift.swiftpm/security/fingerprints/loupe-*.json` and resolve again. No tag will be moved again. |
| The picked element has no name, only bounds | Expected on iOS under SwiftUI, which draws headings, stacks and backgrounds into one shared layer with no view or accessible name behind them. That is a region pick: the crop and the context shot carry the meaning. Name the element (`accessibilityIdentifier`) and it will be resolved on every other platform. |
