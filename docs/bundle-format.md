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
~/.loupe/<app-name>/<sessionID>/
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
| `accessibilityID` | string | What the app named the element. The strongest signal for finding it in source. |
| `label` | string | Visible text or accessibility label. |
| `className` | string | Runtime type, e.g. `ResultsCollectionView` or `div`. |
| `selector` | string | CSS selector. **Web and Electron only**; Apple SDKs leave it out. |
| `sourceFile` / `sourceLine` | string / integer | Only when the host opted in at the call site. |
| `bounds` | rect | On-screen position, in `viewport` coordinates. |

A rect is `{ "x", "y", "width", "height" }`, all numbers, origin top-left.

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
