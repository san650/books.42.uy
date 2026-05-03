# frozen_string_literal: true

require_relative "authors"
require_relative "interactive_select"

def format_book_line(book, index, db)
  marker = book["review"].to_s.strip.empty? ? " " : "*"
  names = resolve_author_names(db, book)
  author = names.first || "Unknown"
  score  = book["score"] || "?"

  parts = [book["title"]]
  subtitle = book["subtitle"].to_s
  parts << subtitle unless subtitle.empty?
  parts << author
  label = parts.join(" — ")

  saga = book["saga"]
  saga_tag = saga ? " [#{saga["name"]} ##{saga["order"]}]" : ""

  format("[%s] %2d. %s (%s/10)%s", marker, index + 1, label, score, saga_tag)
end

def display_book_list(books, db)
  UI.current.say ""
  books.each_with_index do |book, i|
    UI.current.say "  #{format_book_line(book, i, db)}"
  end
  UI.current.say ""
end

def prompt_book_selection(books, db)
  items = books.each_with_index.map { |book, i| format_book_line(book, i, db) }
  idx = interactive_select(items, prompt_label: "Select a book")
  abort "\nCancelled." unless idx
  idx
end

def format_book_title_author(book, db)
  author = resolve_author_names(db, book).first || "Unknown"
  "#{book["title"]} — #{author}"
end
