---
date: 2026-05-03
topic: isbn-lookup
---

# ISBN Lookup Script

## What We're Building

A standalone Ruby script `scripts/isbn_lookup.rb` that takes an ISBN (10 or 13 digits, with or without dashes/spaces) and queries two services in parallel — the Google Books API and the isbnsearch.org HTML page — then prints a human-readable summary to stderr and a combined JSON document to stdout.

The script does not mutate `db.json`, does not auto-commit, and is not wired into the interactive `add_book.rb` workflow. It is a debugging/exploration tool for spot-checking ISBN coverage across these two sources. Code is structured so the lookup functions can later be lifted into `common.rb` if we decide to integrate them.

## Why This Approach

We considered three roles (standalone tool, future building block for `add_book.rb`, eventual replacement for Goodreads scraping). Settled on **standalone tool** because the spec is purely "fetch + print" with no DB integration, and we want to evaluate the data quality of these sources before committing to wiring them in. Keep it small, dump JSON, iterate.

For HTML parsing on isbnsearch.org we follow the existing codebase precedent: regex + `decode_html` + `strip_tags` from `common.rb`. No `nokogiri`. Consistent with how Goodreads is scraped.

## Key Decisions

- **CLI**: `ruby scripts/isbn_lookup.rb <ISBN>`. Single positional arg. ISBN is normalized by stripping spaces/dashes; must be 10 or 13 digits (with `X` allowed for ISBN-10 checksum). Invalid input → exit 1 with a usage message on stderr.
- **Output**: human-readable summary on **stderr** (title, authors, publisher, large thumbnail URL — per service); JSON on **stdout**. Pipeable to `jq`.
- **JSON shape**: `{ "isbnsearch": {...}, "googlebooks": {...} }`. **Omit** keys for services that return 404 / no match. If both services fail to find anything, exit 1 with `{}` on stdout and an error message on stderr. Network/5XX exhaustion after retries is treated the same as "not found" for that service.
- **Retry/backoff**: 3 retries on **5XX status codes and network errors** (timeout, connection reset). Exponential backoff: 1s, 2s, 4s. **No retry** on 4XX (404 = book not found, not a transient failure). Implemented as a new helper `http_get_with_retry` in `common.rb` (reusable; existing `http_get` stays unchanged for callers that don't want retry).
- **Google Books**: `GET https://www.googleapis.com/books/v1/volumes?q=isbn:<ISBN>`. If `items` has multiple entries, filter to the one whose `volumeInfo.industryIdentifiers[].identifier` matches the queried ISBN exactly. Apply the same filter even when only 1 item is returned (defensive — confirms we got what we asked for). Extract: `title`, `authors[]`, `publisher`, `imageLinks.thumbnail` (large thumbnail — note the API returns `smallThumbnail` and `thumbnail`; we use `thumbnail`, which is the larger of the two).
- **isbnsearch.org**: `GET https://isbnsearch.org/isbn/<ISBN>`. 404 → key omitted. 200 → parse HTML for ISBN-13, ISBN-10, Author, Publisher, and the cover image URL. Use the existing `USER_AGENT` constant; isbnsearch may block default Ruby UA.
- **File location**: `scripts/isbn_lookup.rb`. `require_relative "common"`.
- **Make target**: `make isbn` → invokes the script. Since it takes an arg, the target will be `make isbn ISBN=9788418107832` (Makefile-style) or just document that it takes an arg via `ruby scripts/isbn_lookup.rb <ISBN>`. Decide during implementation.
- **Test ISBN**: `9788418107832` — confirmed by user as a known-good case for both services.

## Open Questions

- `make isbn` invocation form — env var (`make isbn ISBN=...`) vs positional vs no make target. Resolve during implementation.
- Whether to also expose a `--json-only` flag that suppresses the stderr summary, for purely scripted use. **YAGNI for now** — pipe stderr to `/dev/null` if you want this.

## Next Steps

→ Implement `scripts/isbn_lookup.rb` and `http_get_with_retry` helper in `common.rb`. Test against ISBN `9788418107832`.
