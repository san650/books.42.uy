#!/usr/bin/env ruby
# frozen_string_literal: true

# add_book.rb — Interactive CLI to add books to db.json.
# Looks up the book across multiple sources (Google Books, OpenLibrary,
# Goodreads, Wikipedia) and lets the user pick the best value per field.

require_relative "common"
require_relative "lookup"

SOURCE_LABELS = {
  "googlebooks" => "Google Books",
  "openlibrary" => "OpenLibrary API",
  "openlibrary_html" => "OpenLibrary HTML",
  "goodreads" => "Goodreads",
  "wikipedia" => "Wikipedia"
}.freeze

# ---------------------------------------------------------------------------
# Lookup result helpers
# ---------------------------------------------------------------------------

def flatten_lookup(result)
  pairs = []
  result.each do |source, value|
    label = SOURCE_LABELS[source] || source
    if value.is_a?(Array)
      value.each { |record| pairs << [label, record] }
    elsif value.is_a?(Hash)
      pairs << [label, value]
    end
  end
  pairs
end

# Short context string for an option label, used to disambiguate similar values.
def record_context(record, exclude: nil)
  parts = []
  isbn_id = (record["identifiers"] || []).find { |id| id["type"] == "ISBN_13" } ||
            (record["identifiers"] || []).find { |id| id["type"] == "ISBN_10" }
  parts << "ISBN: #{isbn_id["value"]}" if isbn_id && exclude != :isbn
  parts << "Title: #{record["title"]}" if record["title"] && exclude != :title
  parts.first(2).join(", ")
end

# ---------------------------------------------------------------------------
# Per-field picker
# ---------------------------------------------------------------------------

# Build option list from raw candidates, dedupe by value, append source list
# and a per-record context to help the user disambiguate.
def build_options(candidates, format_value: ->(v) { v.to_s })
  grouped = {}
  candidates.each do |c|
    key = c[:value].is_a?(Hash) ? c[:value].sort.to_h : c[:value]
    grouped[key] ||= { value: c[:value], sources: [], contexts: [] }
    grouped[key][:sources] << c[:source]
    grouped[key][:contexts] << c[:context] if c[:context] && !c[:context].empty?
  end

  grouped.values.map do |g|
    sources = g[:sources].uniq
    context = g[:contexts].uniq.first
    label_parts = []
    label_parts << context unless context.nil? || context.empty?
    label_parts << "Source#{sources.size == 1 ? "" : "s"}: #{sources.join(", ")}"
    {
      value: g[:value],
      label: "#{format_value.call(g[:value])} (#{label_parts.join(", ")})"
    }
  end
end

# Run a picker for a single-value field. Returns the chosen value (or "" for
# Empty / "" when no candidates and user enters nothing).
def pick_single(field_name, candidates, format_value: ->(v) { v.to_s }, required: false, default_value: nil)
  loop do
    options = build_options(candidates, format_value: format_value)

    if options.empty?
      val = prompt(field_name, default: default_value, required: required)
      return val
    end

    items = options.map { |o| o[:label] }
    items << "Empty" unless required
    items << "Other: enter custom value"

    default_idx = if default_value
                    options.index { |o| o[:value].to_s == default_value.to_s } || 0
                  else
                    0
                  end

    puts "\n#{field_name}:"
    idx = interactive_select(items, prompt_label: field_name, default: default_idx)
    abort "\nCancelled." unless idx

    if idx < options.size
      return options[idx][:value]
    elsif !required && idx == options.size
      return ""
    else
      val = prompt("  Enter #{field_name}", required: required)
      return val
    end
  end
end

# Run a picker for a multi-value field. Returns array of chosen values.
def pick_multi(field_name, candidates, format_value: ->(v) { v.to_s }, allow_other: true)
  options = build_options(candidates, format_value: format_value)

  if options.empty?
    val = prompt("#{field_name} (comma-separated)")
    return val.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  items = options.map { |o| o[:label] }
  items << "Other: enter custom value(s) (comma-separated)" if allow_other

  puts "\n#{field_name}:"
  idxs = interactive_select(items, prompt_label: field_name, multi: true)
  abort "\nCancelled." unless idxs

  values = idxs.select { |i| i < options.size }.map { |i| options[i][:value] }

  if allow_other && idxs.include?(options.size)
    custom = prompt("  Enter custom #{field_name} (comma-separated)")
    values.concat(custom.to_s.split(",").map(&:strip).reject(&:empty?))
  end

  values
end

# ---------------------------------------------------------------------------
# Field candidate extractors
# ---------------------------------------------------------------------------

def collect_field(pairs, exclude_context: nil)
  pairs.flat_map do |source, record|
    raw = yield(record)
    Array(raw).compact.reject { |v| v.to_s.strip.empty? }.map do |v|
      { value: v, source: source, context: record_context(record, exclude: exclude_context) }
    end
  end
