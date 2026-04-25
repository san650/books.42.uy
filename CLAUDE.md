# Lev — Personal Book Tracker

## Project Overview

Single-page book tracking app at books.42.uy. No frameworks — vanilla HTML/CSS/JS. Ruby CLI tools for data management.

## Commands

```bash
make server   # python3 -m http.server 8000 -d public
make add      # ruby add_book.rb — search Goodreads, scrape metadata, download cover
make edit     # ruby edit_book.rb — refetch metadata from Goodreads, field-by-field update
make review   # ruby add_review.rb — select book, edit review via $EDITOR
```

All three scripts auto-commit to git after changes: "Add/Edit/Review &lt;title&gt; - &lt;author&gt; book".

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

- `public/` contains all files served by GitHub Pages: `index.html`, `404.html`, `CNAME`, `assets/`, `covers/`, `db.json`.
- `public/db.json`: pretty-printed, books sorted alphabetically by `title`. Saga books sort by saga name then order within the group.
- Cover files: `public/covers/<id>-<sanitized-title>.<ext>` (lowercase, hyphens, no spaces).
- Ruby scripts share common functionality via `common.rb` (loaded with `require_relative`).

## Data Schema

Each book in `db.json` has: `id`, `title`, `subtitle` (optional), `original_title`, `first_publishing_date`, `publish_dates[]`, `authors[]` (with `name` and `aliases`), `identifiers[]` (with `type` and `value`), `covers[]` (with `file` and `default`), `publisher`, `score` (1-10, optional — null shows as "–"), `review`, `saga` (optional — `{ "name": "...", "order": 1 }` or null).

### Saga Grouping (Option A — Group Header)

Books in a saga are grouped together under a colored header row (purple bg, brand font, yellow text). Within a group, books sort by `saga.order`. A yellow 3px separator marks the end of each saga group. Standalone books (no saga) sort alphabetically by title around the saga groups. Saga groups sort by saga name among the standalone books.

### Text Overflow

Book rows have fixed height. Title and subtitle each allow max 2 lines with ellipsis (`-webkit-line-clamp: 2`). Original title and author are single-line with `text-overflow: ellipsis`.

## Deployment

GitHub Pages serving from `public/` directory with custom domain books.42.uy. 404.html redirects to index.html. CNAME file required.
