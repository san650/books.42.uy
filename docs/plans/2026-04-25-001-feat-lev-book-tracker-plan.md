---
title: "feat: Build Lev personal book tracker"
type: feat
status: active
date: 2026-04-25
origin: specs/2026-04-25-lev-design-brainstorm.md
---

# feat: Build Lev personal book tracker

## Overview

Build Lev, a personal book tracking app: a single self-contained HTML page that loads book data from `db.json`, with Ruby CLI scripts for data management. Brutalist design, no frameworks, self-hosted fonts, deployed to GitHub Pages at books.42.uy.

## Problem Frame

The user wants a minimal, personal book list they own and control — no third-party services, no accounts, no frameworks. Data lives in a JSON file in a git repo. The web page is static and hosted for free. Ruby scripts automate the tedious parts of adding books (metadata lookup, cover downloads). (see origin: specs/2026-04-25-lev-design-brainstorm.md)

## Requirements Trace

- R1. `index.html` displays all books from `db.json` sorted alphabetically by title
- R2. Search bar filters books in real-time with fuzzy matching across title, original_title, authors
- R3. Clicking a book opens a `<dialog>` modal with full details; clicking outside or ESC closes it
- R4. Mobile-first responsive design; modal fills viewport on mobile
- R5. Brutalist visual style: no borders, no rounded corners, no shadows — separation via background colors
- R6. Four self-hosted fonts with distinct roles (brand, titles, body, data)
- R7. `add_book.rb` fetches metadata from OpenLibrary API, attempts Goodreads scraping, downloads covers, manages `db.json`
- R8. `add_review.rb` provides interactive book selection and opens `$EDITOR` for review editing
- R9. `db.json` stays pretty-printed and alphabetically sorted by title
- R10. GitHub Pages deployment with custom domain and 404 redirect to index
- R11. Full keyboard navigation: arrow keys scroll the book list, Enter/Space opens selected book, ESC closes modal and returns to list, `F` focuses search bar, `?` opens a help modal showing all keybindings. Global keybindings are suppressed when the search bar is focused

## Scope Boundaries

- No user authentication or server-side logic
- No build step or bundler — all files served as-is
- No JavaScript frameworks or CSS libraries
- Ruby scripts use only stdlib (net/http, json, open-uri, io/console, tempfile)
- No dark mode (single light theme)
- No pagination — the list is expected to stay under a few hundred books

## Browser Targets

- Latest Chrome (147+)
- iOS Safari on iPhone 12+ with iOS 26.4+

This means we can freely use: `<dialog>` + `::backdrop`, CSS nesting, CSS `:has()`, `<script type="module">`, `structuredClone`, `at()`, `findLast()`, view transitions, container queries, and all ES2024 features. Verified via caniuse.com.

## Key Technical Decisions

- **Utility-first CSS**: Each CSS class maps to a single property (e.g., `.bg-deep { background: var(--c-deep) }`, `.font-title { font-family: var(--f-title) }`, `.text-lg { font-size: var(--text-lg) }`). Classes are composed directly in HTML markup like Tailwind. Custom properties define the design tokens; utility classes consume them. This means the HTML carries the styling intent explicitly — no semantic class names hiding what's applied. CSS nesting is used for state variants (hover, focus, nth-child) since those can't be composed in markup.
- **Modern JS with `<script type="module">`**: All JS runs as an ES module. Use `const`/`let`, arrow functions, template literals, optional chaining, `async`/`await`, `structuredClone`, `Array.prototype.at()`. Prefer CSS over JS whenever possible — animations, transitions, hover states, and responsive behavior are all CSS. JS handles only: data fetching, rendering, search filtering, and dialog open/close wiring.
- **Fuzzy search via trigram similarity**: Simple substring matching misses typos. A trigram-based score (count of matching 3-character sequences / total trigrams) gives fuzzy behavior with ~20 lines of JS and no dependencies. Threshold at 0.3 for loose matching.
- **`<dialog>` with `::backdrop` click**: Native `<dialog>` provides ESC-to-close for free. Add a click listener on the dialog element itself and close when the click target is the dialog (not its children) — this handles backdrop clicks without a separate overlay div. Modal open/close animation is CSS-only using `dialog[open]` and `@starting-style`.
- **Keyboard navigation with active row tracking**: Maintain a `selectedIndex` in JS. Arrow Up/Down moves it and scrolls the row into view with `scrollIntoView({ block: 'nearest' })`. The selected row gets a CSS class (`.selected`) styled with a distinct background. Enter/Space opens the detail dialog. ESC from the dialog returns focus to the previously selected row. `F` calls `searchInput.focus()`. `?` opens a second `<dialog id="help">` with keybinding reference. All global key handlers check `document.activeElement` — if it's the search input, they do nothing (except ESC which blurs the input back to the list). This keeps keyboard handling in JS but visual feedback in CSS.
- **OpenLibrary as primary metadata source**: Free, no API key, good coverage. Goodreads scraping is best-effort fallback since their pages change frequently. Cover downloads via bookcover.longitood.com API.
- **`$EDITOR` for reviews**: Respects the user's preferred editor. Write current review to a tempfile, open in editor, read back on save. Fall back to `vim`.

