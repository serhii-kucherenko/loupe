# Loupe - agent instructions

`project_tracker: linear`

The ordered list of work lives in the [Linear project](https://linear.app/serhii-kucherenko/project/loupe-51d5ad5bc003).
Do not create a ROADMAP.md or a plans directory here: two lists mean two truths and both rot.

## What this is
An annotation SDK compiled into the dev/staging build of a host app. Apple platforms first
(macOS, iPad, iPhone). Open source, MIT. It is meant to be adopted by other people's apps,
so the public API is a contract: additive changes only, no breaking renames without a major.

## Rules
- `LoupeCore` stays free of UIKit and AppKit. It is the testable half; keep it that way.
- `LoupeUI` holds every platform seam, behind `#if canImport(...)`.
- Visible UI follows `DESIGN.md`. A new token goes in that file in the same change.
- Non-trivial logic leaves one runnable test behind. `swift test` must pass before any commit.
- The picker's meaningful-ancestor walk is the correctness core. Changes there need a test.
