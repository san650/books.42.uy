---
title: "feat: Add relative book scoring CLI"
type: feat
status: implemented
date: 2026-04-26
---

# feat: Add relative book scoring CLI

## Overview

Add a Ruby CLI command, `make score`, that helps re-score already-rated books through relative comparisons. The script will randomly present two different scored books, ask whether the second book is better, similar, or worse than the first, repeat this for 10 pairings, report score inconsistencies, and then let the user update the scores of all books that appeared during the session.

The script will live at `scripts/score_books.rb`. Shared terminal and scoring helpers that are useful beyond this script will be added to `scripts/common.rb`.

## Confirmed Decisions

- The session runs 10 random pairings.
- A book cannot be paired with itself.
- A book can appear in multiple pairings across the same session.
- Only books with a numeric `score` are eligible.
- "Similar" means both books should have exactly the same score.
- "Better" and "worse" require strict score ordering.
- Equal scores are inconsistent when one book was marked better or worse.
- At the final editing step, all books that appeared in the session are editable.
- Changes are saved to `docs/db.json`.
- The script auto-commits with the exact commit message `Reranking books`.
- During comparisons, show title and author only.
- During final score editing, show all picked books with current score and comparison summary.
- Input should support both quick keys and arrow-key selection.
- There is no skip option.

## Three Solution Options

### Option 1: Session-Only Pairwise Audit

The script records only the 10 comparisons made in the current run. It compares those answers against current numeric scores, reports contradictions, then prompts for updated scores for every book seen in the session.

Pros:
- Simple and predictable.
- No new data files or schema changes.
- Fits the current scripts' style.
- Easy to reason about and test.

Cons:
- It learns nothing across sessions.
- It may ask similar comparisons in future runs.

### Option 2: Persisted Comparison History

The script writes every comparison to a history file such as `resources/scoring-history.json`. Future sessions can avoid repeated comparisons, prioritize unresolved contradictions, and build a richer consistency graph over time.

Pros:
- More powerful over repeated use.
- Can surface long-term ranking drift.
- Supports future features like "show all contradictions ever observed."

Cons:
- Adds another persisted data source.
- More edge cases around changed scores, renamed books, deleted books, and stale history.
- More implementation and maintenance for a personal workflow that may not need it yet.

### Option 3: Adaptive Tournament Pool

The script starts with random pairs, but then biases later pairings toward books involved in contradictions or close score bands. It behaves like a mini ranking tournament inside one session.

Pros:
- More likely to find useful inconsistencies within 10 comparisons.
- Repeated appearances become more intentional.

Cons:
- Less transparent than pure randomness.
- Slightly harder to predict and test.
- Could feel like the script is oversteering the user's taste instead of just collecting judgments.

## Recommendation

Use **Option 1: Session-Only Pairwise Audit** for the first implementation.

It best matches the requested workflow: lightweight, terminal-native, no new persistent state, and focused on improving the current scores in `db.json`. It also leaves room to add history later without backing out any core behavior.

## User Flow

1. User runs `make score`.
2. Script loads `docs/db.json`.
3. Script filters eligible books to those with numeric scores.
4. If fewer than two scored books exist, the script exits with a helpful message.
5. Script runs 10 comparison rounds.
6. Each round prints:
   - round number, e.g. `Comparison 3/10`
   - Book A title and author
   - Book B title and author
   - prompt: `Is the second book better, similar, or worse than the first?`
7. User can answer with:
   - quick keys: `b`, `s`, `w`
   - arrow-key selector and Enter
8. Script records the comparison.
9. After 10 rounds, script prints:
   - all books picked in this session
   - current score for each picked book
   - comparison summary for each picked book
   - inconsistent comparisons
10. Script prompts through every picked book and lets the user update its score.
11. If any score changed:
   - save `docs/db.json`
   - run `git add docs/db.json`
   - run `git commit -m "Reranking books"`
12. If no score changed, print that no changes were saved.

## Consistency Rules

Each comparison is stored from the prompt's perspective:

- Book A is the first book.
- Book B is the second book.
- User answers whether Book B is better, similar, or worse than Book A.

Rules:

- `better`: Book B score must be greater than Book A score.
- `similar`: Book B score must equal Book A score.
- `worse`: Book B score must be less than Book A score.

Any comparison that violates its rule is reported as inconsistent.

Examples:

