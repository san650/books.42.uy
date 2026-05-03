#!/usr/bin/env ruby
# frozen_string_literal: true

# add_book.rb — Interactive CLI to add books to db.json.
# Looks up the book across multiple sources (Google Books, OpenLibrary,
# Goodreads, Wikipedia) and lets the user pick the best value per field.
#
# `add_book` is the orchestration entrypoint and accepts an injectable
# `http` client and `picker`. The CLI `main` wraps it with the real
# clients; tests pass FakeHttpClient + ScriptedPicker.

require_relative "common"
require_relative "lookup"
require_relative "book_form"

# ---------------------------------------------------------------------------
# Cover download
# ---------------------------------------------------------------------------

def download_cover(cover_url, isbn, book_id, title, http: DEFAULT_HTTP)
  FileUtils.mkdir_p(COVERS_DIR)
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  if cover_url && !cover_url.empty?
    puts "\nDownloading cover from #{cover_url}..."
    if http.download(cover_url, dest) && File.size(dest) > 1000
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
    if http.download(ol_url, dest) && File.size(dest) > 1000
      puts "  Cover saved: covers/#{filename}"
      return "covers/#{filename}"
    end
    File.delete(dest) if File.exist?(dest)
  end

  puts "  No cover available."
  nil
end

# ---------------------------------------------------------------------------
# Orchestrator — pure-ish: takes db + picker + http and produces (or persists
# when save: true) a new book entry. Returns the book hash, or nil if the
# user declined to save or an existing match was found.
# ---------------------------------------------------------------------------

def add_book(db:, query:, http: DEFAULT_HTTP, picker: CLIPicker.new, save: true, download_covers: true)
  books = db["books"]

  pairs = []
  if !query.to_s.empty?
    result = lookup(query, http: http)
    pairs = flatten_lookup(result)
  end

  title_candidates = collect_field(pairs, exclude_context: :title) { |r| r["title"] }
  title = picker.single("Title", title_candidates, required: true)

  existing = books.find { |b| b["title"].downcase == title.downcase }
  if existing
    return { existing: existing }
  end

  subtitle_candidates = collect_field(pairs) { |r| r["subtitle"] }
  subtitle = picker.single("Subtitle", subtitle_candidates).to_s

  original_candidates = collect_field(pairs) { |r| r["original_title"] }
  original_title = picker.single("Original title", original_candidates).to_s

  first_pub_candidates = collect_field(pairs) { |r| r["first_publishing_date"] }
  first_pub = picker.single("First publishing date", first_pub_candidates).to_s

  publish_dates_candidates = collect_field(pairs) { |r| r["publish_dates"] }
  publish_dates = picker.multi("Publish dates", publish_dates_candidates)

  authors_candidates = collect_field(pairs) { |r| r["authors"] }
  author_names = picker.multi("Authors", authors_candidates)
  author_names = picker.author_fallback_names if author_names.empty?
  author_ids = author_names.empty? ? [] : resolve_author_ids(db, author_names)

  identifiers_candidates = collect_identifiers(pairs)
  picked_ids = picker.multi("Identifiers (ISBN-10 / ISBN-13)",
                            identifiers_candidates,
                            format_value: ->(v) { "#{v["type"]}: #{v["value"]}" })
  identifiers = picked_ids.map do |id|
    next id if id.is_a?(Hash)
    val = id.to_s.gsub(/[\s\-]/, "")
    type = val.length == 13 ? "ISBN_13" : (val.length == 10 ? "ISBN_10" : "ISBN")
    { "type" => type, "value" => val }
  end

  publisher = picker.publisher(pairs)

  saga_candidates = collect_sagas(pairs)
  saga = picker.single("Saga",
                       saga_candidates,
                       format_value: ->(v) { "#{v["name"]} ##{v["order"]}" })
  saga = nil if saga.is_a?(String) && saga.empty?
  if saga.is_a?(String) && !saga.empty?
    saga = { "name" => saga, "order" => picker.saga_order }
  end

  cover_candidates = collect_field(pairs) { |r| r["cover_url"] }
  cover_url = picker.single("Cover URL", cover_candidates)
  cover_url = nil if cover_url.to_s.empty?

  score = picker.required_score

  book_id = next_id(books)
  primary_isbn = (identifiers.find { |id| id["type"] == "ISBN_13" } ||
                  identifiers.find { |id| id["type"] == "ISBN_10" })&.dig("value")

  cover_path = download_covers ? download_cover(cover_url, primary_isbn, book_id, title, http: http) : nil
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

  return { book: book, saved: false } unless picker.confirm_save

  if save
    books << book
    save_db(db)
  end

  { book: book, saved: save }
end

# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Add a Book"
  puts "=" * 50

  db = load_db
  query = ARGV.join(" ").strip
  if query.empty?
    query = prompt("\nLookup (ISBN or title; blank to enter manually)")
  else
    puts "\nLookup: #{query}"
  end

  if query.empty?
    puts "\nSkipping lookup — manual entry."
  else
    puts "\nLookup query: #{query}"
  end

  outcome = add_book(db: db, query: query, picker: CLIPicker.new)

  if outcome[:existing]
    book = outcome[:existing]
    names = resolve_author_names(db, book)
    author_name = names.first || "Unknown"
    puts "\n  Book already exists: \"#{book["title"]}\" by #{author_name} (ID: #{book["id"]})"
    puts "  To edit it, run: ruby scripts/edit_book.rb"
    exit 0
  end

  book = outcome[:book]

  puts "\n" + "=" * 50
  puts "  Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Subtitle:    #{book["subtitle"]}" unless book["subtitle"].empty?
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].empty?
  puts "  Authors:     #{resolve_author_names(db, book).join(", ")}"
  puts "  First pub:   #{book["first_publishing_date"]}" unless book["first_publishing_date"].empty?
  puts "  Published:   #{book["publish_dates"].join(", ")}" if book["publish_dates"].any?
  book["identifiers"].each { |id| puts "  #{id["type"]}:    #{id["value"]}" }
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Saga:        #{book["saga"]["name"]} ##{book["saga"]["order"]}" if book["saga"]
  puts "  Score:       #{book["score"]}/10"
  cover_file = book["covers"].first&.dig("file")
  puts "  Cover:       #{cover_file || "none"}"
  puts "  ID:          #{book["id"]}"
  puts ""

  if outcome[:saved]
    puts "Book saved to db.json! (ID: #{book["id"]})"
    git_auto_commit("Add", book, db, include_covers: true)
  else
    puts "Cancelled. Book not saved."
  end
end

if $PROGRAM_NAME == __FILE__
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
end
