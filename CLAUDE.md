# Lev — Personal Book Tracker

## Project Overview

Single-page book tracking app at books.42.uy. No frameworks — vanilla HTML/CSS/JS. Ruby CLI tools for data management.

## Commands

```bash
# Serve locally
python3 -m http.server 8000

# Add a book
ruby add_book.rb

# Add/edit a review
ruby add_review.rb
```

## Design System

### Palette (five colors only)

| Variable | Hex | Usage |
|----------|-----|-------|
| `--c-deep` | `#1E104E` | Toolbar, primary text, dark sections |
| `--c-purple` | `#452E5A` | Secondary text, cover columns, footer |
| `--c-orange` | `#FF653F` | Accent, high scores, focus, hover inversion |
| `--c-yellow` | `#FFC85C` | Score badges, row hover, input focus |
| `--c-white` | `#FFFFFF` | Page background |

Derived: `--surface: #F4F1F7`, `--surface-alt: #EAE5F0`

### Typography — four fonts, each with a distinct role

| CSS Variable | Font | Weight | Role |
|-------------|------|--------|------|
| `--f-brand` | Space Mono | 700 | Toolbar brand, section labels, count strip |
| `--f-title` | DM Serif Display | 400 | Book titles, modal titles, review text |
| `--f-body` | Work Sans | 400, 600 | Author names, body text, metadata values |
| `--f-mono` | JetBrains Mono | 700 | ISBNs, scores, years, labels, placeholders |

Fonts are self-hosted WOFF2 files in `assets/`. Do not use Google Fonts CDN.

### Visual Rules

- **No borders.** Separate sections using background color changes only.
- **No rounded corners.** Keep the brutalist aesthetic.
- **No shadows.** Use color contrast for depth.
- **No external libraries.** All CSS and JS is hand-written.
- **Desktop**: app centered, max-width 640px.
- **Mobile-first** responsive design. Modal fills entire viewport on mobile.

### CSS Architecture — Layers + Utility-First

Three CSS layers declared at the top: `@layer reset, utility, component;`

- **`@layer reset`**: box-sizing, margin reset, base body styles
- **`@layer utility`**: one-property classes composed in HTML markup
- **`@layer component`**: stateful styles that can't be utility-composed (`:hover`, `:nth-child`, `::backdrop`, `dialog[open]`, `.selected`, responsive breakpoints)

Design tokens (`:root` custom properties) and `@font-face` live **outside** layers.

Each utility class maps to **one property**. Styling is composed by applying multiple classes in HTML markup:

```html
<nav class="bg-deep flex items-center gap-4 px-5 py-4">
  <span class="font-brand text-lg fw-700 uppercase tracking-wide color-white">Lev</span>
</nav>
```

Naming convention (Tailwind-inspired, simplified):
- Colors: `bg-deep`, `bg-purple`, `color-orange`, `color-white`, etc.
- Typography: `font-brand`, `font-title`, `text-lg`, `fw-700`, `uppercase`, `italic`
- Spacing: `p-4`, `px-5`, `py-3`, `gap-4`, `m-auto`
- Layout: `flex`, `flex-col`, `flex-1`, `grid`, `items-center`, `justify-between`

### Semantic HTML

Use semantic elements everywhere: `<nav>`, `<main>`, `<header>`, `<footer>`, `<dialog>`, `<section>`, `<article>`, `<kbd>`, `<time>`. Avoid generic `<div>` and `<span>` when a semantic element exists for the purpose. Use `<div>` only as a layout/grouping wrapper with no semantic meaning.

### JavaScript — Modern ES Modules

- `<script type="module">` — no global scope pollution
- Target: latest Chrome + iOS Safari (iPhone 12, iOS 26.4+)
- Use: `const`/`let`, arrow functions, template literals, optional chaining, `async`/`await`, `structuredClone`, `Array.at()`
- **Prefer CSS over JS.** Hover states, transitions, animations, responsive behavior, alternating backgrounds — all CSS. JS handles only: data fetching, DOM rendering, search filtering, dialog open/close wiring.
- Dialog animation uses CSS `@starting-style`, not JS

### Interactions

- Book row hover: yellow background, score inverts colors.
- Search input focus: background turns yellow.
- Modal: uses native `<dialog>` tag. Click outside or ESC to close.

### Keyboard Navigation

Global `keydown` listener with `selectedIndex` tracking. All keybindings are suppressed when the search input is focused (except ESC to blur).

| Key | Action |
|-----|--------|
| Arrow Down/Up | Navigate book list |
| Enter / Space | Open selected book detail |
| Esc | Close dialog / blur search / return to list |
| F | Focus search bar |
| ? | Open help modal with keybinding reference |

## File Conventions

- `db.json`: pretty-printed, books sorted alphabetically by `title`.
- Cover files: `covers/<id>-<sanitized-title>.<ext>` (lowercase, hyphens, no spaces).
- Ruby scripts are self-contained single files with no gem dependencies beyond stdlib.

## Data Schema

Each book in `db.json` has: `id`, `title`, `original_title`, `first_publishing_date`, `publish_dates[]`, `authors[]` (with `name` and `aliases`), `identifiers[]` (with `type` and `value`), `covers[]` (with `file` and `default`), `publisher`, `score` (1-10, optional — null shows as "–"), `review`.

## Deployment

GitHub Pages with custom domain books.42.uy. 404.html redirects to index.html. CNAME file required.