## Open Questions

### Resolved During Planning

- **How to handle books with no cover?** Show a gradient placeholder using the palette colors (same as mockup). The gradient is deterministic based on book ID.
- **How to handle books with same title?** The `id` field is the unique key. Title is for display/sort only.
- **Search debounce?** No — with <500 books, filtering on every keystroke is instant. Skip the complexity.

### Deferred to Implementation

- **Goodreads scraping selectors**: Their HTML structure may have changed. The script should gracefully degrade if scraping fails — OpenLibrary data is sufficient.
- **bookcover.longitood.com API response format**: Need to test the actual response. Fall back to OpenLibrary covers if the service is unavailable.
- **Spanish publisher suggestion list**: The specific publishers to suggest (Planeta, Alfaguara, Sudamericana, etc.) can be refined during implementation.

## Implementation Units

- [ ] **Unit 1: Project scaffolding**

  **Goal:** Create all non-code project files so the repo is deployable and well-structured from the start.

  **Requirements:** R10

  **Dependencies:** None

  **Files:**
  - Create: `db.json` (empty array `[]`)
  - Create: `.gitignore`
  - Create: `CNAME` (books.42.uy)
  - Create: `404.html` (meta-refresh redirect to index.html)
  - Create: `LICENSE` (MIT, 2025, Santiago Ferreira)
  - Create: `README.md`
  - Create: `covers/` (empty directory with `.gitkeep`)

  **Approach:**
  - `db.json` starts as `[]` — the Ruby scripts populate it
  - `.gitignore`: `.claude/`, `*.tmp`, `.DS_Store`, `node_modules/`
  - `404.html`: minimal HTML with `<meta http-equiv="refresh" content="0;url=/">` plus a JS `window.location.replace('/')` fallback — this is the standard GitHub Pages SPA trick
  - `README.md`: brief description, link to books.42.uy, mention of Ruby scripts

  **Verification:**
  - All files exist and are well-formed
  - `404.html` redirects to `/` when opened directly

