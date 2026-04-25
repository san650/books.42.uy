#!/usr/bin/env ruby
# frozen_string_literal: true

# add_book.rb — Interactive CLI to add books to db.json
# Self-contained, no gem dependencies beyond stdlib.

require "json"
require "net/http"
require "uri"
require "open-uri"
require "tempfile"
require "fileutils"

DB_PATH = File.join(__dir__, "db.json")
COVERS_DIR = File.join(__dir__, "covers")
HTTP_TIMEOUT = 10 # seconds

PUBLISHERS = [
  "Planeta",
  "Alfaguara",
  "Sudamericana",
  "Anagrama",
  "Tusquets",
  "Seix Barral",
  "Salamandra",
  "DeBolsillo",
  "Penguin Random House",
  "Galaxia Gutenberg"
].freeze

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def prompt(label, default: nil, required: false)
  loop do
    suffix = default ? " [#{default}]" : ""
    print "#{label}#{suffix}: "
    input = $stdin.gets
    abort "\nCancelled." unless input
    input = input.strip
    input = default if input.empty? && default
    return input unless input.to_s.empty? && required

    puts "  This field is required."
  end
end

def prompt_yes_no(label, default: "y")
  answer = prompt(label, default: default)
  answer.downcase.start_with?("y")
end

def sanitize_title(title)
  title
    .downcase
    .gsub(/[^a-z0-9]/, "-")
    .gsub(/-{2,}/, "-")
    .gsub(/\A-|-\z/, "")
end

def load_db
  return [] unless File.exist?(DB_PATH)

  data = File.read(DB_PATH)
  return [] if data.strip.empty?

  JSON.parse(data)
rescue JSON::ParserError => e
  warn "Warning: could not parse db.json (#{e.message}). Starting with empty list."
  []
end

def save_db(books)
  sorted = books.sort_by { |b| (b["title"] || "").downcase }
  json = JSON.pretty_generate(sorted, indent: "  ")

  FileUtils.mkdir_p(File.dirname(DB_PATH))
  tmp = Tempfile.new(["db", ".json"], File.dirname(DB_PATH))
  begin
    tmp.write(json)
    tmp.write("\n")
    tmp.close
    FileUtils.mv(tmp.path, DB_PATH)
  rescue StandardError
    tmp.close
    tmp.unlink
    raise
  end
end

def next_id(books)
  return 1 if books.empty?

  books.map { |b| b["id"].to_i }.max + 1
end

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http_get(url, headers: {})
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = HTTP_TIMEOUT
  http.read_timeout = HTTP_TIMEOUT

  request = Net::HTTP::Get.new(uri)
  headers.each { |k, v| request[k] = v }

  response = http.request(request)
  response
rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
       Errno::ECONNRESET, SocketError, OpenSSL::SSL::SSLError => e
  warn "  Network error: #{e.message}"
  nil
end

def http_get_json(url)
  response = http_get(url)
  return nil unless response&.code == "200"

  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

def http_download(url, dest)
  response = http_get(url)
  return false unless response&.code == "200"
  return false if response.body.nil? || response.body.empty?

  # Check we actually got image data (not an HTML error page)
  content_type = response["content-type"].to_s
  if content_type.include?("text/html")
    return false
  end

  File.open(dest, "wb") { |f| f.write(response.body) }
  true
rescue StandardError => e
  warn "  Download error: #{e.message}"
  false
end

# ---------------------------------------------------------------------------
# OpenLibrary API
# ---------------------------------------------------------------------------

def search_openlibrary(query)
  encoded = URI.encode_www_form_component(query)
  url = "https://openlibrary.org/search.json?title=#{encoded}&limit=10"
  puts "\nSearching OpenLibrary..."
  data = http_get_json(url)

  unless data && data["docs"]
    puts "  No results or API unavailable."
    return []
  end

  data["docs"]
end

def display_search_results(docs)
  return if docs.empty?

  puts "\nResults:"
  docs.each_with_index do |doc, i|
    authors = (doc["author_name"] || []).join(", ")
    year = doc["first_publish_year"]
    title = doc["title"]
    puts "  #{i + 1}. #{title} — #{authors} (#{year || '?'})"
  end
end

def fetch_work_details(work_key)
  return nil unless work_key

  url = "https://openlibrary.org#{work_key}.json"
  http_get_json(url)
end

def fetch_editions(work_key)
  return [] unless work_key

  url = "https://openlibrary.org#{work_key}/editions.json?limit=50"
  data = http_get_json(url)
  return [] unless data && data["entries"]

  data["entries"]
end

def find_best_edition(editions)
  return nil if editions.empty?

  # Prefer Spanish editions
  spanish = editions.select do |ed|
    langs = ed["languages"] || []
    langs.any? { |l| l["key"] == "/languages/spa" }
  end

  candidates = spanish.empty? ? editions : spanish

  # Prefer editions with ISBN
  with_isbn = candidates.select { |ed| ed["isbn_13"]&.any? || ed["isbn_10"]&.any? }
  best = with_isbn.first || candidates.first

  best
