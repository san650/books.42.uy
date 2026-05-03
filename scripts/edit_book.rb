#!/usr/bin/env ruby
# frozen_string_literal: true

# edit_book.rb — Interactive CLI to update book metadata.
# Pulls current values from db.json and proposes alternatives from external
# sources (Google Books, OpenLibrary, Goodreads, Wikipedia). Field pickers
# are shared with add_book.rb via book_form.rb.

require_relative "common"
require_relative "lookup"
require_relative "book_form"

trap("INT") do
  puts "\nAborted."
  exit 130
end

# ---------------------------------------------------------------------------
# Cover handling
# ---------------------------------------------------------------------------

def update_cover(book, new_url, http: DEFAULT_HTTP, confirm: ->(_) { true })
  return if new_url.nil? || new_url.empty?

  return unless confirm.call(new_url)

  FileUtils.mkdir_p(COVERS_DIR)
  filename = "#{book["id"]}-#{sanitize_title(book["title"])}.jpg"
  dest = File.join(COVERS_DIR, filename)

  puts "  Downloading cover..."
  if http.download(new_url, dest)
    (book["covers"] || []).each do |old|
      old_path = File.join(ROOT_DIR, old["file"])
      File.delete(old_path) if File.exist?(old_path) && old_path != dest
    end
    book["covers"] = [{ "file" => "covers/#{filename}", "default" => true }]
    puts "  Cover saved: covers/#{filename}"
  else
    puts "  Failed to download cover."
  end
end

# ---------------------------------------------------------------------------
# Saga finalization — pick_single may return Hash or String; convert string
# inputs into {name, order} via picker.saga_order.
# ---------------------------------------------------------------------------

def finalize_saga(picked, current_saga, picker)
  return nil if picked.nil?
  return nil if picked.is_a?(String) && picked.empty?
  return picked if picked.is_a?(Hash)

  default_order = current_saga ? current_saga["order"] : nil
  { "name" => picked, "order" => picker.saga_order(default: default_order) }
end

# ---------------------------------------------------------------------------
# Helpers for the CLI's book selection step (not part of the orchestrator)
# ---------------------------------------------------------------------------

def primary_identifier(book)
  ids = book["identifiers"] || []
  ids.find { |id| id["type"] == "ISBN_13" } ||
    ids.find { |id| id["type"] == "ISBN_10" } ||
    ids.first
end

def lookup_query_for(book, db)
  isbn = primary_identifier(book)&.dig("value")
  return isbn if isbn && !isbn.empty?

  first_author = resolve_author_names(db, book).first
  parts = [book["title"], first_author].compact
  parts.join(" ")
end

# ---------------------------------------------------------------------------
# Orchestrator — pure-ish: takes db + book + picker + http, mutates the book
# in place and (if save: true) persists. Returns { book:, saved: }.
# ---------------------------------------------------------------------------

def edit_book(db:, book:, http: DEFAULT_HTTP, picker: CLIPicker.new, save: true, query: nil, confirm_cover: nil)
  query ||= lookup_query_for(book, db)
  pairs = []
  unless query.to_s.empty?
    result = lookup(query, http: http)
    pairs = flatten_lookup(result)
  end

  title_candidates = collect_field(pairs, exclude_context: :title) { |r| r["title"] }
  book["title"] = picker.single("Title", title_candidates, required: true, current: book["title"])

  subtitle_candidates = collect_field(pairs) { |r| r["subtitle"] }
  book["subtitle"] = picker.single("Subtitle", subtitle_candidates, current: book["subtitle"]).to_s

  original_candidates = collect_field(pairs) { |r| r["original_title"] }
  book["original_title"] = picker.single("Original title", original_candidates, current: book["original_title"]).to_s

  first_pub_candidates = collect_field(pairs) { |r| r["first_publishing_date"] }
  book["first_publishing_date"] = picker.single("First publishing date",
                                                first_pub_candidates,
                                                current: book["first_publishing_date"]).to_s

  publish_dates_candidates = collect_field(pairs) { |r| r["publish_dates"] }
  book["publish_dates"] = picker.multi("Publish dates",
                                       publish_dates_candidates,
                                       current: book["publish_dates"] || [])

  authors_candidates = collect_field(pairs) { |r| r["authors"] }
  current_author_names = resolve_author_names(db, book)
  author_names = picker.multi("Authors", authors_candidates, current: current_author_names)
  author_names = picker.author_fallback_names if author_names.empty?
  book["author_ids"] = author_names.empty? ? [] : resolve_author_ids(db, author_names)

  identifiers_candidates = collect_identifiers(pairs)
  picked_ids = picker.multi("Identifiers (ISBN-10 / ISBN-13)",
                            identifiers_candidates,
                            format_value: ->(v) { "#{v["type"]}: #{v["value"]}" },
                            current: book["identifiers"] || [])
  book["identifiers"] = picked_ids.map do |id|
    next id if id.is_a?(Hash)
    val = id.to_s.gsub(/[\s\-]/, "")
    type = val.length == 13 ? "ISBN_13" : (val.length == 10 ? "ISBN_10" : "ISBN")
    { "type" => type, "value" => val }
  end

  book["publisher"] = picker.publisher(pairs, current: book["publisher"])

  saga_candidates = collect_sagas(pairs)
  picked_saga = picker.single("Saga",
                              saga_candidates,
                              format_value: ->(v) { "#{v["name"]} ##{v["order"]}" },
                              current: book["saga"])
  book["saga"] = finalize_saga(picked_saga, book["saga"], picker)

  cover_candidates = collect_field(pairs) { |r| r["cover_url"] }
  cover_url = picker.single("Cover URL", cover_candidates)
  if cover_url.is_a?(String) && !cover_url.empty?
    confirm = confirm_cover || ->(_url) { picker.confirm_save(default: "y") }
    update_cover(book, cover_url, http: http, confirm: confirm)
  end

  new_score = picker.score_update(book["score"])
  book["score"] = new_score if new_score

  return { book: book, saved: false } unless picker.confirm_save

  save_db(db) if save

  { book: book, saved: save }
end

# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Update Book Metadata"
  puts "=" * 50

  db = load_db
  books = db["books"]

  if books.empty?
    puts "No books found. Run `make add` first."
    exit 0
  end

  display_book_list(books, db)
  index = prompt_book_selection(books, db)
  book = books[index]

  puts ""
  puts "Selected: #{book["title"]}"

  query = lookup_query_for(book, db)
  puts query.empty? ? "\nNo ISBN or title to query — proceeding with manual edit." : "\nLookup: #{query}"

  outcome = edit_book(db: db, book: book, picker: CLIPicker.new, query: query)
  book = outcome[:book]

  puts "\n" + "=" * 50
  puts "  Updated Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Subtitle:    #{book["subtitle"]}" unless book["subtitle"].to_s.empty?
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].to_s.empty?
  puts "  Authors:     #{resolve_author_names(db, book).join(", ")}"
  puts "  First pub:   #{book["first_publishing_date"]}" unless book["first_publishing_date"].to_s.empty?
  puts "  Published:   #{(book["publish_dates"] || []).join(", ")}" if (book["publish_dates"] || []).any?
  (book["identifiers"] || []).each { |id| puts "  #{id["type"]}:    #{id["value"]}" }
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Saga:        #{book["saga"]["name"]} ##{book["saga"]["order"]}" if book["saga"]
  puts "  Score:       #{book["score"] || "none"}/10"
  puts "  ID:          #{book["id"]}"
  puts ""

  if outcome[:saved]
    puts "Book updated: \"#{book["title"]}\""
    git_auto_commit("Edit", book, db, include_covers: true)
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
