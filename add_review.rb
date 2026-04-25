#!/usr/bin/env ruby
# frozen_string_literal: true

# add_review.rb — Interactive CLI to add or edit book reviews.

require_relative "common"

trap("INT") do
  puts "\nAborted."
  exit 130
end

def edit_review(current_review)
  tmpfile = Tempfile.new(["review", ".md"])
  tmpfile.write(current_review.to_s)
  tmpfile.flush
  tmpfile.close

  editor = ENV["EDITOR"] || "vim"
  success = system(editor, tmpfile.path)

  unless success
    $stderr.puts "Editor exited with an error."
    tmpfile.unlink
    return nil
  end

  content = File.read(tmpfile.path)
  tmpfile.unlink
  content.rstrip
end

# --- Main ---

books = load_db

if books.empty?
  puts "No books found. Run add_book.rb first."
  exit 0
end

display_book_list(books)

index = prompt_selection(books)
book = books[index]

puts ""
puts "Selected: #{book["title"]}"
puts ""

new_score = prompt_score(book["score"])
book["score"] = new_score if new_score

new_review = edit_review(book["review"])

if new_review.nil?
  puts "Review unchanged (editor error)."
  exit 1
end

book["review"] = new_review

save_db(books)

if new_review.empty?
  puts "Review cleared for \"#{book["title"]}\"."
else
  puts "Review saved for \"#{book["title"]}\"."
end

if new_score
  puts "Score updated to #{new_score}/10."
end

# Auto-commit
git_auto_commit("Review", book)
