#!/usr/bin/env ruby
# frozen_string_literal: true

# add_book.rb — Interactive CLI to add books to db.json
# Primary source: Goodreads (scraping). Fallback: OpenLibrary API.
# Self-contained, no gem dependencies beyond stdlib.

require "json"
require "net/http"
require "uri"
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

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
             "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def prompt(label, default: nil, required: false)
  loop do
    suffix = default && !default.to_s.empty? ? " [#{default}]" : ""
    print "#{label}#{suffix}: "
    input = $stdin.gets
    abort "\nCancelled." unless input
    input = input.strip
    input = default.to_s if input.empty? && default && !default.to_s.empty?
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

# Decode HTML entities (minimal, stdlib-only)
def decode_html(str)
  return "" unless str

  str
    .gsub("&amp;", "&")
    .gsub("&lt;", "<")
    .gsub("&gt;", ">")
    .gsub("&quot;", '"')
    .gsub("&#39;", "'")
    .gsub("&apos;", "'")
    .gsub("&#x27;", "'")
    .gsub("&#x2F;", "/")
    .gsub("&nbsp;", " ")
    .gsub(/&#(\d+);/) { [$1.to_i].pack("U") }
    .gsub(/&#x([0-9a-fA-F]+);/) { [$1.to_i(16)].pack("U") }
end

# Strip HTML tags
def strip_tags(str)
  return "" unless str

  str.gsub(/<[^>]+>/, "")
end

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http_get(url, headers: {}, follow_redirects: true, max_redirects: 5)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = HTTP_TIMEOUT
  http.read_timeout = HTTP_TIMEOUT

  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = USER_AGENT
  headers.each { |k, v| request[k] = v }

  response = http.request(request)
  response.body&.force_encoding("UTF-8") if response.body

  # Follow redirects
  if follow_redirects && %w[301 302 303 307 308].include?(response.code) && max_redirects > 0
    location = response["location"]
    if location
      location = URI.join(uri, location).to_s unless location.start_with?("http")
      return http_get(location, headers: headers, follow_redirects: true, max_redirects: max_redirects - 1)
    end
  end

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

  content_type = response["content-type"].to_s
  return false if content_type.include?("text/html")

  File.open(dest, "wb") { |f| f.write(response.body) }
  true
rescue StandardError => e
  warn "  Download error: #{e.message}"
  false
end

# ---------------------------------------------------------------------------
# Goodreads scraping
# ---------------------------------------------------------------------------

def goodreads_search(query)
  encoded = URI.encode_www_form_component(query).gsub("%20", "+")
  url = "https://www.goodreads.com/search?utf8=%E2%9C%93&q=#{encoded}&search_type=books"
  puts "\nSearching Goodreads..."

  response = http_get(url, headers: { "Accept" => "text/html,application/xhtml+xml" })

  unless response&.code == "200"
    puts "  Goodreads search unavailable (HTTP #{response&.code})."
    return []
  end

  html = response.body
  results = []

  # Parse search results — look for table rows with book data
  # Goodreads search results contain <tr itemtype="http://schema.org/Book"> or similar patterns
  # Each result has a book title link and author name

  # Strategy 1: Look for bookTitle and authorName spans/anchors
  html.scan(/<tr[^>]*>.*?<\/tr>/m).each do |row|
    next unless row.include?("bookTitle") || row.include?("/book/show/")

    title = nil
    author = nil
    book_url = nil

    # Extract book URL and title
    if row =~ /<a[^>]+class="bookTitle"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/m
      book_url = $1
      title = decode_html(strip_tags($2)).strip
    elsif row =~ /<a[^>]+href="(\/book\/show\/[^"]+)"[^>]*>(.*?)<\/a>/m
      book_url = $1
      title = decode_html(strip_tags($2)).strip
    end

    # Extract author
    if row =~ /<a[^>]+class="authorName"[^>]*>(.*?)<\/a>/m
      author = decode_html(strip_tags($1)).strip
    elsif row =~ /<span[^>]+itemprop="name"[^>]*>(.*?)<\/span>/m
      author = decode_html(strip_tags($1)).strip
    end

    next unless title && book_url

    full_url = book_url.start_with?("http") ? book_url : "https://www.goodreads.com#{book_url}"
    results << { title: title, author: author || "Unknown", url: full_url }

    break if results.size >= 10
  end

  # Strategy 2: If strategy 1 found nothing, try a more general pattern
  if results.empty?
    html.scan(/href="(\/book\/show\/[^"]+)"[^>]*>([^<]+)</).each do |match|
      book_url = "https://www.goodreads.com#{match[0]}"
      title = decode_html(match[1]).strip
      next if title.empty? || title.length < 2

      # Try to find nearby author
      author = "Unknown"
      results << { title: title, author: author, url: book_url }
      break if results.size >= 10
    end
  end

  if results.empty?
    puts "  No results found on Goodreads."
  end

  results
