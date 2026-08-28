## What changed

<!-- One or two sentences. What is different now that was not before? -->

## Why

<!-- The problem this solves. Link the issue if there is one. -->

## What you decided against

<!-- Optional, but useful. Saves a reviewer from re-deriving a road you already walked. -->

## Checks

- [ ] `swift build` passes
- [ ] `swift test` passes
- [ ] Non-trivial logic has a test that fails without this change
- [ ] Visible UI uses tokens from `DESIGN.md` (no raw hex or one-off spacing)
- [ ] `LoupeCore` still imports no UIKit or AppKit
- [ ] If `ElementPicker.meaningfulAncestor` changed, a test shows the case it fixes
