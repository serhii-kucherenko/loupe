# The Loupe bundle format, version 1

A **bundle** is what one *Send* produces: every annotation in the tray, plus the build
they came from. It is the only contract between a Loupe SDK and anything that reads its
output, so it is written down here rather than left implied by the Swift types.

You should be able to write a consumer in any language from this page alone.

- Machine-readable schema: [`bundle-format.schema.json`](bundle-format.schema.json)
- Worked example: [`bundle-format.example.json`](bundle-format.example.json)

## The compatibility rule

| Change | Allowed? | Bumps `formatVersion`? |
|---|---|---|
| Add a field | yes | no |
| Add a value to an open enum (`platform`, `subsystem`) | yes | no |
| Add a value to a closed enum (`tag`, `level`) | yes, consumers must tolerate unknown values | no |
| Rename a field | no | n/a - do not |
| Remove a field | no | n/a - do not |
| Change a field's type or meaning | breaking | yes |

Two consequences, and both are load-bearing:

1. **A reader must ignore fields it does not know.** Every object in the schema sets
   `additionalProperties: true` on purpose.
2. **A reader must tolerate a missing optional field**, including one this page lists.
   Only the `required` fields in the schema are guaranteed.

A bundle with no `formatVersion` at all is version 1. That is the only special case.

## Where a bundle lives

Two transports, two shapes. Same JSON either way.

**On disk** (`FileTransport`, the default on macOS):

```
~/.loupe/<app-name>/<sessionID>/          # a Mac app that is not sandboxed
├── bundle.json
├── <annotation-id>.png             the element, cropped
├── <annotation-id>-context.png     the whole window, element outlined
└── <annotation-id>.png
```

Screenshots sit *beside* the JSON, not inside it, so the JSON stays readable and an
agent can open the images directly. `screenshotPNG` is absent in this shape.

**Over HTTP** (`HTTPTransport`): one `POST` of the whole JSON, `Content-Type:
application/json`. Here `screenshotPNG` **is** present, base64-encoded, because there is
no folder to put it in.

An agent reading a bundle must handle both: *if `screenshotPNG` is present use it,
otherwise look for `<id>.png` next to the JSON.* Same rule for the context shot and
`<id>-context.png`.

**Two pictures, two questions.** The crop answers *what is this element*; the context shot
answers *where is it and what is around it*. A layout complaint needs the second, and a
single padded image half-answers both. Either may be absent.

## Fields

### Bundle

| Field | Type | Guaranteed | Meaning |
|---|---|---|---|
| `formatVersion` | integer | yes | `1`. Absent means 1. |
| `sessionID` | UUID string | yes | One tray, one id. Survives an app restart, so an intake can treat a re-upload as the same bundle. |
| `sentAt` | ISO-8601 | yes | When Send was pressed, not when it arrived. |
| `app` | object | yes | Which build produced this. |
| `annotations` | array | yes | In the order they were captured. May be empty only in a test fixture; a real Send refuses an empty tray. |

### `app`

| Field | Type | Guaranteed | Meaning |
|---|---|---|---|
| `name` | string | yes | Also the folder name on disk. |
| `version` | string | no | Marketing version, e.g. `1.4.0`. |
| `commitSHA` | string | no | **The most useful field on this object.** It is how an agent checks out the code that produced the screenshot. |
| `platform` | string | yes | `macOS`, `iOS`, `iPadOS`, `web`, `electron`. Open set: treat an unknown value as a string, not an error. |
| `environment` | string | no | Defaults to `staging`. Loupe is not meant to ship to production users. |
| `device` | object | no | Which machine and which screen. Filled in by the SDK; a host never passes it. |

#### `app.device`

| Field | Type | Guaranteed | Meaning |
|---|---|---|---|
| `identifier` | string | no | Model identifier, `iPad8,3`. Apple platforms only. The precise field: a reader can look it up. |
| `name` | string | no | Marketing name, `iPad Pro 11-inch`. From an exact-match table. |
| `osVersion` | string | no | The point release only, `26.5`. The platform's own name is already `app.platform`, so it is not repeated - one value, one place. |
| `screen` | object | no | `width`, `height` in points and `scale`. **The whole screen**, not the window. |

