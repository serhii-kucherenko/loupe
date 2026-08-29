# Loupe design

The source of truth for how the annotate overlay looks. New UI uses these tokens. A new
token gets added here in the same change, or it does not exist. Never introduce a raw hex,
font stack, or one-off spacing value that is not in this file.

## Principle

The overlay sits on top of someone else's product. It must read as a tool, never as part
of the app underneath, and it must never hide the thing being annotated. Every surface is
translucent, every panel hugs an edge, and the highlight is the loudest thing on screen.

Translucent, but **blurred**. A panel that is merely see-through lets the host app's own
text read straight through a comment, which is unusable over a busy screen. `blur.panel`
goes behind every surface, so what shows through is depth rather than someone else's words.

## A host may replace these

Everything below is Loupe's own look, and it is the default. A host app that has a
design system of its own passes tokens to `Loupe.start(app:theme:)` and the overlay
wears them instead:

```swift
Loupe.start(app: app, theme: LoupeTheme.Appearance(
    accent: .init(light: .init(hex: 0x4338CA), dark: .init(hex: 0xA5B4FC)),
    panelRadius: 28))
```

| Replaceable | Fixed |
|---|---|
| every colour in the table below | spacing, strokes, elevation, motion, hit targets |
| `radius.panel`, `radius.control`, `radius.highlight` | everything else in Spacing and shape |
| `type.body`, `type.label`, `type.caption`, `type.note` | |

Three rules hold this together:

1. **Every field has a default**, so a host names only what it has an opinion about,
   and omitting the argument entirely is exactly the picture in this file.
2. **`loupe.highlight.fill` follows the accent** unless the host states its own. A
   host names one accent; getting the wash right at two alphas in two appearances is
   the sort of homework that makes a theming hook go unused.
3. **It is not a styling API.** No per-control overrides, no slots for custom views.
   An overlay that can be restyled arbitrarily becomes a UI framework, and the point
   is for this one to disappear into its host.

The web SDK takes the same tokens by the same names, as CSS strings rather than
hex pairs - `start({ app, theme: { accent: "var(--brand)" } })` - so a page points
Loupe at a variable it already has instead of restating the value. The overlay is in
a shadow root there, so this option is the only way in; that is by design, since a
page's own reset would otherwise reshape the tool sitting on it.

The spacing scale, strokes, elevation and motion are deliberately not replaceable.
They are what make the overlay feel like one thing across four platforms, and a host
that changes them is not theming Loupe, it is redrawing it.

`scripts/check-theme-literals.py` fails the build on a colour, font or radius written
anywhere but `LoupeTheme.swift`. That is what makes the promise true rather than
mostly true: one hardcoded value is one control that ignores the host, which reads as
a bug rather than as a theme.

## Colour

Semantic names, not literal ones. Light and dark are both first-class.

| Token | Light | Dark | Use |
|---|---|---|---|
| `loupe.highlight` | `#B5551D` | `#E29A5A` | the picked element outline, tray index badges |
| `loupe.highlight.fill` | `#B5551D` @ 10% | `#E29A5A` @ 14% | the wash inside a picked element |
| `loupe.surface` | `#FFFFFF` @ 92% | `#141F1A` @ 92% | tray and comment panels |
| `loupe.ink` | `#17211C` | `#E9EFEA` | primary text |
| `loupe.ink.soft` | `#4C5A52` | `#A2B2A8` | secondary text, captions |
| `loupe.line` | `#D6DED8` | `#293830` | hairlines, panel borders |
| `loupe.action` | `#2F7D5B` | `#62C68E` | Send button, confirmation |
| `loupe.cutaway` | `#E8EDEA` | `#1E2823` | the ground behind a letterboxed thumbnail, so a crop of any shape has edges |
| `loupe.scrim` | `#17211C` @ 8% | `#000000` @ 24% | behind the whole screen while picking, where the app must stay readable |
| `loupe.scrim.modal` | `#17211C` @ 32% | `#000000` @ 48% | behind a panel that must be answered before anything else |

Tags reuse the palette rather than adding colours: `bug` uses `loupe.highlight`,
`polish` and `idea` use `loupe.ink.soft`, `question` uses `loupe.action`.

## Type

System faces only. The overlay must not ship fonts or clash with the host app.

| Token | Value | Use |
|---|---|---|
| `type.body` | `.body` | comment text |
| `type.label` | `.subheadline` semibold | panel titles, buttons |
| `type.caption` | `.caption` monospaced | endpoints, counts, element names |
| `type.note` | `.caption` | field labels, hints, status lines |

## Spacing and shape

A 4pt base. Only these steps: `4, 8, 12, 16, 24, 32`.

| Token | Value | Use |
|---|---|---|
| `radius.panel` | 16 | tray, comment popover |
| `radius.control` | 10 | buttons, tag chips |
| `radius.highlight` | 6 | the outline around a picked element |
| `stroke.highlight` | 2pt | the outline itself |
| `stroke.focus` | 2pt | the keyboard focus ring |
| `offset.focus` | 2pt | the gap between a control and its focus ring |
| `elevation.panel` | y8 blur24 @ 18% | floating panels |
| `blur.panel` | system ultra-thin material | what sits behind a panel |

## Motion

Fast and quiet. The overlay must never make someone wait to leave a note.

| Token | Value | Use |
|---|---|---|
| `motion.hover` | 90ms ease-out | highlight follows the pointer |
| `motion.panel` | 180ms spring(0.9) | tray and popover appear |
| `motion.commit` | 220ms ease-in-out | annotation flies into the tray |

Respect Reduce Motion: replace every transition with a cross-fade at `motion.hover`.

## Layout rules

- The tray hugs one edge and never covers the centre of the screen.
- The comment popover attaches to the picked element, and flips side rather than covering it.
- On iPhone the tray becomes a bottom sheet at one detent; on iPad and macOS it is a side panel.
- Minimum hit target 44pt on touch, 28pt on pointer.

## Accessibility

- The highlight is never the only signal: the picked element also gets a numbered badge.
- Every overlay control has an accessibility label, and the overlay is reachable by keyboard on macOS.
- The focus ring reuses `loupe.highlight` rather than adding a colour. It is the one thing
  already guaranteed to stand out against every surface here, and it clears 3:1 on both themes.
  It appears instantly: a ring that fades in is a ring you have already stopped looking for.
- Contrast holds at 4.5:1 for text on `loupe.surface` in both themes.
