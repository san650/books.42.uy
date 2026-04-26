#!/usr/bin/env ruby
# frozen_string_literal: true

# score_books.rb — Relative score review for already-rated books.

require_relative "common"

COMPARISON_COUNT = 10
COMPARISON_CHOICES = [
  { label: "Second is better", key: "b", value: :better },
  { label: "Similar", key: "s", value: :similar },
  { label: "Second is worse", key: "w", value: :worse }
].freeze

trap("INT") do
  puts "\nAborted."
  exit 130
end

def random_pair(books)
  books.sample(2)
end

def comparison_consistent?(comparison)
  first_score = comparison[:first]["score"]
  second_score = comparison[:second]["score"]

  case comparison[:result]
  when :better then second_score > first_score
  when :similar then second_score == first_score
  when :worse then second_score < first_score
  else false
  end
end

def result_label(result)
  case result
  when :better then "better"
  when :similar then "similar"
  when :worse then "worse"
  else result.to_s
  end
end

def empty_summary
  {
    better_than: 0,
    worse_than: 0,
    similar_to: 0,
    inconsistencies: 0
  }
end

def build_book_summaries(comparisons)
  summaries = Hash.new { |hash, key| hash[key] = empty_summary }

  comparisons.each do |comparison|
    first_id = comparison[:first]["id"]
    second_id = comparison[:second]["id"]

    case comparison[:result]
    when :better
      summaries[second_id][:better_than] += 1
      summaries[first_id][:worse_than] += 1
    when :similar
      summaries[first_id][:similar_to] += 1
      summaries[second_id][:similar_to] += 1
    when :worse
      summaries[first_id][:better_than] += 1
      summaries[second_id][:worse_than] += 1
    end

    next if comparison_consistent?(comparison)

    summaries[first_id][:inconsistencies] += 1
    summaries[second_id][:inconsistencies] += 1
  end

  summaries
end

def run_comparisons(books, db)
  comparisons = []

  COMPARISON_COUNT.times do |idx|
    first, second = random_pair(books)

    puts "\n"
    puts "=" * 50
    puts "  Comparison #{idx + 1}/#{COMPARISON_COUNT}"
    puts "=" * 50
    puts "First:  #{format_book_title_author(first, db)}"
    puts "Second: #{format_book_title_author(second, db)}"
    puts ""
    puts "Is the second book better, similar, or worse than the first?"

    choice = interactive_choice(COMPARISON_CHOICES, prompt_label: "Compare")
    abort "\nCancelled." unless choice

    comparisons << {
      first: first,
      second: second,
      result: choice[:value]
    }
  end

  comparisons
end

def picked_books(comparisons)
  comparisons.flat_map { |comparison| [comparison[:first], comparison[:second]] }
             .uniq { |book| book["id"] }
             .sort_by { |book| book["title"].unicode_normalize(:nfkd).downcase }
end

def print_session_books(books, db, summaries)
  puts "\n"
  puts "=" * 50
  puts "  Books in this session"
  puts "=" * 50

  books.each_with_index do |book, idx|
    summary = summaries[book["id"]]
    puts ""
    puts format("  %2d. %s (%s/10)", idx + 1, format_book_title_author(book, db), book["score"])
    puts "      Better than: #{summary[:better_than]} | " \
         "Worse than: #{summary[:worse_than]} | " \
         "Similar to: #{summary[:similar_to]} | " \
         "Inconsistencies: #{summary[:inconsistencies]}"
  end
end

def print_inconsistencies(comparisons, db)
  inconsistent = comparisons.reject { |comparison| comparison_consistent?(comparison) }

  puts "\n"
  puts "=" * 50
  puts "  Score inconsistencies"
  puts "=" * 50

  if inconsistent.empty?
    puts "\n  No inconsistencies found in this session."
    return
  end

  inconsistent.each_with_index do |comparison, idx|
    first = comparison[:first]
    second = comparison[:second]
    puts ""
    puts "  #{idx + 1}. You said the second book is #{result_label(comparison[:result])}:"
    puts "     First:  #{format_book_title_author(first, db)} (#{first["score"]}/10)"
    puts "     Second: #{format_book_title_author(second, db)} (#{second["score"]}/10)"
  end
end

def edit_scores(books, db, summaries)
  changed = false

  puts "\n"
  puts "=" * 50
  puts "  Update scores"
  puts "=" * 50
  puts "Press enter to keep a score unchanged."

  books.each do |book|
    summary = summaries[book["id"]]
    puts ""
    puts "#{format_book_title_author(book, db)}"
    puts "  Current score: #{book["score"]}/10"
    puts "  Better than: #{summary[:better_than]} | " \
         "Worse than: #{summary[:worse_than]} | " \
         "Similar to: #{summary[:similar_to]} | " \
         "Inconsistencies: #{summary[:inconsistencies]}"

    new_score = prompt_score_update(book["score"])
    next unless new_score && new_score != book["score"]

    book["score"] = new_score
    changed = true
  end

  changed
end

def main
  puts "=" * 50
  puts "  Lev — Relative Book Scoring"
  puts "=" * 50

  db = load_db
  books = db["books"]
  scored_books = books.select { |book| numeric_score?(book) }

  if scored_books.size < 2
    puts "\nAt least two books with numeric scores are required."
    exit 0
  end

  comparisons = run_comparisons(scored_books, db)
  summaries = build_book_summaries(comparisons)
  session_books = picked_books(comparisons)

  print_session_books(session_books, db, summaries)
  print_inconsistencies(comparisons, db)

  if edit_scores(session_books, db, summaries)
    save_db(db)
    git_commit_paths(DB_PATH, "Reranking books")
    puts "\nScores saved."
  else
    puts "\nNo score changes to save."
  end
end

begin
  main
rescue Interrupt
  puts "\n\nCancelled."
  exit 1
rescue StandardError => e
  warn "\nError: #{e.message}"
  warn e.backtrace.first(5).map { |line| "  #{line}" }.join("\n")
  exit 1
end