rescue StandardError => e
  puts "  Goodreads search failed: #{e.message}"
  []
end

def display_goodreads_results(results)
  return if results.empty?

  puts "\nResults:"
  results.each_with_index do |r, i|
    puts "  #{i + 1}. #{r[:title]} — #{r[:author]}"
  end
end

def scrape_goodreads_detail_from_next_data(html)
  next_data_match = html.match(/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/m)
  return nil unless next_data_match

  next_data = JSON.parse(next_data_match[1])
  apollo = next_data.dig("props", "pageProps", "apolloState")
  return nil unless apollo

  book_obj = apollo.values.find { |v| v["__typename"] == "Book" }
  work_obj = apollo.values.find { |v| v["__typename"] == "Work" }
  return nil unless book_obj

  detail = {}

  # --- Title ---
  raw_title = book_obj["titleComplete"] || book_obj["title"] || ""
  if raw_title.include?(":")
    parts = raw_title.split(":", 2)
    detail[:title] = parts[0].strip
    detail[:subtitle] = parts[1].strip
  else
    detail[:title] = raw_title.strip
  end

  # --- Cover image ---
  detail[:cover_url] = book_obj["imageUrl"] if book_obj["imageUrl"]

  # --- Authors (only role=Author) ---
  authors = []
  primary = book_obj["primaryContributorEdge"]
  if primary && primary["role"] == "Author"
    ref = primary.dig("node", "__ref")
    contributor = apollo[ref] if ref
    authors << contributor["name"] if contributor&.dig("name")
  end
  (book_obj["secondaryContributorEdges"] || []).each do |edge|
    next unless edge["role"] == "Author"
    ref = edge.dig("node", "__ref")
    contributor = apollo[ref] if ref
    authors << contributor["name"] if contributor&.dig("name")
  end
  detail[:authors] = authors unless authors.empty?

  # --- Series/Saga ---
  series_list = book_obj["bookSeries"] || []
  series_list.each do |series_entry|
    # Series entries may be inline or contain refs
    series_ref = series_entry.dig("series", "__ref")
    series_obj = series_ref ? apollo[series_ref] : series_entry["series"]
    if series_obj && series_obj["title"]
      detail[:saga_name] = series_obj["title"].strip
      # userPosition is the book's position in the series (e.g. "1", "2")
      detail[:saga_order] = (series_entry["userPosition"] || "1").to_i
      detail[:saga_order] = 1 if detail[:saga_order] < 1
      break
    end
  end

  # --- Original title from Work ---
  if work_obj
    orig = work_obj.dig("details", "originalTitle")
    detail[:original_title] = orig.strip if orig && !orig.strip.empty?
  end

  # --- Publication year from Work timestamp ---
  if work_obj
    pub_time = work_obj.dig("details", "publicationTime")
    if pub_time
      detail[:first_publishing_date] = Time.at(pub_time / 1000).year.to_s
    end
  end

  # Fallback: "First published" text in HTML for the year
  if detail[:first_publishing_date].nil? || detail[:first_publishing_date].to_s.empty?
    first_pub_match = html.match(/First published.*?(\d{4})/)
    detail[:first_publishing_date] = first_pub_match[1] if first_pub_match
  end

  # --- ISBN from JSON-LD ---
  begin
    ld_match = html.match(/<script type="application\/ld\+json">(.*?)<\/script>/m)
    if ld_match
      ld_json = JSON.parse(ld_match[1])
      isbn_val = ld_json["isbn"]
      detail[:isbn] = isbn_val if isbn_val && !isbn_val.to_s.empty?
    end
  rescue JSON::ParserError
    # ignore malformed JSON-LD
  end

  detail
rescue JSON::ParserError => e
  puts "  __NEXT_DATA__ JSON parse error: #{e.message}"
  nil
end

