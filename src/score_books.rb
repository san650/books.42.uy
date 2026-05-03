# frozen_string_literal: true

require_relative "console_ui"
require_relative "db"
require_relative "display"
require_relative "interactive_select"
require_relative "prompts"
require_relative "git"
require_relative "constants"

COMPARISON_COUNT = 10
COMPARISON_CHOICES = [
  { label: "Second is better", key: "b", value: :better },
  { label: "Similar", key: "s", value: :similar },
  { label: "Second is worse", key: "w", value: :worse }
].freeze

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
  { better: "better", similar: "similar", worse: "worse" }.fetch(result, result.to_s)
end

def empty_summary
  { better_than: 0, worse_than: 0, similar_to: 0, inconsistencies: 0 }
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

    UI.current.say "\n"
    UI.current.say "=" * 50
    UI.current.say "  Comparison #{idx + 1}/#{COMPARISON_COUNT}"
    UI.current.say "=" * 50
    UI.current.say "First:  #{format_book_title_author(first, db)}"
    UI.current.say "Second: #{format_book_title_author(second, db)}"
    UI.current.say ""
    UI.current.say "Is the second book better, similar, or worse than the first?"

    choice = interactive_choice(COMPARISON_CHOICES, prompt_label: "Compare")
    abort "\nCancelled." unless choice

    comparisons << { first: first, second: second, result: choice[:value] }
  end

  comparisons
end

def picked_books(comparisons)
  comparisons.flat_map { |c| [c[:first], c[:second]] }
             .uniq { |book| book["id"] }
             .sort_by { |book| book["title"].unicode_normalize(:nfkd).downcase }
end

def print_session_books(books, db, summaries)
  UI.current.say "\n"
  UI.current.say "=" * 50
  UI.current.say "  Books in this session"
  UI.current.say "=" * 50

  books.each_with_index do |book, idx|
    s = summaries[book["id"]]
    UI.current.say ""
    UI.current.say format("  %2d. %s (%s/10)", idx + 1, format_book_title_author(book, db), book["score"])
    UI.current.say "      Better than: #{s[:better_than]} | " \
                   "Worse than: #{s[:worse_than]} | " \
                   "Similar to: #{s[:similar_to]} | " \
                   "Inconsistencies: #{s[:inconsistencies]}"
  end
end

def print_inconsistencies(comparisons, db)
  inconsistent = comparisons.reject { |c| comparison_consistent?(c) }

  UI.current.say "\n"
  UI.current.say "=" * 50
  UI.current.say "  Score inconsistencies"
  UI.current.say "=" * 50

  if inconsistent.empty?
    UI.current.say "\n  No inconsistencies found in this session."
    return
  end

  inconsistent.each_with_index do |comparison, idx|
    first = comparison[:first]
    second = comparison[:second]
    UI.current.say ""
    UI.current.say "  #{idx + 1}. You said the second book is #{result_label(comparison[:result])}:"
    UI.current.say "     First:  #{format_book_title_author(first, db)} (#{first["score"]}/10)"
    UI.current.say "     Second: #{format_book_title_author(second, db)} (#{second["score"]}/10)"
  end
end

def edit_scores(books, db, summaries)
  changed = false

  UI.current.say "\n"
  UI.current.say "=" * 50
  UI.current.say "  Update scores"
  UI.current.say "=" * 50
  UI.current.say "Press enter to keep a score unchanged."

  books.each do |book|
    s = summaries[book["id"]]
    UI.current.say ""
    UI.current.say format_book_title_author(book, db).to_s
    UI.current.say "  Current score: #{book["score"]}/10"
    UI.current.say "  Better than: #{s[:better_than]} | " \
                   "Worse than: #{s[:worse_than]} | " \
                   "Similar to: #{s[:similar_to]} | " \
                   "Inconsistencies: #{s[:inconsistencies]}"

    new_score = prompt_score_update(book["score"])
    next unless new_score && new_score != book["score"]

    book["score"] = new_score
    changed = true
  end

  changed
end

def score_books_cli
  UI.current.say "=" * 50
  UI.current.say "  Lev — Relative Book Scoring"
  UI.current.say "=" * 50

  db = load_db
  books = db["books"]
  scored_books = books.select { |book| numeric_score?(book) }

  if scored_books.size < 2
    UI.current.say "\nAt least two books with numeric scores are required."
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
    UI.current.say "\nScores saved."
  else
    UI.current.say "\nNo score changes to save."
  end
end
