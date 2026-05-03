---
date: 2026-05-03
topic: add-book-multi-source
---

# Add-Book Multi-Source Search & Per-Field Picker

## What We're Building

Two related changes:

1. **Generalize `isbn_lookup.rb` into a `lookup.rb` script** that accepts either an ISBN (10/13) or a free-text query (e.g. a book title). The script auto-detects the input type, queries the appropriate sources, and emits the standardized JSON shape (mirroring `db.json`) that `isbn_lookup.rb` already returns today.
2. **Rewrite `add_book.rb`'s search/review flow** so that, instead of a single "pick one source, take all its fields" path, the user picks the **best value per field** from the union of all sources. Empty input at the first prompt skips lookup entirely and falls through to manual entry.

## Why This Approach

The current `add_book.rb` is "winner takes all": pick one Goodreads result, take its title/author/ISBN/publisher as-is, then fall back to OpenLibrary only if Goodreads fails. In practice each source is good at different fields (Goodreads has saga + original title, Google Books has clean publisher metadata, OpenLibrary has ISBN coverage and reliable cover scans). Per-field selection lets the user cherry-pick the best value without manual re-typing.

Combining (1) and (2) keeps the lookup logic in one place: `lookup.rb` is the single source of book metadata, and `add_book.rb` is purely the interactive shell on top of it. The standardized shape we already designed for `isbn_lookup.rb` becomes the canonical contract.

## Key Decisions

### Lookup script (renamed `lookup.rb`)

- **Input dispatch**: detect ISBN by stripping spaces/dashes and checking the `\A(\d{9}[\dXx]|\d{13})\z` pattern (existing `normalize_isbn` logic). Anything else is treated as a free-text title query.
- **ISBN path** (existing): Google Books `q=isbn:<ISBN>` + OpenLibrary `bibkeys=ISBN:<ISBN>`.
- **Title-query path** (new): three sources to evaluate —
  - Google Books `q=<title>` (JSON API, already supports title search)
  - OpenLibrary `search.json?title=<title>` (JSON API, already used in `add_book.rb`)
  - **OpenLibrary HTML search** (`https://openlibrary.org/search?q=<title>`) — scrape, since the HTML page sometimes surfaces editions the JSON API ranks lower. Follows the existing precedent of HTML scraping with `decode_html` + regex.
- **Output**: same shape as today, but the top-level keys reflect *which* sources returned data. ISBN path → `{ "googlebooks": {...}, "openlibrary": {...} }`. Title path → `{ "googlebooks": [...], "openlibrary_api": [...], "openlibrary_html": [...] }` (arrays of standardized records, since title search returns multiple hits).
- **Make target**: rename `make isbn` → `make lookup`. Keep `make isbn` as a deprecated alias for one or two iterations.
- **File rename**: `scripts/isbn_lookup.rb` → `scripts/lookup.rb`. Update `Makefile` and the `make isbn` line in `CLAUDE.md`.

### `add_book.rb` flow

1. **Prompt for lookup string** (ISBN or title). **Empty input → skip lookup**; jump straight to manual entry with empty defaults for every field.
2. **Run `lookup.rb` internally** (call the Ruby functions directly via `require_relative "lookup"`, not shell out). Collect every record returned by every source into a flat list of `(source_label, record)` pairs.
3. **Per-field selector**. For each field on the book schema (`title`, `subtitle`, `authors`, `publisher`, `first_publishing_date`, `publish_dates`, `identifiers`, `cover_url`, `saga`, `original_title`):
   - Build the option list as the **deduplicated** values from all source records for that field.
   - Each option is rendered with provenance: `El Color De La Magia (ISBN: 9788445000000, Source: OpenLibrary API)`.
   - Add an `Other: ___` option that prompts for a custom value via Readline.
   - Add an `Empty` option that explicitly clears the field. (Required fields like `title` either omit `Empty` or re-prompt if it's chosen.)
   - If **no** source produced any value for the field, skip the picker and ask via plain `prompt(...)` (current behaviour). Empty input = missing.
4. **Publisher special case**: the option list is always `publishers.txt` ∪ source-derived values, plus `Other: ___` and `Empty`. If any source returned a publisher, **pre-select** it in the list (the existing `select_publisher` already supports `default:`). Custom values entered via `Other` are appended to `publishers.txt` (existing `add_publisher` helper).
5. **Authors**: each source returns an array. Flatten + dedupe across sources. Picker is multi-select (current author selection logic already does this with comma-separated input — keep it, but show provenance per name).
6. **Identifiers**: source records have `[{type, value}]`. Aggregate across sources, dedupe by `(type, value)`. Picker is multi-select (let the user keep both ISBN_10 and ISBN_13 if they want).
7. **Cover**: pick from the list of cover URLs returned across sources. Download via the existing `download_cover` helper. Add an `Other URL: ___` option and an `Empty` (no cover) option.
8. **Saga / `original_title`**: today only Goodreads provides these. With the rewrite, Goodreads stays as a source (its scraper still runs and contributes records). If only Goodreads has a value, the picker still shows it — same code path, no special case.

### Source labelling in option text

Format: `<value> (<key fields>, Source: <Label>)`. Labels:

- `Goodreads`
- `Google Books`
- `OpenLibrary API`
- `OpenLibrary HTML`

Key fields shown alongside the value should be whatever disambiguates similar-looking records — for `title` show ISBN; for `authors` show title; for `publisher` show ISBN + year. Keep it short, single-line.

## Resolved Decisions

- **Goodreads lives in `lookup.rb`** (or `common.rb` if shared with other scripts). All five sources are unified behind a single lookup interface — `add_book.rb` does not query any source directly.
- **Wikipedia is a fifth source**, language-aware. Detect the book's language from result metadata (e.g. Google Books `volumeInfo.language`); query `es.wikipedia.org` or `en.wikipedia.org` accordingly. Fall back to Spanish if no language is detected. Wikipedia results feed the per-field picker the same way as the other sources.
- **Multi-select picker** for fields where multi-select makes semantic sense: `authors`, `identifiers`, `publish_dates`. Implemented by extending `interactive_select` with space-to-toggle + enter-to-confirm (rendered as checkboxes). Single-select stays for `title`, `subtitle`, `original_title`, `publisher`, `first_publishing_date`, `saga`, `cover_url`.

## Open Questions

- **Caching lookup results**: each `add_book` run hits 5 APIs. Worth caching the JSON responses in `/tmp` keyed by query? **Probably YAGNI for now** — interactive use is low-volume.

## Next Steps

→ Implement `lookup.rb` with title-query dispatch and the OpenLibrary HTML search. Confirm shape parity with `isbn_lookup.rb` for ISBN inputs.
→ Refactor `add_book.rb` to consume `lookup.rb`'s output and drive a per-field picker. Start with the no-lookup (empty input) path so manual entry still works while the picker is being built.
→ Decide on Goodreads' home (lookup vs. add_book) before wiring the picker, since it's the only source for `saga` / `original_title` today.
