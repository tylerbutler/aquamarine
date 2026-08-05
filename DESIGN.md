---
name: Aquamarine
description: Protocol-agnostic Beryl-style WebSocket channel client for Gleam on the BEAM.
colors:
  accent-low: "#0e3f47"
  accent: "#3fbfb5"
  accent-high: "#b8f0ea"
  ink: "#f4fafb"
  text-strong: "#e3f0f4"
  text-muted: "#b8d2de"
  text-subtle: "#6b8a9e"
  surface-muted: "#355569"
  surface-raised: "#1b3349"
  surface: "#122638"
  canvas: "#0b1a26"
  crimson: "#e63462"
  crimson-soft: "#ff6b8b"
typography:
  display:
    fontFamily: "Sora Variable, system-ui, sans-serif"
    fontWeight: 600
  headline:
    fontFamily: "Sora Variable, system-ui, sans-serif"
    fontWeight: 600
  body:
    fontFamily: "Commissioner Variable, system-ui, sans-serif"
    fontWeight: 430
  label:
    fontFamily: "Commissioner Variable, system-ui, sans-serif"
    fontWeight: 600
  mono:
    fontFamily: "JetBrains Mono Variable, ui-monospace, monospace"
    fontWeight: 400
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.canvas}"
  button-minimal:
    backgroundColor: "transparent"
    textColor: "{colors.text-strong}"
  card-doc:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text-strong}"
---

# Design System: Aquamarine

## 1. Overview

**Creative North Star: "The Clear Channel"**

Aquamarine's visual system is a calm technical signal: dark navy structure, aquamarine emphasis, and restrained documentation patterns that keep the reader oriented. The site should feel like a reliable channel runtime rather than a launch campaign. It earns attention through clarity, hierarchy, and well-placed examples.

The current site is built on Astro Starlight, so the system should preserve Starlight's documentation affordances while making Aquamarine's identity visible through color, typography, and navigation rhythm. The brand rejects generic SaaS landing-page tropes, hype metrics, decorative gradients, and ornamental visuals that do not explain the library.

**Key Characteristics:**
- Dark-first technical documentation with a light theme that keeps the same navy/aquamarine identity.
- One primary aquamarine signal color, used for links, primary actions, and active affordances.
- Crimson is a rare secondary highlight, not a competing accent system.
- Commissioner gives long-form documentation a readable humanist sans voice, while Sora adds a sharper display layer for headings and the site title.

## 2. Colors

The palette is a deep-water navy documentation shell with aquamarine signal color and a restrained crimson highlight.

### Primary
- **Clear Aquamarine**: The primary action, link, and active-state color. It should be visible but never flood the surface.
- **Pale Channel Glow**: High-contrast accent text and selected states on dark surfaces.
- **Deep Channel Teal**: Low-emphasis accent backgrounds, callout tinting, and active navigation grounds.

### Secondary
- **Crimson Interrupt**: A sparing highlight for important contrast moments, warnings, or brand-specific emphasis.
- **Soft Crimson Signal**: A lighter companion for hover or small decorative emphasis when the main crimson is too strong.

### Neutral
- **Midnight Canvas**: The dark-mode page ground.
- **Deep Navy Surface**: The primary documentation surface and shell color.
- **Raised Navy Surface**: Sidebars, cards, and grouped content areas when Starlight needs a second layer.
- **Muted Blue Border**: Structural dividers and quiet outlines.
- **Bright Ink**: Primary text and icons on dark surfaces.
- **Muted Technical Text**: Secondary body copy and metadata.

### Named Rules

**The Signal Rarity Rule.** Aquamarine is the signal, not the wallpaper. If more than roughly 10% of a viewport is accent-colored, the interface is shouting.

**The Crimson Exception Rule.** Crimson is reserved for rare emphasis. It must not become a second brand palette competing with aquamarine.

## 3. Typography