- A: 7, B: 8, answer `better` -> consistent.
- A: 7, B: 7, answer `better` -> inconsistent.
- A: 8, B: 7, answer `similar` -> inconsistent.
- A: 8, B: 7, answer `worse` -> consistent.

## Comparison Summary

For each book that appeared in the session, show:

- title
- author
- current score
- number of times it was judged better than another book
- number of times it was judged worse than another book
- number of times it was judged similar to another book
- number of inconsistent comparisons involving that book

Example display shape:

```text
Books in this session:

  1. Dune — Frank Herbert (8/10)
     Better than: 2 | Worse than: 1 | Similar to: 0 | Inconsistencies: 1

  2. Mort — Terry Pratchett (7/10)
     Better than: 1 | Worse than: 1 | Similar to: 1 | Inconsistencies: 0
```

## Terminal Input Design

The comparison prompt should support both quick keys and arrow-key selection.

Implementation approach:

- Add a reusable helper to `scripts/common.rb`, likely named `interactive_choice`.
- It accepts labels with optional hotkeys, such as:
  - `Better`, hotkey `b`
  - `Similar`, hotkey `s`
  - `Worse`, hotkey `w`
- It renders like the existing `interactive_select`.
- Arrow Up/Down moves the selection.
- Enter confirms the highlighted option.
- Pressing a hotkey immediately returns that option.
- Ctrl-C exits with status 130.

This keeps the existing terminal style while adding fast one-key input.

## Score Editing Design

For each picked book:

- Show title, author, current score, and summary.
- Prompt for a new score using a reusable score prompt.
- Enter keeps the current score.
- Valid scores are integers 1 through 10.
- Invalid values re-prompt instead of silently keeping the score.

This may require adding a stricter reusable score helper to `scripts/common.rb`, because the existing `prompt_score` prints a message and returns `nil` on invalid input.

## Files

### Modify: `Makefile`

Add:

```make
score:
	ruby scripts/score_books.rb
```

Update `.PHONY` to include `score`.

### Create: `scripts/score_books.rb`

Responsibilities:

- Load DB.
- Select eligible scored books.
- Generate 10 random non-self pairings.
- Render comparison prompts.
- Record session comparisons.
- Detect inconsistencies.
- Summarize picked books.
- Prompt for score updates.
- Save DB if needed.
- Commit score changes with `Reranking books`.

### Modify: `scripts/common.rb`

Candidate reusable helpers:

- `format_book_title_author(book, db)` -> `"Title — Author"`
- `numeric_score?(book)` -> boolean
- `interactive_choice(choices, prompt_label:)` -> selected value with arrow keys and hotkeys
- `prompt_score_update(current_score)` -> valid 1-10 integer or nil for unchanged
- `git_commit_paths(paths, message)` -> small generic commit helper

Keep helpers minimal and only extract what is actually reused or clearly common.

## Implementation Notes

- Use Ruby stdlib only.
- Follow current script structure:
  - shebang
  - `# frozen_string_literal: true`
  - `require_relative "common"`
  - `trap("INT")`
  - small helper methods
  - `main`
  - guarded entry point with error handling
- Preserve `docs/db.json` formatting via `save_db(db)`.
- Do not change the DB schema.
- Do not create scoring history files in this first version.
- Random pairing can use Ruby's default `sample(2)` over eligible books.
- The same pair may appear more than once unless future refinement decides otherwise.

## Verification Plan

Manual CLI checks:

- `make score` starts the script.
- Script exits clearly when fewer than two numeric scores exist.
- No comparison pairs a book with itself.
- Books can repeat across rounds.
- Quick keys `b`, `s`, `w` work.
- Arrow-key selection and Enter work.
- Inconsistency reporting matches the rules.
- Final score editor shows every unique picked book.
- Enter keeps a score unchanged.
- Invalid scores re-prompt.
- Changed scores are saved to `docs/db.json`.
- Commit message is exactly `Reranking books`.

Code checks:

- `ruby -c scripts/score_books.rb`
- `ruby -c scripts/common.rb`
- `make format`

## Acceptance Criteria

- Running `make score` performs exactly 10 required comparisons between two different numeric-scored books.
- User can answer each comparison with either hotkeys or arrow-key selection.
- The script reports inconsistent current scores according to the recorded comparisons.
- The script shows all books picked during the session before score editing.
- The score editing step includes current score and session comparison summary for each picked book.
- Changed scores are persisted to `docs/db.json`.
- Score changes auto-commit with `Reranking books`.
- No implementation begins until this spec is accepted.