end

def extract_isbn(edition)
  return nil unless edition

  isbn13 = edition["isbn_13"]&.first
  return isbn13 if isbn13

  isbn10 = edition["isbn_10"]&.first
  isbn10
end

# ---------------------------------------------------------------------------
# Goodreads scraping (best-effort)
# ---------------------------------------------------------------------------

def scrape_goodreads(query)
  encoded = URI.encode_www_form_component(query)
  url = "https://www.goodreads.com/search?q=#{encoded}"
  puts "\nAttempting Goodreads lookup..."

  response = http_get(url, headers: {
    "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    "Accept" => "text/html"
  })

  unless response&.code == "200"
    puts "  Goodreads unavailable, skipping."
    return {}
  end

  html = response.body
  result = {}

  # Try to extract rating
  if html =~ /aria-label="(\d+\.\d+) out of 5 stars"/
    result[:rating] = $1
  elsif html =~ /class="[^"]*RatingStatistics[^"]*"[^>]*>.*?(\d+\.\d+)/m
    result[:rating] = $1
  end

  # Try to extract original title
  if html =~ /Original Title.*?<[^>]+>([^<]+)</m
    result[:original_title] = $1.strip
  end

  unless result.empty?
    puts "  Found Goodreads data: #{result.map { |k, v| "#{k}=#{v}" }.join(", ")}"
  else
    puts "  No additional data from Goodreads."
  end

  result
rescue StandardError => e
  puts "  Goodreads scraping failed: #{e.message}"
  {}
end

# ---------------------------------------------------------------------------
# Cover download
# ---------------------------------------------------------------------------

def download_cover(isbn, book_id, title)
  return nil unless isbn && !isbn.empty?

  FileUtils.mkdir_p(COVERS_DIR)
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  # Try bookcover.longitood.com first
  puts "\nDownloading cover from bookcover.longitood.com..."
  longitood_url = "https://bookcover.longitood.com/bookcover/#{URI.encode_www_form_component(isbn)}"
  if http_download(longitood_url, dest)
    puts "  Cover saved: covers/#{filename}"
    return "covers/#{filename}"
  end

  # Fall back to OpenLibrary covers
  puts "  Trying OpenLibrary covers..."
  ol_url = "https://covers.openlibrary.org/b/isbn/#{URI.encode_www_form_component(isbn)}-L.jpg"
  if http_download(ol_url, dest)
    # OpenLibrary returns a 1x1 pixel for missing covers
    if File.size(dest) < 1000
      File.delete(dest)
      puts "  OpenLibrary cover too small (likely placeholder), skipping."
      return nil
    end
    puts "  Cover saved: covers/#{filename}"
    return "covers/#{filename}"
  end

  puts "  No cover available."
  nil
end

# ---------------------------------------------------------------------------
# Publisher selection
# ---------------------------------------------------------------------------

def select_publisher(default: nil)
  puts "\nPublisher:"
  PUBLISHERS.each_with_index do |pub, i|
    marker = (default && pub.downcase == default.to_s.downcase) ? " *" : ""
    puts "  #{i + 1}. #{pub}#{marker}"
  end
  puts "  #{PUBLISHERS.size + 1}. Other (enter custom)"

  if default
    print "Select [#{default}]: "
  else
    print "Select: "
  end

  input = $stdin.gets
  abort "\nCancelled." unless input
  input = input.strip

  return default if input.empty? && default

  num = input.to_i
  if num >= 1 && num <= PUBLISHERS.size
    PUBLISHERS[num - 1]
  elsif num == PUBLISHERS.size + 1
    prompt("  Enter publisher name", required: true)
  elsif input.empty?
    default || prompt("  Enter publisher name", required: true)
  else
    # Treat as custom text input
    input
  end
end

# ---------------------------------------------------------------------------
# Score prompt
# ---------------------------------------------------------------------------

def prompt_score
  loop do
    input = prompt("Score (1-10)", required: true)
    score = input.to_i
    if score >= 1 && score <= 10
      return score
    end

    puts "  Please enter a number between 1 and 10."
  end
end

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Add a Book"
  puts "=" * 50

  books = load_db

  # Step 1: Prompt for title
  title_query = prompt("\nBook title", required: true)

  # Step 2: Search OpenLibrary
  docs = search_openlibrary(title_query)

  # Step 3: Let user pick a result or enter manually
  selected_doc = nil
  if docs.any?
    display_search_results(docs)
    puts "\n  0. None of these — enter manually"
    choice = prompt("Select a result (1-#{docs.size}, or 0)")
    num = choice.to_i
    selected_doc = docs[num - 1] if num >= 1 && num <= docs.size
  else
    puts "\nNo results found. You'll enter details manually."
  end

  # Step 4: Fetch details
  metadata = {
    title: title_query,
    original_title: "",
    first_publishing_date: "",
    publish_dates: [],
    authors: [],
    isbn: "",
    publisher: ""
  }

  if selected_doc
    puts "\nFetching details..."
    work_key = selected_doc["key"]

    # Basic metadata from search result
    metadata[:title] = selected_doc["title"] || title_query
    metadata[:first_publishing_date] = selected_doc["first_publish_year"].to_s
    metadata[:authors] = (selected_doc["author_name"] || []).map do |name|
      { "name" => name, "aliases" => [] }
    end

    # Fetch work details for original title
    work = fetch_work_details(work_key)
    if work
      if work["title"] && work["title"] != metadata[:title]
        metadata[:original_title] = work["title"]
      end
    end

    # Fetch editions to find Spanish one with ISBN
    editions = fetch_editions(work_key)
    best_edition = find_best_edition(editions)

    if best_edition
      metadata[:isbn] = extract_isbn(best_edition) || ""
      if best_edition["publishers"]&.any?
        metadata[:publisher] = best_edition["publishers"].first
      end
      if best_edition["publish_date"]
        metadata[:publish_dates] = [best_edition["publish_date"]]
      end
    end

    # Fallback: ISBNs from search result
    if metadata[:isbn].empty?
      isbn_list = selected_doc["isbn"] || []
      metadata[:isbn] = isbn_list.first.to_s unless isbn_list.empty?
    end
  end

  # Goodreads scraping (best-effort)
  gr_query = metadata[:title]
  gr_query += " #{metadata[:authors].first["name"]}" if metadata[:authors].any?
  gr_data = scrape_goodreads(gr_query)

  if metadata[:original_title].empty? && gr_data[:original_title]
    metadata[:original_title] = gr_data[:original_title]
  end

  # Step 5: Show fetched metadata and let user confirm/override
  puts "\n" + "-" * 50
  puts "  Review & Edit Book Details"
  puts "-" * 50

  metadata[:title] = prompt("Title", default: metadata[:title], required: true)
  metadata[:original_title] = prompt("Original title", default: metadata[:original_title])
  metadata[:first_publishing_date] = prompt("First publishing date", default: metadata[:first_publishing_date])

  # Publish dates
  pd_default = metadata[:publish_dates].join(", ")
  pd_input = prompt("Publish dates (comma-separated)", default: pd_default)
  metadata[:publish_dates] = pd_input.split(",").map(&:strip).reject(&:empty?)

  # Authors
  if metadata[:authors].any?
    puts "\nAuthors:"
    metadata[:authors].each_with_index do |a, i|
      puts "  #{i + 1}. #{a["name"]} (aliases: #{a["aliases"].join(", ").then { |s| s.empty? ? "none" : s }})"
    end
    unless prompt_yes_no("Keep these authors?", default: "y")
      metadata[:authors] = []
    end
  end

  if metadata[:authors].empty?
    loop do
      name = prompt("Author name (blank to finish)", required: false)
      break if name.empty?

      aliases_input = prompt("  Aliases for #{name} (comma-separated, blank for none)")
      aliases = aliases_input.split(",").map(&:strip).reject(&:empty?)
      metadata[:authors] << { "name" => name, "aliases" => aliases }
    end
  end

  if metadata[:authors].empty?
    puts "  Warning: no authors entered."
  end

  # ISBN
  metadata[:isbn] = prompt("ISBN", default: metadata[:isbn])

  # Publisher
  metadata[:publisher] = select_publisher(default: metadata[:publisher])

  # Score
  score = prompt_score

  # Step 6: Assign ID
  book_id = next_id(books)

  # Step 7: Download cover
  cover_path = download_cover(metadata[:isbn], book_id, metadata[:title])
  covers = []
  if cover_path
    covers << { "file" => cover_path, "default" => true }
  end

  # Step 8: Build book object
  book = {
    "id" => book_id,
    "title" => metadata[:title],
    "original_title" => metadata[:original_title],
    "first_publishing_date" => metadata[:first_publishing_date],
    "publish_dates" => metadata[:publish_dates],
    "authors" => metadata[:authors],
    "identifiers" => [],
    "covers" => covers,
    "publisher" => metadata[:publisher],
    "score" => score,
    "review" => ""
  }

  unless metadata[:isbn].empty?
    book["identifiers"] << { "type" => "ISBN", "value" => metadata[:isbn] }
  end

  # Step 9: Confirm
  puts "\n" + "=" * 50
  puts "  Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].empty?
  puts "  Authors:     #{book["authors"].map { |a| a["name"] }.join(", ")}"
  puts "  Published:   #{book["first_publishing_date"]}"
  puts "  ISBN:        #{metadata[:isbn]}" unless metadata[:isbn].empty?
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Score:       #{book["score"]}/10"
  puts "  Cover:       #{cover_path || "none"}"
  puts "  ID:          #{book_id}"
  puts ""

  unless prompt_yes_no("Save this book?", default: "y")
    puts "Cancelled. Book not saved."
    exit 0
  end

  # Step 10: Save
  books << book
  save_db(books)

  puts "\nBook saved to db.json! (ID: #{book_id})"
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

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
