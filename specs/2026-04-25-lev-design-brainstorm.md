---
date: 2026-04-25
topic: lev-design
---

# Lev — Design Brainstorm

## What We're Building

A personal "books I've read" tracker called **Lev** (a tribute to Lev Tolstoi). Single-page web app hosted on GitHub Pages at books.42.uy. No frameworks — self-contained HTML+CSS+JS with data loaded from a JSON file. Ruby CLI scripts for adding books and reviews.

## Why "Lev"

Short, personal, memorable. Named after Lev Tolstoi, one of the user's favorite authors. Works as a brand name and as a single-letter logo mark.

## Visual Direction

**Brutalist aesthetic** with strong typographic hierarchy. No borders anywhere — sections separate through background color changes. Limited five-color palette with bold, intentional use of color blocks.

### Color Palette

Source: [colorhunt.co/palette/1e104e452e5aff653fffc85c](https://colorhunt.co/palette/1e104e452e5aff653fffc85c)

| Token | Hex | Role |
|-------|-----|------|
| `--c-deep` | `#1E104E` | Toolbar, primary text, dark sections |
| `--c-purple` | `#452E5A` | Secondary text, search input bg, cover column |
| `--c-orange` | `#FF653F` | Accent, high scores, accent strips, hover states |
| `--c-yellow` | `#FFC85C` | Score badges, focus states, row hover |
| `--c-white` | `#FFFFFF` | Page background |

Derived surfaces: `--surface: #F4F1F7`, `--surface-alt: #EAE5F0`

### Typography — Four Distinct Fonts

All self-hosted as WOFF2 in `assets/`. Licensed under SIL OFL 1.1.

| Role | Font | Weight | File |
|------|------|--------|------|
| Brand / toolbar | Space Mono | 700 | `space-mono-700.woff2` |
| Book titles | DM Serif Display | 400 | `dm-serif-display-400.woff2` |
| Body / metadata | Work Sans | 400, 600 | `work-sans-{400,600}.woff2` |
| Data / ISBN / scores | JetBrains Mono | 700 | `jetbrains-mono-700.woff2` |

### Logo / Favicon

Bold serif "L" on deep purple square with orange bottom stripe. File: `assets/logo.svg`, 32x32 viewBox.

## Layout Decisions

- **No borders** — background color shifts create visual separation between sections
- **Desktop**: app centered, max-width 640px
- **Mobile-first** responsive design
- **Toolbar**: deep purple background, "Lev" brand + logo on left, search input fills remaining space with white background (turns yellow on focus)
- **Orange accent strip** (4px) below toolbar
- **Book list rows**: alternating white/surface backgrounds, full yellow on hover
- **Score column**: right-aligned, mono font, orange fill for scores >= 9
- **Footer**: purple background with copyright, MIT license, and GitHub link

## Interactions

- **Book row hover**: yellow background fill, score inverts to deep purple on yellow
- **Search focus**: input background turns yellow
- **Modal open**: `<dialog>` with scale-up fade (CSS only)
- **Modal close**: click outside backdrop, ESC key, or close button

## Book Detail Modal (`<dialog>`)

- **Header**: deep purple, title in DM Serif, original title in italic below, ESC button
- **Orange accent strip** below header
- **Body grid**: cover in purple column (left), metadata rows on right (alternating backgrounds)
- **Author strip**: orange text, surface background
- **Metadata rows**: label (mono, uppercase) + value pairs
- **Score strip**: large mono number in orange block + label
- **Review block**: deep purple background, yellow label, white DM Serif text
- **Mobile**: modal fills entire viewport, grid stacks vertically

## Data Schema

```json
{
  "id": 1,
  "title": "Cien anos de soledad",
  "original_title": "One Hundred Years of Solitude",
  "first_publishing_date": "1967",
  "publish_dates": ["1967-06-05"],
  "authors": [{"name": "Gabriel Garcia Marquez", "aliases": ["Gabo"]}],
  "identifiers": [{"type": "ISBN", "value": "978-0-06-088328-7"}],
  "covers": [{"file": "covers/1-cien-anos-de-soledad.jpg", "default": true}],
  "publisher": "Editorial Sudamericana",
  "score": 9,
  "review": ""
}
```

## Search

- Fuzzy search across: title, original_title, authors[].name
- Real-time filtering as user types
- Sorted alphabetically by title

## Project Structure

```
index.html          — self-contained HTML+CSS+JS
db.json             — book data
add_book.rb         — CLI to add books (fetches metadata from OpenLibrary/Goodreads)
add_review.rb       — CLI to add/edit reviews via $EDITOR
assets/             — fonts (woff2), logo.svg
covers/             — book cover images
specs/              — design docs
CLAUDE.md           — project conventions
README.md           — project description
LICENSE             — MIT
.gitignore          — temp files, .claude/
404.html            — redirects to index for GitHub Pages SPA
CNAME               — books.42.uy
```

## Deployment

- GitHub Pages with custom domain books.42.uy
- 404.html redirects to index.html (SPA routing)
- CNAME file for custom domain

## Open Questions

- None — ready to plan and implement.

## Next Steps

Run `/ce:plan` for implementation details.
