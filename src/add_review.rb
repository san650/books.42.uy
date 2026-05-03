# frozen_string_literal: true

require "tempfile"
require_relative "console_ui"
require_relative "db"
require_relative "display"
require_relative "prompts"
require_relative "git"

def edit_review(current_review)
  tmpfile = Tempfile.new(["review", ".md"])
  tmpfile.write(current_review.to_s)
  tmpfile.flush
  tmpfile.close

  editor = ENV["EDITOR"] || "vim"
  success = system(editor, tmpfile.path)

  unless success
    UI.current.warn "Editor exited with an error."
    tmpfile.unlink
    return nil
  end

  content = File.read(tmpfile.path)
  tmpfile.unlink
  content.rstrip
end

def add_review_cli
  db = load_db
  books = db["books"]

  if books.empty?
    UI.current.say "No books found. Run add_book.rb first."
    exit 0
  end

  book = prompt_book_selection(books, db)

  UI.current.say ""
  UI.current.say "Selected: #{book["title"]}"
  UI.current.say ""

  new_score = prompt_score(book["score"])
  book["score"] = new_score if new_score

  new_review = edit_review(book["review"])

  if new_review.nil?
    UI.current.say "Review unchanged (editor error)."
    exit 1
  end

  book["review"] = new_review
  save_db(db)

  if new_review.empty?
    UI.current.say "Review cleared for \"#{book["title"]}\"."
  else
    UI.current.say "Review saved for \"#{book["title"]}\"."
  end

  UI.current.say "Score updated to #{new_score}/10." if new_score

  git_auto_commit("Review", book, db)
end
