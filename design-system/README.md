# Signloop — Playroom design system

Approved visual foundation, v0.1 · Sunny · September 19, 2026.

**The visual direction is agreed; the app screens are still drafts.** This package captures the reusable colors, fonts, type hierarchy, spacing, shapes, icons, and interaction rules. It does not approve a screen inventory or implement a navigation flow.

The goose will be a **3D character supplied by another teammate**, with idle, thinking, and emotion modes. The illustrated goose in the local studies is a placeholder and is not a shipped asset or character specification.

## What to use

| File | Purpose |
|---|---|
| `tokens.json` | Canonical token source. Semantic color and shadow entries refer to named palette keys. |
| `tokens.resolved.json` | Generated, platform-neutral tokens with color references resolved. Useful outside TypeScript, including the existing iOS scaffold. |
| `tokens.ts` | Generated, typed tokens with semantic colors resolved. No runtime dependencies. |
| `native.ts` | React Native text styles, explicit font aliases, and token exports. No React Native dependency required to import the data. |
| `tokens.css` | Scoped `--sl-*` custom properties for HTML work; no resets, fonts downloaded at runtime, or screen styles. |
| `icons.json` / `icons.ts` | Original icon geometry, source and generated typed registry. |
| `assets/icons/*.svg` | 21 reusable SVG icons from the prototypes. |
| `build.py` | Generates adapters/assets, checks freshness, and verifies approved text/surface contrast pairings. |

The HTML prototypes, illustrative camera person, goose drawings, hardcoded device frames, and sample translations are not part of this package. The existing camera scaffold is unchanged. Expo remains the intended consumer-app direction; this package does not select or migrate a runtime.

## Character of the interface

Warm, direct, and playful. Butter-yellow surfaces, coral actions, blue supporting areas, dark brown ink, rounded typography, and a restrained solid-offset shadow. Personality comes from the visual language and eventual character, not extra slogans or tiny decorative labels.

- Make the signed message the most readable content on the screen.
- Prefer generous open space to extra cards, badges, dividers, or metrics.
- Use sentence case and useful labels. Remove copy that does not explain a state, action, or next step.
- Keep layouts stable during translation and speech. Character movement should not move the camera or captions around.
- Use actual status for feedback. A friendly visual style must not hide uncertainty.

## Color

| Role | Value | Use |
|---|---|---|
| Butter | `#FFF2BA` | Main app canvas |
| Paper | `#FFFCF0` | Captions, sheets, secondary buttons |
| Coral | `#F87960` | Primary actions; not a generic error color |
| Blue | `#A7C6E8` | Supporting surfaces and illustrations |
| Ink | `#49312D` | Main text and strong outlines |
| Strong ink | `#432D2B` | Labels on coral primary actions |
| Muted ink | `#75675F` | Supporting text on butter or paper |
| Success | `#E3F0D2` / `#40532B` | A successful state, with an icon and text |
| Caution | `#FFEDC3` / `#70502B` | Recoverable issues with specific guidance |
| Destructive ink | `#AA3E29` | Destructive-action text on paper |
| Focus | `#315991` | Visible keyboard focus |

Use semantic roles (`semantic.surface.canvas`, `semantic.text.default`) in components. Palette names are available for art and exceptional uses. Muted text is approved on butter and paper, not every colored surface. Never use white text on coral. Strong ink slightly darkens the primary-action label to clear 4.5:1 contrast without changing the coral.

Status always needs text or an icon alongside color. Soft dividers are decorative; interactive boundaries use strong ink. Success means the specific check passed—for example, visible hands and face—not that a translation is guaranteed correct.

## Typography

**Fredoka** is the display and caption family. **DM Sans** carries body copy, controls, and utility labels. Both stay upright; no all-caps micro-label system or widely tracked technical readouts in the consumer UI.

| Token | Family / weight | Size / line height | Use |
|---|---|---|---|
| `hero` | Fredoka 500 | 48 / 52 | Occasional short welcome headline |
| `title` | Fredoka 500 | 40 / 44 | Main screen heading |
| `sheetTitle` | Fredoka 500 | 28 / 32 | Sheet heading |
| `sectionTitle` | Fredoka 500 | 24 / 28 | Section heading |
| `status` | Fredoka 500 | 20 / 24 | A brief state label |
| `caption` | Fredoka 400 | 24 / 28 | Main translated message |
| `captionLarge` | Fredoka 400 | 30 / 36 | Larger-caption option |
| `body` | DM Sans 400 | 16 / 24 | Instructions and prose |
| `button` | DM Sans 600 | 16 / 24 | Action labels |
| `label` | DM Sans 600 | 14 / 20 | Useful metadata and state qualifiers |
| `supporting` | DM Sans 400 | 14 / 20 | Secondary explanatory copy |

These are logical sizes, not fixed raster sizes. Preserve system text scaling and allow wrapping. At large sizes, give captions more room before reducing type size; scrolling is preferable to clipped text or unreachable controls. The named larger-caption option is not a substitute for system accessibility settings.

Font binaries are not included. Before using `native.ts`, register the corresponding font files under these aliases:

| Alias | Font file to load |
|---|---|
| `SignloopDisplayRegular` | Fredoka Regular / 400 |
| `SignloopDisplayMedium` | Fredoka Medium / 500 |
| `SignloopBodyRegular` | DM Sans Regular / 400 |
| `SignloopBodyMedium` | DM Sans Medium / 500 |
| `SignloopBodySemibold` | DM Sans Semibold / 600 |