**Display / Headline Font:** Sora Variable with system sans fallback  
**Body / UI Font:** Commissioner Variable with system sans fallback  
**Code Font:** JetBrains Mono Variable with system monospace fallback

**Character:** The type system pairs a readable humanist sans for prose and UI with a crisp geometric sans for headings. Commissioner carries long reference passages and navigation without strain; Sora adds a precise, engineered display voice where hierarchy needs more presence. Code uses JetBrains Mono so Gleam examples stay distinct and easy to scan.

### Hierarchy
- **Display** (Sora, 600, Starlight splash scale): Used for the homepage hero and site title. Keep line breaks balanced and avoid oversized marketing language.
- **Headline** (Sora, 600, Starlight heading scale): Used for documentation sections and page titles.
- **Title** (600): Used for cards, sidebar groups, and component titles.
- **Body** (Commissioner, 430): Used for documentation prose, capped by Starlight's readable content measure.
- **Label** (Commissioner, 600): Used for navigation, badges, and action labels when the UI needs extra structure.
- **Code** (JetBrains Mono, 400): Used for code blocks and inline code.

### Named Rules

**The No-Hype Heading Rule.** Headings should explain the runtime model or reader task. Avoid abstract launch-copy phrases that could belong to any developer tool.

## 4. Elevation

Aquamarine is flat by default. Depth comes from tonal layering inside the navy ramp, not broad shadows or glass effects. Starlight containers, cards, and navigation groups should distinguish hierarchy through background shifts and clear borders.

### Named Rules

**The Tonal Layer Rule.** Use darker and lighter navy surfaces before adding shadows. If a shadow appears decorative, remove it.

## 5. Components

### Buttons
- **Shape:** Inherit Starlight's documentation button shape; do not over-round beyond the framework defaults.
- **Primary:** Clear Aquamarine background with Midnight Canvas text for strong action contrast.
- **Hover / Focus:** Keep state changes crisp and accessible. Use color shifts and focus outlines rather than glow-heavy effects.
- **Minimal:** Transparent background with strong text, used for secondary actions like GitHub links.

### Cards / Containers
- **Corner Style:** Starlight defaults; restrained and documentation-native.
- **Background:** Raised Navy Surface on Midnight Canvas or Deep Navy Surface.
- **Shadow Strategy:** No decorative shadow stack. Use tonal layering and borders.
- **Border:** Muted Blue Border where separation is needed.
- **Internal Padding:** Starlight card spacing; avoid dense custom overrides unless the content demands it.

### Navigation
- **Style:** Starlight sidebar and top navigation should remain the primary wayfinding system. Active states use the aquamarine family; group labels stay quiet and scannable.
- **Mobile Treatment:** Preserve Starlight's responsive navigation behavior. Custom styling must not reduce tap target size or contrast.

### Code Blocks
- **Style:** Code should feel first-class. Keep syntax highlighting readable against the dark navy ground, and avoid shrinking examples below comfortable documentation size.

## 6. Do's and Don'ts

### Do:
- **Do** preserve the dark-first navy/aquamarine identity already defined in `website/src/styles/custom.css`.
- **Do** use Clear Aquamarine for primary actions, links, and active documentation states.
- **Do** keep prose and examples readable; the site succeeds when developers can understand the lifecycle quickly.
- **Do** use Crimson Interrupt only for rare emphasis, never as a broad decorative accent.
- **Do** keep documentation affordances recognizable; Aquamarine should feel custom-branded, not custom for its own sake.

### Don't:
- **Don't** use generic SaaS landing-page tropes: hype metrics, decorative gradients, hero-stat blocks, or ornamental visuals that do not explain the library.
- **Don't** add gradient text, glassmorphism, or wide soft shadow stacks to make the site feel "premium."
- **Don't** turn every section into identical icon cards. Cards should support navigation or comprehension, not fill space.
- **Don't** over-round cards, buttons, or containers beyond the Starlight defaults.
- **Don't** let crimson compete with aquamarine as a primary brand color.