def scrape_goodreads_detail_from_html(html)
  detail = {}

  # --- Title ---
  if html =~ /<h1[^>]*data-testid="bookTitle"[^>]*>(.*?)<\/h1>/m
    raw_title = decode_html(strip_tags($1)).strip
    if raw_title.include?(":")
      parts = raw_title.split(":", 2)
      detail[:title] = parts[0].strip
      detail[:subtitle] = parts[1].strip
    else
      detail[:title] = raw_title
    end
  elsif html =~ /<h1[^>]*class="[^"]*bookTitle[^"]*"[^>]*>(.*?)<\/h1>/m
    raw_title = decode_html(strip_tags($1)).strip
    if raw_title.include?(":")
      parts = raw_title.split(":", 2)
      detail[:title] = parts[0].strip
      detail[:subtitle] = parts[1].strip
    else
      detail[:title] = raw_title
    end
  elsif html =~ /<meta[^>]+property="og:title"[^>]+content="([^"]+)"/
    raw_title = decode_html($1).strip
    if raw_title.include?(":")
      parts = raw_title.split(":", 2)
      detail[:title] = parts[0].strip
      detail[:subtitle] = parts[1].strip
    else
      detail[:title] = raw_title
    end
  end

  # --- Series/Saga ---
  if html =~ /\(([^)]+?)\s*#(\d+(?:\.\d+)?)\)/
    detail[:saga_name] = decode_html($1).strip
    detail[:saga_order] = $2.to_i
  elsif html =~ /<a[^>]+href="\/series\/[^"]*"[^>]*>([^<]+)<\/a>\s*#?(\d+)?/
    detail[:saga_name] = decode_html($1).strip
    detail[:saga_order] = $2 ? $2.to_i : 1
  end

  # --- Author(s) ---
  authors = []
  html.scan(/<span[^>]*class="[^"]*ContributorLink__name[^"]*"[^>]*>(.*?)<\/span>/m).each do |match|
    name = decode_html(strip_tags(match[0])).strip
    authors << name unless name.empty? || authors.include?(name)
  end
  if authors.empty?
    html.scan(/<a[^>]+class="authorName"[^>]*>.*?<span[^>]*itemprop="name"[^>]*>(.*?)<\/span>/m).each do |match|
      name = decode_html(strip_tags(match[0])).strip
      authors << name unless name.empty? || authors.include?(name)
    end
  end
  if authors.empty?
    html.scan(/<meta[^>]+property="books:author"[^>]+content="([^"]+)"/m).each do |match|
      name = decode_html(match[0]).strip
      authors << name unless name.empty? || authors.include?(name)
    end
  end
  detail[:authors] = authors unless authors.empty?

  # --- Publication date (year only) ---
  if html =~ /First published.*?(\d{4})/i
    detail[:first_publishing_date] = $1
  elsif html =~ /Published.*?(\d{4})/i
    detail[:first_publishing_date] = $1
  end

  # --- Original Title ---
  if html =~ /Original Title\s*<\/dt>\s*<dd[^>]*>(.*?)<\/dd>/mi
    detail[:original_title] = decode_html(strip_tags($1)).strip
  elsif html =~ /Original Title.*?<[^>]+>\s*([^<]+)/mi
    val = decode_html($1).strip
    detail[:original_title] = val unless val.empty?
  end

  # --- ISBN / ISBN13 ---
  if html =~ /ISBN13.*?(\d{13})/m
    detail[:isbn] = $1
  elsif html =~ /ISBN.*?(\d{13})/m
    detail[:isbn] = $1
  elsif html =~ /ISBN.*?(\d{9}[\dXx])/m
    detail[:isbn] = $1
  end
  if detail[:isbn].nil? || detail[:isbn].to_s.empty?
    if html =~ /<meta[^>]+property="books:isbn"[^>]+content="([^"]+)"/
      detail[:isbn] = $1.strip
    end
  end

  # --- Publisher ---
  if html =~ /Publisher\s*<\/dt>\s*<dd[^>]*>(.*?)<\/dd>/mi
    detail[:publisher] = decode_html(strip_tags($1)).strip
  elsif html =~ /Publisher.*?<[^>]+>\s*([^<]+)/mi
    val = decode_html($1).strip
    detail[:publisher] = val unless val.empty? || val.length > 100
  end

  # --- Cover image URL ---
  if html =~ /<img[^>]+class="[^"]*ResponsiveImage[^"]*"[^>]+src="([^"]+)"/
    detail[:cover_url] = $1
  elsif html =~ /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/
    detail[:cover_url] = $1
  elsif html =~ /<img[^>]+id="coverImage"[^>]+src="([^"]+)"/
    detail[:cover_url] = $1
  elsif html =~ /<img[^>]+src="(https:\/\/[^"]*goodreads[^"]*\/books\/[^"]+)"/
    detail[:cover_url] = $1
  end

  detail