end

def collect_identifiers(pairs)
  pairs.flat_map do |source, record|
    (record["identifiers"] || []).map do |id|
      next nil if id["value"].to_s.strip.empty?
      { value: { "type" => id["type"], "value" => id["value"] }, source: source, context: "Title: #{record["title"]}" }
    end.compact
  end
end

def collect_sagas(pairs)
  pairs.flat_map do |source, record|
    saga = record["saga"]
    next [] if saga.nil? || saga["name"].to_s.empty?
    [{ value: { "name" => saga["name"], "order" => saga["order"] || 1 },
       source: source,
       context: "Title: #{record["title"]}" }]
  end
end

# ---------------------------------------------------------------------------
# Publisher: special case — uses publishers.txt as the option set, augmented
# with any value(s) from the lookup, plus Empty / Other.
# ---------------------------------------------------------------------------

def pick_publisher(pairs)
  source_publishers = collect_field(pairs) { |r| r["publisher"] }
  source_values = source_publishers.map { |c| c[:value] }.uniq

  publishers = load_publishers
  combined = (publishers + source_values).uniq.sort_by { |p| p.unicode_normalize(:nfkd).downcase }

  items = combined.map do |pub|
    if source_values.include?(pub)
      sources = source_publishers.select { |c| c[:value] == pub }.map { |c| c[:source] }.uniq
      "#{pub} (Source#{sources.size == 1 ? "" : "s"}: #{sources.join(", ")})"
    else
      pub
    end
  end
  items << "Empty"
  items << "Other: enter custom publisher"

  default_idx = if source_values.any?
                  combined.index(source_values.first) || 0
                else
                  combined.size  # "Empty" if no source value
                end

  puts "\nPublisher:"
  idx = interactive_select(items, prompt_label: "Publisher", default: default_idx)
  abort "\nCancelled." unless idx

  if idx < combined.size
    selected = combined[idx]
    add_publisher(selected) unless publishers.include?(selected)
    selected
  elsif idx == combined.size
    ""
  else
    name = prompt("  Enter publisher name")
    return "" if name.empty?
    add_publisher(name)
    name
  end
end

# ---------------------------------------------------------------------------
# Cover download (unchanged)
# ---------------------------------------------------------------------------

def download_cover(cover_url, isbn, book_id, title)
  FileUtils.mkdir_p(COVERS_DIR)
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  if cover_url && !cover_url.empty?
    puts "\nDownloading cover from #{cover_url}..."
    if http_download(cover_url, dest) && File.size(dest) > 1000
      puts "  Cover saved: covers/#{filename}"
      return "covers/#{filename}"
    else
      File.delete(dest) if File.exist?(dest)
      puts "  Cover download failed or too small, trying ISBN fallback..."
    end
  end

  if isbn && !isbn.empty?
    ol_url = "https://covers.openlibrary.org/b/isbn/#{URI.encode_www_form_component(isbn)}-L.jpg"
    puts "  Trying OpenLibrary ISBN cover..."
    if http_download(ol_url, dest) && File.size(dest) > 1000
      puts "  Cover saved: covers/#{filename}"
      return "covers/#{filename}"
    end
    File.delete(dest) if File.exist?(dest)
  end

  puts "  No cover available."
  nil
end

# ---------------------------------------------------------------------------
# Score / author resolution
# ---------------------------------------------------------------------------

def prompt_required_score
  loop do
    input = prompt("Score (1-10)", required: true)
    score = input.to_i
    return score if score >= 1 && score <= 10

    puts "  Please enter a number between 1 and 10."
  end
end

