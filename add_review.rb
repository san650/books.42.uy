#!/usr/bin/env ruby
# frozen_string_literal: true

# add_review.rb — Interactive CLI to add or edit book reviews.
# Self-contained, no gem dependencies beyond stdlib.

require "json"
require "tempfile"
require "fileutils"

DB_PATH = File.join(__dir__, "db.json")

trap("INT") do
  puts "\nAborted."
  exit 130
end

def load_books
  unless File.exist?(DB_PATH)
    $stderr.puts "db.json not found. Run add_book.rb first."
    exit 1
  end

  raw = File.read(DB_PATH)
  books = JSON.parse(raw)

  unless books.is_a?(Array)
    $stderr.puts "db.json is malformed (expected an array)."
    exit 1
  end

  books
end

def display_book_list(books)
  puts ""
  books.each_with_index do |book, i|
    marker = book["review"].to_s.strip.empty? ? " " : "*"
    author = book.dig("authors", 0, "name") || "Unknown"
    score  = book["score"] || "?"
    printf "  [%s] %2d. %s — %s (%s/10)\n", marker, i + 1, book["title"], author, score
  end
  puts ""
end

def prompt_selection(books)
  loop do
    print "Select a book (1-#{books.length}): "
    input = $stdin.gets
    if input.nil?
      puts ""
      exit 130
    end
    input = input.strip
    next if input.empty?

    num = input.to_i
    if num >= 1 && num <= books.length
      return num - 1
    end

    puts "Invalid selection. Please enter a number between 1 and #{books.length}."
  end
end

def prompt_score(current_score)
  print "Update score? (current: #{current_score || "none"}) [enter to skip]: "
  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  input = input.strip
  return nil if input.empty?

  score = input.to_i
  if score >= 1 && score <= 10
    score
  else
    puts "Score must be 1-10. Keeping current score."
    nil
  end
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

def save_books(books)
  sorted = books.sort_by { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }

  json = JSON.pretty_generate(sorted, indent: "  ")

  tmpfile = Tempfile.new(["db", ".json"], File.dirname(DB_PATH))
  tmpfile.write(json)
  tmpfile.write("\n")
  tmpfile.flush
  tmpfile.close

  FileUtils.mv(tmpfile.path, DB_PATH)
end

# --- Main ---

books = load_books

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

save_books(books)

if new_review.empty?
  puts "Review cleared for \"#{book["title"]}\"."
else
  puts "Review saved for \"#{book["title"]}\"."
end

if new_score
  puts "Score updated to #{new_score}/10."
end