The native styles select the actual loaded weight by alias; they do not depend on synthetic `fontWeight`. HTML consumers load the families separately. A font-loading fallback must keep the interface usable.

## Spacing, shape, and controls

- Use a **4-point spacing unit**: `space[1] = 4`, `space[3] = 12`, `space[6] = 24`. Common choices are 8 within small groups, 12 between related components, and 24 between sections.
- Screen gutters start at 24; 16 is the compact option. Add the device's safe-area insets separately. Do not copy the prototype's fake status bar or home indicator.
- Radius: 8 for small surfaces, 16 for controls, 20 for caption bubbles, 28 for larger panels/sheets. A bubble can use the 4-point tail corner deliberately.
- Outlines are usually 1.5 points of ink; use 2 for emphasis. Avoid soft card shadows everywhere. Primary actions use a 3-point solid downward offset; captions may use the softer ochre offset.
- A compact icon control has a **minimum 44 × 44 touch area**, even when its glyph is 20–22 points. Prefer 48 where space allows. Primary actions have a minimum height of 52 and can grow with text.
- Keep pause discoverable and labeled for assistive technology. A gesture can supplement it, but must not be the only way to stop capture or speech.
- Use the same visual hierarchy for primary, secondary, and destructive actions across screens. Button width, exact placement, and screen-specific layouts remain open for iteration.

The source normalizes one-off prototype measurements to a reusable 4-point rhythm. It does not preserve every 17-, 19-, or 25-pixel exploratory measurement.

## Icons and reusable art

Icons use a 24 × 24 viewBox, rounded caps and joins, a 1.75-unit outline, and `currentColor`. The filled play triangle and heavier pause bars are intentional exceptions. Render glyphs at the token size inside a larger pressable area.

The geometry registry contains `path` and `circle` elements. An app adapter can map these to its SVG renderer; no SVG runtime or rendering library is imposed here. `$surface` in the settings icon means the background directly beneath the icon; standalone SVG exports default it to paper.

Give icon-only controls an action label such as “Pause camera and speech.” Treat the icon itself as decorative when the parent control already supplies its accessible name. These are original UI assets from the Signloop studies, not final branding or a goose asset pack.

## Motion and the future 3D goose

UI timing tokens cover presses (85 ms), small feedback (160 ms), content transitions (240 ms), navigation (280 ms), and stage travel (440 ms). Controls compress to 97.5% and move down two points, then release with the shared touch spring. Sheets use the more damped sheet spring with no overshoot. Use the same tokens across new controls instead of adding local timings.

Reduce Motion removes movement and animated layout changes; status always has a static text/icon cue. In the mobile app, the shared MotionProvider observes changes to the OS preference. Haptics signal completed taps, never inferred emotions or recognition confidence.

Keep the camera renderer and avatar mounted across state changes. Fade supporting text and overlays; do not animate every word of a streaming draft. Opening a sheet suspends capture and voice immediately, keeps the visible conversation stable beneath the backdrop, and resumes only after dismissal completes. Correction playback starts after the keyboard and sheet close. Content changes within the same sheet resize the existing surface.

The 3D character's modeling, rigging, materials, animation clips, emotion set, and rendering technology belong to the teammate producing it. Those decisions are intentionally not embedded in this design system.

For the eventual integration:

- Reserve a replaceable character region with no dependence on the current SVG's dimensions, colors, or DOM anatomy.
- Map app activity to the character's available clips in an adapter. Idle and thinking are expected concepts; final clip names are the character teammate's decision.
- Keep activity, playback, and emotional expression separate. A framing error or network failure is not an emotion attributed to the signer.
- Speech animation follows actual audio playback. Stop it when playback stops or the session pauses. The UI caption remains usable if the model/renderer is unavailable.
- Support a neutral still pose or minimal-motion alternative. Keep the character from covering captions, controls, or the signing area.

This records the integration boundary, not a finalized animation state machine.

## Use in an Expo / React Native screen

After the app loads the font aliases:

```tsx
import { StyleSheet } from 'react-native';
import { tokens, textStyles } from '../design-system/native';

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: tokens.semantic.surface.canvas,
    paddingHorizontal: tokens.layout.screenGutter,
  },
  caption: {
    ...textStyles.caption,
    color: tokens.semantic.text.default,
  },
  primaryAction: {
    minHeight: tokens.control.primaryMinHeight,
    backgroundColor: tokens.semantic.surface.primary,
    borderColor: tokens.semantic.stroke.strong,
    borderWidth: tokens.border.default,
    borderRadius: tokens.radius.control,
    paddingHorizontal: tokens.space[4],
    paddingVertical: tokens.space[3],
  },
});
```

This is a styling example, not a shipped component. The app remains responsible for safe areas, font loading, focus, disabled states, text scaling, and audio/camera behavior. Shadow geometry is exported as data; each runtime maps it to its own shadow implementation.

For HTML, load `tokens.css` and use `--sl-surface-canvas`, `--sl-text-default`, `--sl-font-display`, `--sl-type-caption-size`, and the other generated variables. The CSS does not import Google Fonts or make network requests.

## Editing and verification

Change `tokens.json` or `icons.json`, then regenerate and commit the outputs with the sources:

```sh
python3 design-system/build.py
python3 design-system/build.py --check
```

The check verifies generated-file freshness, valid palette/alias references, and the nine approved text/surface pairings at 4.5:1 or better. It is a token check, not a claim that an unbuilt app passes an accessibility audit.

Final screen layouts, 3D character assets, and runtime integration remain separate work.