end

def scrape_goodreads_detail(url)
  puts "\nFetching Goodreads book page..."
  response = http_get(url, headers: { "Accept" => "text/html,application/xhtml+xml" })

  unless response&.code == "200"
    puts "  Could not fetch book page (HTTP #{response&.code})."
    return nil
  end

  html = response.body

  # Try structured __NEXT_DATA__ JSON first (more reliable)
  begin
    detail = scrape_goodreads_detail_from_next_data(html)
    if detail && detail[:title] && !detail[:title].empty?
      puts "  Parsed book data from structured JSON."
      return detail
    end
  rescue StandardError => e
    puts "  __NEXT_DATA__ extraction failed (#{e.message}), falling back to HTML scraping..."
  end

  # Fall back to HTML scraping
  detail = scrape_goodreads_detail_from_html(html)
  return detail unless detail.empty?

  nil
rescue StandardError => e
  puts "  Goodreads detail scraping failed: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# OpenLibrary API (fallback)
# ---------------------------------------------------------------------------

def search_openlibrary(query)
  encoded = URI.encode_www_form_component(query)
  url = "https://openlibrary.org/search.json?title=#{encoded}&limit=10"
  puts "\nSearching OpenLibrary (fallback)..."
  data = http_get_json(url)

  unless data && data["docs"]
    puts "  No results or API unavailable."
    return []
  end

  data["docs"]
end

def display_openlibrary_results(docs)
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

  spanish = editions.select do |ed|
    langs = ed["languages"] || []
    langs.any? { |l| l["key"] == "/languages/spa" }
  end

  candidates = spanish.empty? ? editions : spanish
  with_isbn = candidates.select { |ed| ed["isbn_13"]&.any? || ed["isbn_10"]&.any? }
  with_isbn.first || candidates.first
end

def extract_isbn(edition)
  return nil unless edition

  isbn13 = edition["isbn_13"]&.first
  return isbn13 if isbn13

  edition["isbn_10"]&.first
end

# Build metadata from an OpenLibrary search result
def metadata_from_openlibrary(doc, title_query)
  metadata = {
    title: doc["title"] || title_query,
    subtitle: "",
    original_title: "",
    first_publishing_date: doc["first_publish_year"].to_s,
    publish_dates: [],
    authors: (doc["author_name"] || []).map { |name| { "name" => name, "aliases" => [] } },
    isbn: "",
    publisher: "",
    saga: nil,
    cover_url: nil
  }

  puts "\nFetching OpenLibrary details..."
  work_key = doc["key"]
  work = fetch_work_details(work_key)
  if work && work["title"] && work["title"] != metadata[:title]
    metadata[:original_title] = work["title"]
  end

  editions = fetch_editions(work_key)
  best_edition = find_best_edition(editions)

  if best_edition
    metadata[:isbn] = extract_isbn(best_edition) || ""
    metadata[:publisher] = best_edition["publishers"]&.first.to_s
    metadata[:publish_dates] = [best_edition["publish_date"]].compact
  end

  if metadata[:isbn].empty?
    isbn_list = doc["isbn"] || []
    metadata[:isbn] = isbn_list.first.to_s unless isbn_list.empty?
  end

  # Cover from OpenLibrary
  cover_id = doc["cover_i"]
  if cover_id
    metadata[:cover_url] = "https://covers.openlibrary.org/b/id/#{cover_id}-L.jpg"
  end

  metadata
end

# ---------------------------------------------------------------------------
# Cover download
# ---------------------------------------------------------------------------