**An absent `name` means Loupe has not been taught that model, never that the model is
unknown** - `identifier` says exactly what the machine was. Loupe will not guess a name
from a prefix: a wrong device in a bug report sends somebody to reproduce a layout bug
on hardware that is not the hardware, which is worse than a blank field.

**`screen` and `viewport` are different things, and the gap between them is the point.**
`app.device.screen` is the display; `annotations[].viewport` is the window the app had.
When the viewport is smaller, the app was in Split View, Slide Over, or a resized
window - which explains a whole class of "it looks wrong" reports and is completely
invisible in a screenshot cropped to the app. `LoupeLinear` says so in a sentence on the
issue rather than leaving a reader to notice two numbers disagree; if you write your own
consumer, do the same.

On the web only `screen` is present. The browser has no non-identifying way to say which
machine it is on, and parsing a user agent for it would be guessing and fingerprinting at
the same time.

### `annotations[]`

| Field | Type | Guaranteed | Meaning |
|---|---|---|---|
| `id` | UUID string | yes | Also the screenshot filename on disk. |
| `comment` | string | yes | What the person typed. The only human-authored field in the bundle. |
| `tag` | enum | no | `bug`, `idea`, `polish`, `question`. A hint for triage, not the final word. |
| `element` | object | yes | Where it points. |
| `screenshotPNG` | base64 | no | The element, cropped. Present over HTTP, absent on disk. See above. |
| `contextScreenshotPNG` | base64 | no | The whole window with the element outlined. Answers "where is it and what is around it", which the tight crop deliberately does not. Apple platforms only; the web SDK cannot take one. |
| `trace` | array | no | Requests that fired shortly before the pick. Absent means none were recorded, never that none happened. |
| `logs` | array | no | Log lines from shortly before the pick. Errors are kept preferentially over debug chatter. |
| `screen` | string | no | Route, screen name or tab, e.g. `/search`. |
| `viewport` | rect | no | The window or viewport at capture time. **`element.bounds` is expressed inside this**, so without it you cannot tell a phone from a desktop. |
| `capturedAt` | ISO-8601 | yes | When this pick happened. Earlier than `sentAt`, often by minutes. |

### `element`

Everything but `bounds` is best-effort. The crop and the trace carry the meaning, so a
missing field degrades quality, never correctness.

| Field | Type | Meaning |
|---|---|---|
| `kind` | `"view"` \| `"region"` | What the annotation points at. Absent means `view`. |
| `accessibilityID` | string | What the app named the element. The strongest signal for finding it in source. |
| `label` | string | Visible text or accessibility label. |
| `className` | string | Runtime type, e.g. `ResultsCollectionView` or `div`. |
| `selector` | string | CSS selector. **Web and Electron only**; Apple SDKs leave it out. |
| `sourceFile` / `sourceLine` | string / integer | Only when the host opted in at the call site. |
| `bounds` | rect | On-screen position, in `viewport` coordinates. |

A rect is `{ "x", "y", "width", "height" }`, all numbers, origin top-left.

**A `kind` of `"region"` means the person drew a rectangle, or the framework could
resolve nothing.** Both are ordinary, and neither is a failure.

Drag-select is a first-class gesture: plenty of real feedback is about something no
view corresponds to - two controls misaligned with each other, the padding around a
group, the gap between two rows. A region says "this area", and `bounds` is the whole
of what it can say.

The same kind is used when a point cannot be resolved. Some UI frameworks do not back
what you see with anything a picker can reach - SwiftUI on iOS draws headings, stacks
and backgrounds into one shared layer, so a point over a heading is indistinguishable
from a point over blank space. Rather than drop the note, the SDK captures a box
around the point.

**Web content inside a native app is the strongest case of this, and it is not a
bug.** A `WKWebView` is one `UIView` to a native picker; the paragraphs, buttons and
links inside it are the web engine's, and no amount of climbing reaches them. So a
tap inside a reader, a help page or an embedded checkout comes back as a region with
an empty `className` and no `label` - a picture, a rectangle, and nothing else.

