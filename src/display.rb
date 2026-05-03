# frozen_string_literal: true

require_relative "authors"
require_relative "interactive_select"

def format_book_line(book, db)
  names = resolve_author_names(db, book)
  authors = names.empty? ? "Unknown" : names.join(", ")
  "#{book["title"]} — #{authors}"
end

def display_book_list(books, db)
  UI.current.say ""
  books.each { |book| UI.current.say "  #{format_book_line(book, db)}" }
  UI.current.say ""
end

# Sort books alphabetically by title (Spanish-locale-friendly), let the user
# pick one, return the selected book. The interactive selector renders the
# list itself, so callers should not also call display_book_list.
def prompt_book_selection(books, db)
  sorted = books.sort_by { |b| b["title"].to_s.unicode_normalize(:nfkd).downcase }
  items = sorted.map { |book| format_book_line(book, db) }
  idx = interactive_select(items, prompt_label: "Select a book")
  abort "\nCancelled." unless idx
  sorted[idx]
end

def format_book_title_author(book, db)
  author = resolve_author_names(db, book).first || "Unknown"
  "#{book["title"]} — #{author}"
end