def download_cover(cover_url, isbn, book_id, title)
  FileUtils.mkdir_p(COVERS_DIR)
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  # Try Goodreads cover URL first
  if cover_url && !cover_url.empty?
    puts "\nDownloading cover from Goodreads..."
    if http_download(cover_url, dest)
      if File.size(dest) > 1000
        puts "  Cover saved: covers/#{filename}"
        return "covers/#{filename}"
      else
        File.delete(dest) if File.exist?(dest)
        puts "  Goodreads cover too small (likely placeholder), trying fallback..."
      end
    else
      puts "  Goodreads cover download failed, trying fallback..."
    end
  end

  # Fall back to OpenLibrary covers via ISBN
  if isbn && !isbn.empty?
    puts "  Trying OpenLibrary covers..."
    ol_url = "https://covers.openlibrary.org/b/isbn/#{URI.encode_www_form_component(isbn)}-L.jpg"
    if http_download(ol_url, dest)
      if File.size(dest) > 1000
        puts "  Cover saved: covers/#{filename}"
        return "covers/#{filename}"
      else
        File.delete(dest) if File.exist?(dest)
        puts "  OpenLibrary cover too small (likely placeholder), skipping."
      end
    end
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

  if default && !default.empty?
    print "Select [#{default}]: "
  else
    print "Select: "
  end

  input = $stdin.gets
  abort "\nCancelled." unless input
  input = input.strip

  return default if input.empty? && default && !default.empty?

  num = input.to_i
  if num >= 1 && num <= PUBLISHERS.size
    PUBLISHERS[num - 1]
  elsif num == PUBLISHERS.size + 1
    prompt("  Enter publisher name", required: true)
  elsif input.empty?
    default && !default.empty? ? default : prompt("  Enter publisher name", required: true)
  else
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
    return score if score >= 1 && score <= 10

    puts "  Please enter a number between 1 and 10."
  end
end

# ---------------------------------------------------------------------------
# Git auto-commit
# ---------------------------------------------------------------------------

def git_auto_commit(book)
  author = book["authors"]&.first&.dig("name") || "Unknown"
  system("git", "add", "db.json", "covers/")
  system("git", "commit", "-m", "Add #{book["title"]} - #{author} book")
rescue StandardError
  # Don't fail if git is not available or repo not initialized