Read an empty `className` as *there was nothing to name*, never as a failed capture.
The crop and the context shot are still correct and still show what the person was
looking at. If you need element identity inside web content, the web SDK running
*inside* that page is the thing that can give it to you; a native picker cannot.

Either way: read `bounds`, and let the crop and the context shot carry the rest.

### `trace[]`

| Field | Type | Meaning |
|---|---|---|
| `method` | string | `GET`, `POST`, … |
| `url` | string | Full URL, query string included. |
| `statusCode` | integer or null | Null means the request never completed. |
| `durationMs` | integer | |
| `at` | ISO-8601 | When the request *started*. |

Only the last ~30 seconds before a pick are included, and only the last 200 requests are
kept in memory at all. A quiet `trace` on a busy screen means the window was too short,
not that the screen made no calls.

### `logs[]`

| Field | Type | Meaning |
|---|---|---|
| `level` | enum | `debug`, `info`, `warning`, `error`. Treat an unknown value as `info`. |
| `message` | string | |
| `subsystem` | string | Free-form, e.g. `search`, `auth`. |
| `at` | ISO-8601 | |

Logs are whatever the host app chose to hand Loupe. Loupe never intercepts `os_log`,
`stderr` or `console` on its own: that is invasive and fragile, and it would put strings
the host never meant to share into a bundle.

## Reading one, in any language

```python
import json, pathlib

folder = pathlib.Path("~/.loupe/Acme Store/6F9619FF-...").expanduser()
bundle = json.loads((folder / "bundle.json").read_text())

assert bundle.get("formatVersion", 1) == 1

for a in bundle["annotations"]:
    png = folder / f"{a['id']}.png"          # on-disk shape
    print(a["comment"], a["element"].get("accessibilityID"), a.get("screen"))
    for call in a.get("trace", []):
        if call.get("statusCode", 200) >= 400:
            print("  failed:", call["method"], call["url"], call["statusCode"])
```

## What this format deliberately does not carry

- **No user identity.** No account id, no email, no device id. A bundle is about a build,
  not a person. `app.device` says which *model* the note came from, never whose device it
  was: no name somebody chose for their iPad, no `identifierForVendor`, no advertising
  identifier, no user agent, no locale, no timezone. This one is enforced rather than
  intended - `scripts/check-nothing-identifying.py` fails Loupe's build on the APIs that
  would break it, because every one of them is one autocomplete away from an API Loupe
  legitimately uses and produces a bundle that looks completely normal.
- **No request or response bodies.** Only method, URL, status and duration. Bodies are
  where secrets live, and a URL is enough to find the endpoint in source.
- **No full page source.** The element reference plus a crop, not a DOM dump.
- **No video.** Stills only.
- **No picture at all, sometimes.** Both image fields are optional. The web SDK often
  cannot take one (a cross-origin image taints the canvas), and it carries the element
  reference and the trace instead. Missing pictures degrade quality, never correctness.

If you need any of that, it belongs in your own intake service, added on top - not in the
format everybody else has to trust.

## What a bundle *does* carry, and why it decides where you run this

The list above is about fields. The pictures are the other half, and they are not
filtered: **a screenshot is whatever was on screen.** If the app was showing a real
customer's name, that name is now in the bundle, and the bundle is on its way to a
ticket somebody will paste into a pull request.

That is not a bug to fix - a capture tool that redacted the screen would be useless -
but it does decide where Loupe belongs:

- **Run it against seeded or synthetic data.** A staging app pointed at a scrubbed
  database is the case Loupe was built for.
- **Staging pointed at production data is a decision, not a default.** If you do it,
  the people annotating need to know that what is on screen is what gets filed.
- **Never in a build a real user can reach.** Loupe is DEBUG-only for this reason among
  others, and `docs/agent-install.md` makes "no Loupe code runs in production" a gate.

The `trace` is filtered on purpose - method, URL, status and duration, never bodies,
because bodies are where tokens live. The pictures cannot be.