- [ ] **Unit 2: index.html — Utility CSS foundation**

  **Goal:** Write a utility-first CSS system: custom properties for design tokens, `@font-face` declarations, a reset, and single-property utility classes that get composed in HTML markup.

  **Requirements:** R4, R5, R6

  **Dependencies:** Unit 1 (fonts already exist in `assets/`)

  **Files:**
  - Create: `index.html` (`<style>` block at the bottom, before `</body>`)

  **Approach:**
  - **CSS `@layer` ordering**: declare `@layer reset, utility, component;` at the top. Reset styles go in `@layer reset`, utility classes in `@layer utility`, and stateful/structural styles (dialog, hover, nth-child, responsive) in `@layer component`. This ensures utilities always beat reset, and component overrides beat utilities when needed
  - **Design tokens in `:root`** (outside any layer): palette (`--c-deep`, `--c-purple`, `--c-orange`, `--c-yellow`, `--c-white`), surfaces (`--surface`, `--surface-alt`), font families (`--f-brand`, `--f-title`, `--f-body`, `--f-mono`), spacing scale (`--sp-1` through `--sp-12`), type scale (`--text-xs` through `--text-3xl`). `@font-face` declarations also outside layers
  - **Four `@font-face` declarations** pointing to `assets/*.woff2`
  - **Utility classes — one property each**, composed in HTML (inside `@layer utility`):
    - Colors: `.bg-deep`, `.bg-purple`, `.bg-orange`, `.bg-yellow`, `.bg-white`, `.bg-surface`, `.bg-surface-alt`, `.color-deep`, `.color-purple`, `.color-orange`, `.color-yellow`, `.color-white`, `.color-mid`
    - Typography: `.font-brand`, `.font-title`, `.font-body`, `.font-mono`, `.text-xs`, `.text-sm`, `.text-base`, `.text-lg`, `.text-xl`, `.text-2xl`, `.text-3xl`, `.fw-400`, `.fw-600`, `.fw-700`, `.uppercase`, `.tracking-wide`, `.tracking-wider`, `.italic`, `.leading-tight`, `.leading-relaxed`
    - Spacing: `.p-1` through `.p-8`, `.px-*`, `.py-*`, `.gap-*`, `.m-auto`
    - Layout: `.flex`, `.flex-col`, `.flex-1`, `.items-center`, `.items-stretch`, `.justify-center`, `.justify-between`, `.shrink-0`, `.grid`, `.w-full`, `.max-w-app` (640px), `.mx-auto`
    - Display: `.hidden`, `.block`, `.inline-block`
    - Sizing: specific width/height classes for covers and score columns
    - Transitions: `.transition-bg`, `.transition-colors`
  - **Component layer** (`@layer component`) for stateful/structural styles that can't be utility-composed:
    - `dialog { ... }` with `::backdrop`, `dialog[open]` animation via `@starting-style`
    - `.book-row { &:nth-child(even) { ... } &:hover { ... } }` and `.selected` state
    - Responsive: `@media (min-width: 641px) { ... }` for desktop centering
  - **No borders, no border-radius, no box-shadow** — strictly enforced
  - Mobile-first: base styles are mobile, media query adds desktop centering

  **Patterns to follow:**
  - Design tokens from `specs/palette-preview.html`
  - Utility naming convention: Tailwind-inspired but simpler (no responsive prefixes needed — only one breakpoint)

  **Test scenarios:**
  - Page renders with correct fonts and colors on Chrome/Safari
  - Resizing browser shows responsive centering at 641px+
  - Dialog fills viewport on mobile, is centered on desktop
  - CSS nesting works correctly (verified on target browsers)

  **Verification:**
  - Visual comparison against `specs/palette-preview.html` mockup
  - Inspect elements to confirm utility classes produce correct computed styles