end

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Add a Book"
  puts "=" * 50

  books = load_db

  # Step 1: Prompt for search query (or take from ARGV)
  search_query = ARGV.join(" ").strip
  if search_query.empty?
    search_query = prompt("\nSearch query (e.g. 'Anochecer Isaac')", required: true)
  else
    puts "\nSearching for: #{search_query}"
  end

  # Step 2: Search Goodreads (primary)
  metadata = nil
  gr_results = goodreads_search(search_query)

  if gr_results.any?
    display_goodreads_results(gr_results)
    puts "\n  0. None of these — enter manually"
    choice = prompt("Select a result (1-#{gr_results.size}, or 0)")
    num = choice.to_i

    if num >= 1 && num <= gr_results.size
      selected = gr_results[num - 1]
      detail = scrape_goodreads_detail(selected[:url])

      if detail
        metadata = {
          title: detail[:title] || selected[:title],
          subtitle: detail[:subtitle] || "",
          original_title: detail[:original_title] || "",
          first_publishing_date: detail[:first_publishing_date] || "",
          publish_dates: [],
          authors: (detail[:authors] || [selected[:author]]).map { |name| { "name" => name, "aliases" => [] } },
          isbn: detail[:isbn] || "",
          publisher: detail[:publisher] || "",
          saga: nil,
          cover_url: detail[:cover_url]
        }

        if detail[:saga_name]
          metadata[:saga] = { "name" => detail[:saga_name], "order" => detail[:saga_order] || 1 }
        end

        puts "\n  Goodreads data loaded successfully."
      else
        puts "\n  Could not scrape book details. Falling back..."
      end
    end
  end

  # Step 3: Fall back to OpenLibrary if Goodreads yielded nothing
  if metadata.nil?
    docs = search_openlibrary(search_query)

    if docs.any?
      display_openlibrary_results(docs)
      puts "\n  0. None of these — enter manually"
      choice = prompt("Select a result (1-#{docs.size}, or 0)")
      num = choice.to_i

      if num >= 1 && num <= docs.size
        metadata = metadata_from_openlibrary(docs[num - 1], search_query)
      end
    else
      puts "\nNo results found on either service. You'll enter details manually."
    end
  end

  # Step 4: If still no metadata, start with empty defaults
  metadata ||= {
    title: search_query,
    subtitle: "",
    original_title: "",
    first_publishing_date: "",
    publish_dates: [],
    authors: [],
    isbn: "",
    publisher: "",
    saga: nil,
    cover_url: nil
  }

  # Step 5: Interactive field review — show each scraped field, let user confirm or override
  puts "\n" + "-" * 50
  puts "  Review & Edit Book Details"
  puts "-" * 50

  metadata[:title] = prompt("Title", default: metadata[:title], required: true)

  # Check for duplicate
  existing = books.find { |b| b["title"].downcase == metadata[:title].downcase }
  if existing
    author_name = existing["authors"]&.first&.dig("name") || "Unknown"
    puts "\n  Book already exists: \"#{existing["title"]}\" by #{author_name} (ID: #{existing["id"]})"
    puts "  To edit it, run:"
    puts "    ruby edit_book.rb"
    exit 0
  end

  metadata[:subtitle] = prompt("Subtitle (press enter to skip)", default: metadata[:subtitle])
  metadata[:original_title] = prompt("Original title", default: metadata[:original_title])
  metadata[:first_publishing_date] = prompt("First publishing date", default: metadata[:first_publishing_date])

  # Publish dates
  pd_default = metadata[:publish_dates].join(", ")
  pd_input = prompt("Publish dates (comma-separated)", default: pd_default)
  metadata[:publish_dates] = pd_input.to_s.split(",").map(&:strip).reject(&:empty?)

  # Authors
  if metadata[:authors].any?
    puts "\nAuthors:"
    metadata[:authors].each_with_index do |a, i|
      aliases_str = a["aliases"]&.join(", ")
      aliases_str = aliases_str && !aliases_str.empty? ? aliases_str : "none"
      puts "  #{i + 1}. #{a["name"]} (aliases: #{aliases_str})"
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

  puts "  Warning: no authors entered." if metadata[:authors].empty?

  # ISBN
  metadata[:isbn] = prompt("ISBN", default: metadata[:isbn])

  # Publisher
  metadata[:publisher] = select_publisher(default: metadata[:publisher])

  # Saga
  if metadata[:saga]
    saga_default_name = metadata[:saga]["name"]
    saga_default_order = metadata[:saga]["order"]
    saga_name = prompt("Book saga/series name", default: saga_default_name)
    if saga_name.empty?
      metadata[:saga] = nil
    else
      loop do
        order_input = prompt("Order in saga (number)", default: saga_default_order.to_s, required: true)
        order = order_input.to_i
        if order >= 1
          metadata[:saga] = { "name" => saga_name, "order" => order }
          break
        end
        puts "  Please enter a positive number."
      end
    end
  else
    saga_name = prompt("Book saga/series name (press enter to skip)")
    unless saga_name.empty?
      loop do
        order_input = prompt("Order in saga (number)", required: true)
        order = order_input.to_i
        if order >= 1
          metadata[:saga] = { "name" => saga_name, "order" => order }
          break
        end
        puts "  Please enter a positive number."
      end
    end
  end

  # Score
  score = prompt_score

  # Step 6: Assign ID
  book_id = next_id(books)

  # Step 7: Download cover
  cover_path = download_cover(metadata[:cover_url], metadata[:isbn], book_id, metadata[:title])
  covers = []
  if cover_path
    covers << { "file" => cover_path, "default" => true }
  end

  # Step 8: Build book object
  book = {
    "id" => book_id,
    "title" => metadata[:title],
    "subtitle" => metadata[:subtitle].to_s,
    "original_title" => metadata[:original_title].to_s,
    "first_publishing_date" => metadata[:first_publishing_date].to_s,
    "publish_dates" => metadata[:publish_dates],
    "authors" => metadata[:authors],
    "identifiers" => [],
    "covers" => covers,
    "publisher" => metadata[:publisher],
    "saga" => metadata[:saga],
    "score" => score,
    "review" => ""
  }

  unless metadata[:isbn].to_s.empty?
    book["identifiers"] << { "type" => "ISBN", "value" => metadata[:isbn] }
  end

  # Step 9: Confirm
  puts "\n" + "=" * 50
  puts "  Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Subtitle:    #{book["subtitle"]}" unless book["subtitle"].empty?
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].empty?
  puts "  Authors:     #{book["authors"].map { |a| a["name"] }.join(", ")}"
  puts "  Published:   #{book["first_publishing_date"]}"
  puts "  ISBN:        #{metadata[:isbn]}" unless metadata[:isbn].to_s.empty?
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Score:       #{book["score"]}/10"
  puts "  Saga:        #{metadata[:saga]["name"]} ##{metadata[:saga]["order"]}" if metadata[:saga]
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

  # Step 11: Git auto-commit
  git_auto_commit(book)
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