def resolve_author_ids(db, author_names)
  author_names.map do |name|
    existing = find_author_by_name(db, name)
    if existing
      puts "  [MATCH] #{name} -> existing author ##{existing["id"]}"
      existing
    else
      author = find_or_create_author(db, name, aliases: [])
      puts "  [NEW]   #{name} -> author ##{author["id"]}"
      author
    end
  end.map { |a| a["id"] }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Add a Book"
  puts "=" * 50

  db = load_db
  books = db["books"]

  query = ARGV.join(" ").strip
  if query.empty?
    query = prompt("\nLookup (ISBN or title; blank to enter manually)")
  else
    puts "\nLookup: #{query}"
  end

  pairs = []
  if query.empty?
    puts "\nSkipping lookup — manual entry."
  else
    result = lookup(query)
    pairs = flatten_lookup(result)
    if pairs.empty?
      puts "\nNo results from any source — manual entry."
    else
      puts "\nFound #{pairs.size} record(s) across #{pairs.map(&:first).uniq.size} source(s)."
    end
  end

  puts "\n" + "-" * 50
  puts "  Pick the best value per field"
  puts "-" * 50

  title_candidates = collect_field(pairs, exclude_context: :title) { |r| r["title"] }
  title = pick_single("Title", title_candidates, required: true)

  existing = books.find { |b| b["title"].downcase == title.downcase }
  if existing
    names = resolve_author_names(db, existing)
    author_name = names.first || "Unknown"
    puts "\n  Book already exists: \"#{existing["title"]}\" by #{author_name} (ID: #{existing["id"]})"
    puts "  To edit it, run: ruby scripts/edit_book.rb"
    exit 0
  end

  subtitle_candidates = collect_field(pairs) { |r| r["subtitle"] }
  subtitle = pick_single("Subtitle", subtitle_candidates)

  original_candidates = collect_field(pairs) { |r| r["original_title"] }
  original_title = pick_single("Original title", original_candidates)

  first_pub_candidates = collect_field(pairs) { |r| r["first_publishing_date"] }
  first_pub = pick_single("First publishing date", first_pub_candidates)

  publish_dates_candidates = collect_field(pairs) { |r| r["publish_dates"] }
  publish_dates = pick_multi("Publish dates", publish_dates_candidates)

  authors_candidates = collect_field(pairs) { |r| r["authors"] }
  author_names = pick_multi("Authors", authors_candidates)
  if author_names.empty?
    loop do
      name = prompt("Author name (blank to finish)")
      break if name.empty?
      author_names << name
    end
  end
  puts "\nMatching authors:"
  author_ids = author_names.empty? ? [] : resolve_author_ids(db, author_names)

  identifiers_candidates = collect_identifiers(pairs)
  identifiers = pick_multi("Identifiers (ISBN-10 / ISBN-13)",
                           identifiers_candidates,
                           format_value: ->(v) { "#{v["type"]}: #{v["value"]}" })
  identifiers = identifiers.map do |id|
    next id if id.is_a?(Hash)
    val = id.to_s.gsub(/[\s\-]/, "")
    type = val.length == 13 ? "ISBN_13" : (val.length == 10 ? "ISBN_10" : "ISBN")
    { "type" => type, "value" => val }
  end

  publisher = pick_publisher(pairs)

  saga_candidates = collect_sagas(pairs)
  saga = pick_single("Saga",
                     saga_candidates,
                     format_value: ->(v) { "#{v["name"]} ##{v["order"]}" })
  saga = nil if saga.is_a?(String) && saga.empty?
  if saga.is_a?(String) && !saga.empty?
    name = saga
    order_input = prompt("Order in saga (number)", required: true)
    saga = { "name" => name, "order" => order_input.to_i }
  end

  cover_candidates = collect_field(pairs) { |r| r["cover_url"] }
  cover_url = pick_single("Cover URL", cover_candidates)
  cover_url = nil if cover_url.to_s.empty?

  score = prompt_required_score

  book_id = next_id(books)
  primary_isbn = (identifiers.find { |id| id["type"] == "ISBN_13" } ||
                  identifiers.find { |id| id["type"] == "ISBN_10" })&.dig("value")

  cover_path = download_cover(cover_url, primary_isbn, book_id, title)
  covers = cover_path ? [{ "file" => cover_path, "default" => true }] : []

  book = {
    "id" => book_id,
    "title" => title,
    "subtitle" => subtitle.to_s,
    "original_title" => original_title.to_s,
    "first_publishing_date" => first_pub.to_s,
    "publish_dates" => publish_dates,
    "author_ids" => author_ids,
    "identifiers" => identifiers,
    "covers" => covers,
    "publisher" => publisher,
    "saga" => saga,
    "score" => score,
    "review" => ""
  }

  puts "\n" + "=" * 50
  puts "  Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Subtitle:    #{book["subtitle"]}" unless book["subtitle"].empty?
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].empty?
  puts "  Authors:     #{resolve_author_names(db, book).join(", ")}"
  puts "  First pub:   #{book["first_publishing_date"]}" unless book["first_publishing_date"].empty?
  puts "  Published:   #{publish_dates.join(", ")}" if publish_dates.any?
  identifiers.each { |id| puts "  #{id["type"]}:    #{id["value"]}" }
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Saga:        #{saga["name"]} ##{saga["order"]}" if saga
  puts "  Score:       #{book["score"]}/10"
  puts "  Cover:       #{cover_path || "none"}"
  puts "  ID:          #{book_id}"
  puts ""

  unless prompt_yes_no("Save this book?", default: "y")
    puts "Cancelled. Book not saved."
    exit 0
  end

  books << book
  save_db(db)
  puts "\nBook saved to db.json! (ID: #{book_id})"

  git_auto_commit("Add", book, db, include_covers: true)
end

begin
  main
rescue Interrupt
  puts "\n\nCancelled."
  exit 1
rescue StandardError => e
  warn "\nError: #{e.message}"
  warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
  exit 1
end