- [ ] **Unit 3: index.html — HTML structure with utility classes**

  **Goal:** Write the semantic HTML for the toolbar, book list container, dialog modal, and footer — styled entirely via composed utility classes in markup.

  **Requirements:** R1, R3, R4

  **Dependencies:** Unit 2

  **Files:**
  - Modify: `index.html`

  **Approach:**
  - All styling is expressed as utility class composition in the HTML attributes, e.g. `<nav class="bg-deep flex items-center gap-4 px-5 py-4">`
  - **Semantic HTML everywhere** — use the most specific element for each purpose:
    - `<nav>` for toolbar
    - `<header>` inside dialog for the title area
    - `<main>` for the book list area
    - `<article>` for each book row (generated by JS)
    - `<footer>` for the page footer
    - `<dialog>` for both modals
    - `<section>` for logical groups within the modal (metadata, score, review)
    - `<time>` for dates/years
    - `<kbd>` for keyboard shortcut keys in the help modal
    - `<figure>` / `<img>` for book covers
    - `<search>` for the search form wrapper (HTML5 semantic element)
    - Avoid `<div>` and `<span>` when a semantic element exists
  - `<nav>` toolbar with logo `<img>`, brand text, and `<search>` wrapping `<input type="search">`
  - Accent strip as a styled element below the nav
  - `<main>` with a list container — JS generates `<article>` elements for each book row
  - Count strip showing total/filtered count
  - `<dialog id="book-detail">` — inner sections use `<header>`, `<section>`, semantic tags throughout. Dialog uses CSS nesting for `::backdrop` and `[open]` animation
  - `<dialog id="help">` — keybinding reference modal. Uses `<table>` or `<dl>` with `<kbd>` elements for keys. Same dialog styling as book detail but simpler content
  - `<footer>` with copyright, MIT license, GitHub link
  - Favicon `<link>` pointing to `assets/logo.svg`
  - `<meta>` tags for description, viewport, charset
  - `<script type="module">` at the bottom (Unit 4 fills it)

  **Patterns to follow:**
  - HTML structure matches mockup at `specs/palette-preview.html`
  - Use semantic elements: `<nav>`, `<main>`, `<footer>`, `<dialog>`
  - Styling intent is readable directly from the HTML — no hunting through CSS for what a class does

  **Test scenarios:**
  - Page loads and shows toolbar, empty list area, footer
  - Dialog can be opened programmatically via `dialog.showModal()`
  - All visual styles match mockup without any semantic CSS classes

  **Verification:**
  - HTML validates (no unclosed tags, correct nesting)
  - Structure and appearance match mockup sections

- [ ] **Unit 4: index.html — JavaScript (ES module)**

  **Goal:** Fetch `db.json`, render the book list, implement search filtering, and wire up the dialog modal. All JS is modern ES module code. Prefer CSS for anything CSS can handle.

  **Requirements:** R1, R2, R3

  **Dependencies:** Unit 3

  **Files:**
  - Modify: `index.html` (fill the `<script type="module">` section)

  **Approach:**
  - **Modern JS conventions**: `const`/`let` only (no `var`), arrow functions, template literals, optional chaining (`?.`), nullish coalescing (`??`), `async`/`await` for fetch, `Array.prototype.at()` where useful. All code inside `<script type="module">` — no global scope pollution
  - **CSS-first principle**: all hover states, transitions, responsive layout, alternating row backgrounds (`:nth-child`), dialog animations (`@starting-style`), and focus styles are CSS. JS only handles: data loading, DOM rendering, search logic, and dialog show/close
  - **Data loading**: top-level `await fetch('db.json')`, parse, sort by `title` using `localeCompare('es')`
  - **Rendering**: function that builds row HTML with utility classes composed per element. Generated HTML uses the same utility classes as static HTML. Use `innerHTML` — no framework needed at this scale. Each row includes a `data-index` attribute for dialog lookup
  - **Fuzzy search**: trigram function — extracts all 3-char sequences from a lowercased string. Score = intersection size / query trigrams count. On `input` event, filter books where any searchable field (title, original_title, author names) scores above 0.3. Re-render filtered list. Update count strip text
  - **Cover handling**: if book has a default cover, render `<img>` with utility classes. Otherwise render a `<div>` with gradient placeholder — use `book.id % 5` to select from 5 gradient combos. Cover image `onerror` falls back to placeholder
  - **Dialog**: clicking a row calls `dialog.showModal()` and populates inner HTML with the selected book's data (utility classes in generated markup). Close on backdrop click (`event.target === dialog`), ESC is built-in. Hide original title when same as title. Hide review section when empty
  - **Keyboard navigation**: single `keydown` listener on `document`. Maintain `selectedIndex` (starts at -1, meaning nothing selected). Behavior:
    - **ArrowDown**: increment `selectedIndex` (clamp to list length - 1), add `.selected` class to active row (remove from previous), `scrollIntoView({ block: 'nearest' })`
    - **ArrowUp**: decrement `selectedIndex` (clamp to 0), same visual update
    - **Enter / Space**: if a row is selected and no dialog is open, open book detail for that row
    - **Escape**: if book detail dialog is open, close it (native behavior) and refocus the selected row. If search input is focused, blur it and return to list navigation. If help dialog is open, close it
    - **F** (lowercase or uppercase): if not in search input, `searchInput.focus()` and `preventDefault()` to avoid typing "f" into the field
    - **?** (Shift+/): if not in search input and no dialog is open, open the help dialog
    - **All keys**: check `document.activeElement === searchInput` first — if true, let the event propagate normally (no global keybinding interference). Exception: ESC always handled to blur the search
  - **Selected row visual**: `.selected` class adds a background (use `--c-yellow` with lower opacity or `--surface-alt` to distinguish from hover). The selected state is CSS, the index tracking is JS
  - **Help dialog content**: static list of keybindings — `<kbd>` elements for keys, plain text for descriptions. Keybindings: Arrow Up/Down (navigate list), Enter/Space (open book), Esc (close/back), F (focus search), ? (show help)
  - **No `addEventListener` for hover/focus/animation** — those are purely CSS

  **Test scenarios:**
  - Empty `db.json` (`[]`) shows empty list with "0 libros" count
  - Books render sorted alphabetically by title
  - Searching "tol" matches "Tolstoi" in author field
  - Searching "karenina" matches title
  - Searching with typo "karnina" still matches via fuzzy
  - Clicking a book opens modal with correct data
  - Clicking backdrop closes modal
  - Pressing ESC closes modal
  - Books with no review hide the review section in modal
  - Books with no original_title (or same as title) hide the original title line
  - `<script type="module">` does not pollute global scope
  - ArrowDown from no selection selects first book
  - ArrowDown at last book stays on last book
  - ArrowUp at first book stays on first book
  - Enter on selected book opens its detail dialog
  - ESC from dialog returns focus to previously selected row
  - F key focuses search bar without typing "f"
  - Typing in search bar does not trigger arrow/enter/F keybindings
  - ESC from search bar blurs it and returns to list
  - ? key opens help dialog with keybinding list
  - After search filters the list, selectedIndex resets and arrow navigation works on filtered results

  **Verification:**
  - Add 2-3 sample books to `db.json` manually and verify all interactions work in Chrome and iOS Safari

