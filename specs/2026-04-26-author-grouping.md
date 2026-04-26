# Author Grouping Toggle Spec

## Goal

Add a minimalist option to switch the book list between the current title/saga organization and a new author-grouped organization.

The app should remember the selected grouping mode in `localStorage`.

## Decisions

- Default mode remains the existing title-ordered list with saga groups.
- Author mode groups books by author using the same visual treatment as saga groups.
- Books with multiple authors appear once under each author group.
- The grouping mode persists across refreshes using `localStorage`.
- The UI uses a small action link in the list metadata strip:
  - Title mode shows `Group by author`.
  - Author mode shows `List by title`.

## Proposed Solutions

### Solution 1: Inline Action Link In The Metadata Strip

Place a small text action between the count and the score label.

Title mode:

```text
42 BOOKS        GROUP BY AUTHOR        MY SCORE
```

Author mode:

```text
46 ROWS         LIST BY TITLE          MY SCORE
```

On narrow mobile screens, the action wraps under the count/score row:

```text
42 BOOKS        MY SCORE
GROUP BY AUTHOR
```

Pros:

- Minimal visual footprint.
- Keeps list organization controls next to list metadata.
- Avoids crowding the search toolbar.
- Discoverable enough because the action is always visible.

Cons:

- Less explicit than a segmented control because only the available action is shown, not both modes.

### Solution 2: Segmented Control In The Metadata Strip

Place a two-option control between count and score label:

```text
42 BOOKS        [TITLE  AUTHOR]        MY SCORE
```

Pros:

- Very explicit current mode.
- Easy to understand at a glance.

Cons:

- Visually heavier.
- Takes more horizontal space on mobile.
- Feels less minimalist than the rest of the UI.

### Solution 3: Overflow/Settings Button

Place a small `...` or similar control in the metadata strip that opens grouping options.

Pros:

- Cleanest default surface.
- Scales if more list options are added later.

Cons:

- Least discoverable.
- Adds menu behavior for only one option.
- More implementation complexity for a tiny feature.

## Recommendation

Use Solution 1: the inline action link in the metadata strip.

It matches the requested minimalist direction while keeping the feature visible. It also preserves the toolbar as a dedicated brand/search area.

## Data And Sorting Behavior

### Title Mode

Keep the existing behavior:

- Standalone books sort alphabetically by title.
- Saga books group by `book.saga.name`.
- Saga groups sort by saga name among standalone titles.
- Books inside a saga group sort by `book.saga.order`, then title.

### Author Mode

Build author groups from `book.author_ids`.

- Each author group header uses the author name.
- Groups sort alphabetically by author name using Spanish locale sorting.
- Books inside each author group sort alphabetically by title.
- A book with multiple authors appears in each author group.
- Books without known authors appear in an `Unknown Author` group.
- The count label should reflect visible rows, since multi-author books may appear more than once:
  - `1 row`
  - `46 rows`

## UI Changes

### HTML

- Add an action link or button to the list metadata strip.
- Keep the control semantic and keyboard accessible.
- Reuse the existing group header/end templates where possible, or rename them if they become generic.

### CSS

- Add a minimal metadata-strip action style.
- Preserve the no-border, no-radius, no-shadow design system.
- On mobile, allow the action to wrap below the count and score label.
- Reuse the saga group visual style for author headers:
  - Purple background.
  - Brand font.
  - Yellow group name.
  - Muted white count.
  - Orange end separator.

### JavaScript

- Add grouping mode state:
  - `title`
  - `author`
- Read initial mode from `localStorage`.
- Save mode changes to `localStorage`.
- Toggle mode when the metadata action is clicked.
- Update the action text based on current mode:
  - `Group by author`
  - `List by title`
- Refactor rendering so title mode and author mode produce grouped entries through separate functions.
- Keep keyboard navigation based on the visible row list.
- In author mode, a repeated multi-author book row should open the same detail dialog as the original book.
- Search should filter first, then apply the selected grouping mode to matching books.

## Implementation Steps

1. Update the metadata strip markup with the minimal grouping action.
2. Generalize the saga templates/classes enough to support both saga and author groups without changing the visual design.
3. Add grouping-mode state with `localStorage` persistence.
4. Split entry building into title-mode and author-mode functions.
5. Update `renderBooks` to render the selected grouping mode and maintain the visible row list for keyboard/dialog navigation.
6. Update search handling to preserve the selected grouping mode after filtering.
7. Verify manually in the in-app browser:
   - Default title/saga mode.
   - Toggle to author mode.
   - Refresh persistence.
   - Search while in author mode.
   - Multi-author books appear in each author group.
   - Keyboard navigation and detail navigation still work.
   - Mobile wrapping of the action link.

## Acceptance Criteria

- The app opens in the last selected grouping mode.
- The default first-time mode is the current title/saga list.
- Clicking `Group by author` switches to author grouping.
- Clicking `List by title` returns to title/saga listing.
- Author groups visually match saga groups.
- Multi-author books appear under each author.
- Search results use the active grouping mode.
- Keyboard row navigation opens the expected visible row.
- No external libraries or fonts are added.
- Existing unrelated files, including `publishers.txt`, are not modified.
