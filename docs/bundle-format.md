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
| `kind` | `"view"` \| `"region"` \| `"path"` | What the annotation points at. Absent means `view`. |
| `accessibilityID` | string | What the app named the element. The strongest signal for finding it in source. |
| `label` | string | Visible text or accessibility label. |
| `className` | string | Runtime type, e.g. `ResultsCollectionView` or `div`. |
| `selector` | string | CSS selector. **Web and Electron only**; Apple SDKs leave it out. |
| `sourceFile` / `sourceLine` | string / integer | Only when the host opted in at the call site. |
| `bounds` | rect | On-screen position, in `viewport` coordinates. For a `path`, the drawn shape's bounding box. |
| `path` | array of `[x, y]` | The drawn shape. **`path` kind only.** |

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

Either way: read `bounds`, and let the crop and the context shot carry the rest.

**A `kind` of `"path"` means the person drew a shape around several things.** It says
the one thing a rectangle cannot: *these things, and not the things between them.*

A box around two controls at opposite corners of a card includes everything in
between and therefore means nothing. So does a box around a diagonal run of items in
a grid. The shape is the answer to that.

```json
"element": {
  "kind": "path",
  "bounds": { "x": 40, "y": 60, "width": 120, "height": 90 },
  "path": [[40, 60], [160, 70], [100, 150]]
}
```

- **`[x, y]` pairs, not objects, and not SVG path data.** Both SDKs already produce
  points and neither needs curves, so anything can render this with four lines. The
  pair form matters at this size: a drawn shape is hundreds of points, and the object
  form spends four times the bytes repeating `"x"` and `"y"` in a payload leaving a
  phone on whatever network is going.
- **Closed implicitly.** The last point joins the first. Fill it with the **even-odd**
  rule - a hand-drawn shape crosses itself often, and even-odd is what a renderer
  handed a bare point list does by default.
- **Simplified before it is written** (Ramer-Douglas-Peucker, about 2 points of
  tolerance). A finger emits a point per frame, so an unthinned shape around one card
  is several hundred points that sit on top of each other.
- **`bounds` is the bounding box, and it is still required.** That is the contract:
  ignore `path` entirely and you get exactly the rectangle a drag would have given
  you. A missing field degrades quality, never correctness.

On Apple platforms the crop PNG for a path is the bounding box with everything
outside the shape replaced by `loupe.cutaway` - so the picture shows what was circled
and not what was deliberately gone around. The context shot is the whole window with
the shape stroked on it, the same as for the other two kinds.

**The web SDK sends no crop for a path, and none for a region either.** It captures
by cloning an element into an SVG `foreignObject`, and neither a region nor a shape
has an element to clone. It is worse for a shape than for a region: even a
bounding-box crop taken some other way would be a rectangle, which is the exact thing
the person went out of their way not to say, so a picture would contradict the
gesture rather than merely be missing. `bounds` plus `path` is what a shape offers
there, and that is enough to draw it over a screenshot taken any other way.

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
  not a person.
- **No request or response bodies.** Only method, URL, status and duration. Bodies are
  where secrets live, and a URL is enough to find the endpoint in source.
- **No full page source.** The element reference plus a crop, not a DOM dump.
- **No video.** Stills only.
- **No picture at all, sometimes.** Both image fields are optional. The web SDK often
  cannot take one (a cross-origin image taints the canvas), and it carries the element
  reference and the trace instead. Missing pictures degrade quality, never correctness.

If you need any of that, it belongs in your own intake service, added on top - not in the
format everybody else has to trust.