- [ ] **Unit 5: add_book.rb — Book addition script**

  **Goal:** Interactive Ruby CLI that prompts for book info, fetches metadata from OpenLibrary (and attempts Goodreads), downloads covers, and appends to `db.json`.

  **Requirements:** R7, R9

  **Dependencies:** Unit 1 (db.json exists)

  **Files:**
  - Create: `add_book.rb`

  **Approach:**
  - **Flow**: prompt for title (required) -> search OpenLibrary API (`/search.json?title=`) -> display results and let user pick -> fetch work details (`/works/OLID.json`) and edition details -> prompt for missing fields -> download cover -> save to db.json
  - **OpenLibrary API**: `https://openlibrary.org/search.json?title=QUERY&limit=10` for search. Use edition data for ISBN, publisher, publish dates. Prefer Spanish editions: filter by `language: spa` in editions list, fall back to first edition
  - **Goodreads scraping**: best-effort. Search via `https://www.goodreads.com/search?q=QUERY`, parse HTML for additional metadata. Use `Net::HTTP` with a browser User-Agent. Gracefully skip on any error
  - **Cover download**: try `https://bookcover.longitood.com/bookcover/TITLE` first. Fall back to OpenLibrary covers API (`https://covers.openlibrary.org/b/isbn/ISBN-L.jpg`). Save to `covers/<id>-<sanitized-title>.<ext>`
  - **Sanitize title for filename**: downcase, replace non-alphanumeric with hyphens, collapse multiple hyphens, strip leading/trailing hyphens
  - **Publisher suggestions**: present a numbered list of common Spanish-language publishers (Planeta, Alfaguara, Sudamericana, Anagrama, Tusquets, Seix Barral, Salamandra, DeBolsillo, Penguin Random House) plus "Other (enter custom)"
  - **ID assignment**: `max_id + 1` from existing books, or 1 if empty
  - **Save**: append book to array, sort by title (locale-aware), write with `JSON.pretty_generate` with 2-space indent
  - **Interactive prompts**: use `$stdin.gets` for input. Show fetched metadata and let user confirm or override each field

  **Test scenarios:**
  - Running with empty `db.json` creates first book with id 1
  - Running with existing books assigns next sequential id
  - Output `db.json` is pretty-printed and sorted by title
  - Cover file is saved with correct naming convention
  - Script handles OpenLibrary being unreachable (timeout, error) gracefully
  - Script handles missing cover gracefully (no cover file, book still saved)

  **Verification:**
  - Run the script, add a book, verify `db.json` is valid and sorted
  - Verify cover file exists in `covers/` with correct name
  - Open `index.html` and confirm the new book appears

- [ ] **Unit 6: add_review.rb — Review editing script**

  **Goal:** Interactive Ruby CLI that lists books, lets user pick one, and opens their `$EDITOR` to write/edit a review.

  **Requirements:** R8, R9

  **Dependencies:** Unit 1 (db.json exists), Unit 5 (books exist to review)

  **Files:**
  - Create: `add_review.rb`

  **Approach:**
  - **Load books**: read and parse `db.json`
  - **Display list**: numbered list showing `[id] Title — Author (score/10)`. If book has existing review, show a marker like `[*]`
  - **Selection**: prompt for number, validate input
  - **Editor**: write current review (or empty string) to a `Tempfile` with `.md` extension. Open with `ENV['EDITOR'] || 'vim'`. Use `system()` to launch editor. On return, read the tempfile content
  - **Save**: update the book's review field, re-sort by title, write with `JSON.pretty_generate`
  - **Score editing**: also prompt "Update score? (current: N) [enter to skip]:" before opening editor, so user can adjust score at the same time

  **Test scenarios:**
  - Empty `db.json` shows "No books found" message
  - Books display with correct numbering
  - Books with existing reviews show marker
  - Editor opens with existing review content pre-filled
  - Saving empty review clears the review field (sets to empty string)
  - `db.json` remains sorted and pretty-printed after save

  **Verification:**
  - Run script, select a book, write a review, verify `db.json` updated
  - Re-run script, confirm the review marker appears and editor shows previous content

## System-Wide Impact

- **Interaction graph**: `add_book.rb` and `add_review.rb` both read and write `db.json`. They should not run simultaneously (no locking needed — single user). `index.html` only reads `db.json` via fetch.
- **Error propagation**: Ruby scripts should print clear error messages and exit non-zero on failure. The HTML page should handle `fetch` failure gracefully (show empty list, not crash).
- **State lifecycle risks**: If a Ruby script crashes mid-write, `db.json` could be corrupted. Write to a tempfile first, then rename atomically.
- **API surface parity**: Not applicable — no API, only static files.
- **Integration coverage**: The integration point is `db.json` format. The HTML JS and Ruby scripts must agree on the schema. The schema is defined in the brainstorm doc and CLAUDE.md.

## Risks & Dependencies

- **bookcover.longitood.com availability**: Third-party service may be down or change API. Mitigate with OpenLibrary covers fallback.
- **Goodreads scraping fragility**: HTML selectors will break. Mitigate by making it best-effort with clear error handling — the script works fine without Goodreads data.
- **GitHub Pages CNAME propagation**: Custom domain DNS setup is outside scope of this plan but CNAME file must be committed.
- **Font licensing**: All four fonts are SIL OFL 1.1 — compatible with any use including commercial. No risk.

## Sources & References

- **Origin document:** [specs/2026-04-25-lev-design-brainstorm.md](specs/2026-04-25-lev-design-brainstorm.md)
- **Design mockup:** [specs/palette-preview.html](specs/palette-preview.html)
- **Project conventions:** [CLAUDE.md](CLAUDE.md)
- OpenLibrary API: https://openlibrary.org/developers/api
- bookcover.longitood.com: https://bookcover.longitood.com/
- GitHub Pages SPA redirect: https://github.com/rafgraph/spa-github-pages
