#!/usr/bin/env ruby
# frozen_string_literal: true

# lookup.rb — Look up book metadata by ISBN or free-text query.
#
# Sources: Google Books, OpenLibrary (JSON API), OpenLibrary (HTML search),
# Goodreads, and Wikipedia (language-aware).
#
# All sources return the same standardized record shape, mirroring db.json.
# Prints a human-readable summary on stderr and a combined JSON document on
# stdout. Does not mutate db.json.
#
# Other scripts (e.g. add_book.rb) can `require_relative "lookup"` to access
# the dispatcher (`lookup`) and per-source fetchers programmatically.

require_relative "common"

# ---------------------------------------------------------------------------
# Input dispatch
# ---------------------------------------------------------------------------

def normalize_isbn(raw)
  cleaned = raw.to_s.gsub(/[\s\-]/, "")
  return nil unless cleaned =~ /\A(\d{9}[\dXx]|\d{13})\z/

  cleaned.upcase
end

def isbn_matches?(candidate, isbn)
  return false unless candidate

  candidate.gsub(/[\s\-]/, "").upcase == isbn
end

# ---------------------------------------------------------------------------
# Standardization
# ---------------------------------------------------------------------------

# Match against publishers.txt case-insensitively; return the canonical
# spelling if found, otherwise return the service-provided value as-is.
def sanitize_publisher(name)
  return name if name.nil? || name.to_s.strip.empty?

  match = load_publishers.find { |p| p.downcase == name.to_s.strip.downcase }
  match || name.to_s.strip
end

def build_identifiers(isbn_13, isbn_10)
  identifiers = []
  identifiers << { "type" => "ISBN_13", "value" => isbn_13 } if isbn_13 && !isbn_13.to_s.empty?
  identifiers << { "type" => "ISBN_10", "value" => isbn_10 } if isbn_10 && !isbn_10.to_s.empty?
  identifiers
end

def standardize(title:, subtitle: nil, original_title: nil, authors: [], publisher: nil,
                publish_date: nil, first_publishing_date: nil, isbn_13: nil, isbn_10: nil,
                identifiers: nil, cover_url: nil, url: nil, language: nil, saga: nil)
  ids = identifiers || build_identifiers(isbn_13, isbn_10)
  {
    "title" => title,
    "subtitle" => subtitle.to_s.empty? ? nil : subtitle,
    "original_title" => original_title.to_s.empty? ? nil : original_title,
    "authors" => Array(authors).compact,
    "publisher" => sanitize_publisher(publisher),
    "first_publishing_date" => first_publishing_date.to_s.empty? ? nil : first_publishing_date.to_s,
    "publish_dates" => publish_date.to_s.empty? ? [] : [publish_date.to_s],
    "identifiers" => ids,
    "cover_url" => cover_url,
    "url" => url,
    "language" => language,
    "saga" => saga
  }.compact
end

# ---------------------------------------------------------------------------
# Google Books
# ---------------------------------------------------------------------------

def google_volume_to_record(item)
  info = item["volumeInfo"] || {}
  industry = info["industryIdentifiers"] || []
  isbn_13 = industry.find { |id| id["type"] == "ISBN_13" }&.dig("identifier")
  isbn_10 = industry.find { |id| id["type"] == "ISBN_10" }&.dig("identifier")

  standardize(
    title: info["title"],
    subtitle: info["subtitle"],
    authors: info["authors"] || [],
    publisher: info["publisher"],
    publish_date: info["publishedDate"],
    isbn_13: isbn_13,
    isbn_10: isbn_10,
    cover_url: info.dig("imageLinks", "thumbnail"),
    url: info["infoLink"] || info["canonicalVolumeLink"],
    language: info["language"]
  )
end

def fetch_google_books_isbn(isbn, http: DEFAULT_HTTP)
  cached("googlebooks", isbn) do
    url = "https://www.googleapis.com/books/v1/volumes?q=isbn:#{isbn}"
    warn "Querying Google Books (ISBN)..."

    response = http.get_with_retry(url, headers: { "Accept" => "application/json" })
    warn "  Google Books HTTP #{response&.code || "network error"}"
    next nil unless response&.code == "200"

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      warn "  Google Books returned invalid JSON: #{e.message}"
      next nil
    end

    items = data["items"] || []
    next nil if items.empty?

    item = items.find do |it|
      identifiers = it.dig("volumeInfo", "industryIdentifiers") || []
      identifiers.any? { |id| isbn_matches?(id["identifier"], isbn) }
    end

    next nil unless item

    google_volume_to_record(item)
  end
end

def fetch_google_books_query(query, limit: 5, http: DEFAULT_HTTP)
  cached("googlebooks", query) do
    encoded = URI.encode_www_form_component(query)
    url = "https://www.googleapis.com/books/v1/volumes?q=#{encoded}&maxResults=#{limit}"
    warn "Querying Google Books (query)..."

    response = http.get_with_retry(url, headers: { "Accept" => "application/json" })
    warn "  Google Books HTTP #{response&.code || "network error"}"
    next [] unless response&.code == "200"

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      warn "  Google Books returned invalid JSON: #{e.message}"
      next []
    end

    (data["items"] || []).map { |item| google_volume_to_record(item) }.compact
  end
end

# ---------------------------------------------------------------------------
# OpenLibrary — JSON API
# ---------------------------------------------------------------------------

def openlibrary_entry_to_record(entry)
  identifiers = entry["identifiers"] || {}
  cover = entry["cover"] || {}

  standardize(
    title: entry["title"],
    subtitle: entry["subtitle"],
    authors: (entry["authors"] || []).map { |a| a["name"] }.compact,
    publisher: (entry["publishers"] || []).map { |p| p["name"] }.compact.first,
    publish_date: entry["publish_date"],
    isbn_13: (identifiers["isbn_13"] || []).first,
    isbn_10: (identifiers["isbn_10"] || []).first,
    cover_url: cover["large"] || cover["medium"] || cover["small"],
    url: entry["url"]
  )
end

def fetch_openlibrary_isbn(isbn, http: DEFAULT_HTTP)
  cached("openlibrary", isbn) do
    url = "https://openlibrary.org/api/books?bibkeys=ISBN:#{isbn}&format=json&jscmd=data"
    warn "Querying Open Library (ISBN)..."

    response = http.get_with_retry(url, headers: { "Accept" => "application/json" })
    warn "  Open Library HTTP #{response&.code || "network error"}"
    next nil unless response&.code == "200"

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      warn "  Open Library returned invalid JSON: #{e.message}"
      next nil
    end

    entry = data["ISBN:#{isbn}"]
    next nil unless entry

    openlibrary_entry_to_record(entry)
  end
end

def openlibrary_doc_to_record(doc)
  isbn_13 = (doc["isbn"] || []).find { |i| i.to_s.length == 13 }
  isbn_10 = (doc["isbn"] || []).find { |i| i.to_s.length == 10 }
  cover_id = doc["cover_i"]
  cover_url = cover_id ? "https://covers.openlibrary.org/b/id/#{cover_id}-L.jpg" : nil
  work_url = doc["key"] ? "https://openlibrary.org#{doc["key"]}" : nil

  standardize(
    title: doc["title"],
    subtitle: doc["subtitle"],
    authors: doc["author_name"] || [],
    publisher: (doc["publisher"] || []).first,
    first_publishing_date: doc["first_publish_year"]&.to_s,
    publish_date: doc["publish_date"]&.first,
    isbn_13: isbn_13,
    isbn_10: isbn_10,
    cover_url: cover_url,
    url: work_url,
    language: (doc["language"] || []).first
  )
end

def fetch_openlibrary_query(query, limit: 5, http: DEFAULT_HTTP)
  cached("openlibrary", query) do
    encoded = URI.encode_www_form_component(query)
    url = "https://openlibrary.org/search.json?q=#{encoded}&limit=#{limit}"
    warn "Querying Open Library (query)..."

    data = http.get_json(url)
    next [] unless data && data["docs"]

    data["docs"].first(limit).map { |doc| openlibrary_doc_to_record(doc) }.compact
  end
end

# ---------------------------------------------------------------------------
# OpenLibrary — HTML search (fallback for alternate ranking)
# ---------------------------------------------------------------------------

def fetch_openlibrary_html(query, limit: 5, http: DEFAULT_HTTP)
  cached("openlibrary_html", query) do
    fetch_openlibrary_html_uncached(query, limit: limit, http: http)
  end
end

def fetch_openlibrary_html_uncached(query, limit: 5, http: DEFAULT_HTTP)
  encoded = URI.encode_www_form_component(query)
  url = "https://openlibrary.org/search?q=#{encoded}"
  warn "Scraping Open Library HTML search..."

  response = http.get(url, headers: { "Accept" => "text/html,application/xhtml+xml" })
  unless response&.code == "200"
    warn "  Open Library HTML HTTP #{response&.code || "network error"}"
    return []
  end

  html = response.body
  records = []

  # Each result is a <li class="searchResultItem">. Extract title (link to /works/),
  # author name, and cover image URL when present.
  html.scan(/<li[^>]*class="[^"]*searchResultItem[^"]*"[^>]*>(.*?)<\/li>/m).each do |match|
    block = match[0]

    title = nil
    work_url = nil
    if block =~ /<h3[^>]*itemprop="name"[^>]*>(.*?)<\/h3>/m
      header = $1
      if header =~ /<a[^>]+href="([^"]+)"[^>]*>(.*?)<\/a>/m
        work_url = $1.start_with?("http") ? $1 : "https://openlibrary.org#{$1}"
        title = decode_html(strip_tags($2)).strip
      else
        title = decode_html(strip_tags(header)).strip
      end
    end

    next if title.nil? || title.empty?

    authors = []
    block.scan(/<a[^>]+href="\/authors\/[^"]*"[^>]*>([^<]+)<\/a>/).each do |a|
      name = decode_html(a[0]).strip
      authors << name unless name.empty? || authors.include?(name)
    end

    cover_url = nil
    if block =~ /<img[^>]+(?:class="[^"]*bookcover[^"]*"|src="https:\/\/covers\.openlibrary\.org[^"]*")[^>]*src="([^"]+)"/m
      cover_url = $1
    elsif block =~ /<img[^>]+src="([^"]*covers\.openlibrary\.org[^"]*)"/
      cover_url = $1
    end

    records << standardize(
      title: title,
      authors: authors,
      cover_url: cover_url,
      url: work_url
    )

    break if records.size >= limit
  end

  warn "  Open Library HTML returned #{records.size} result(s)."
  records
rescue StandardError => e
  warn "  Open Library HTML scraping failed: #{e.message}"
  []
end

# ---------------------------------------------------------------------------
# Goodreads
# ---------------------------------------------------------------------------

def goodreads_detail_to_record(detail)
  return nil unless detail && detail[:title] && !detail[:title].empty?

  saga = nil
  if detail[:saga_name]
    saga = { "name" => detail[:saga_name], "order" => detail[:saga_order] || 1 }
  end

  isbn_str = detail[:isbn].to_s
  isbn_13 = isbn_str.length == 13 ? isbn_str : nil
  isbn_10 = isbn_str.length == 10 ? isbn_str : nil

  standardize(
    title: detail[:title],
    subtitle: detail[:subtitle],
    original_title: detail[:original_title],
    authors: detail[:authors] || [],
    publisher: detail[:publisher],
    first_publishing_date: detail[:first_publishing_date],
    isbn_13: isbn_13,
    isbn_10: isbn_10,
    cover_url: detail[:cover_url],
    saga: saga
  )
end

def fetch_goodreads(query, limit: 3, http: DEFAULT_HTTP)
  cached("goodreads", query) do
    results = goodreads_search(query, http: http)
    next [] if results.empty?

    records = []
    results.first(limit).each do |result|
      detail = scrape_goodreads_detail(result[:url], http: http)
      record = goodreads_detail_to_record(detail)
      if record
        record["url"] ||= result[:url]
        records << record
      elsif result[:title]
        records << standardize(
          title: result[:title],
          authors: result[:author] && result[:author] != "Unknown" ? [result[:author]] : [],
          url: result[:url]
        )
      end
    end

    records
  end
end

# ---------------------------------------------------------------------------
# Wikipedia (augmentation only)
# ---------------------------------------------------------------------------

def detect_language(records)
  records.flatten.compact.each do |rec|
    lang = rec["language"]
    return lang if lang && %w[es en].include?(lang)
  end
  "es"
end

def best_title(records)
  records.flatten.compact.map { |r| r["title"] }.compact.first
end

def best_author(records)
  records.flatten.compact.map { |r| (r["authors"] || []).first }.compact.first
end

def fetch_wikipedia(records, http: DEFAULT_HTTP)
  title = best_title(records)
  return nil unless title

  language = detect_language(records)
  author = best_author(records)
  cache_query = [title, author, language].compact.join("|")

  cached("wikipedia", cache_query) do
    info = search_wikipedia(title, author, language: language, http: http)
    next nil unless info

    standardize(
      title: info[:page_title],
      original_title: info[:original_title],
      isbn_13: info[:isbn]&.length == 13 ? info[:isbn] : nil,
      isbn_10: info[:isbn]&.length == 10 ? info[:isbn] : nil,
      url: info[:url],
      language: info[:language]
    )
  end
end

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

# Returns a hash keyed by source label. Each value is a single record (ISBN
# lookup) or an array of records (text query). Wikipedia, when present, is
# always a single record (it augments the other sources).
def lookup(query, http: DEFAULT_HTTP)
  isbn = normalize_isbn(query)
  isbn ? lookup_isbn(isbn, http: http) : lookup_text(query, http: http)
end

def lookup_isbn(isbn, http: DEFAULT_HTTP)
  warn "Looking up ISBN #{isbn}"

  google = fetch_google_books_isbn(isbn, http: http)
  openlibrary = fetch_openlibrary_isbn(isbn, http: http)
  goodreads = fetch_goodreads(isbn, limit: 1, http: http).first

  result = {}
  result["googlebooks"] = google if google
  result["openlibrary"] = openlibrary if openlibrary
  result["goodreads"] = goodreads if goodreads

  wiki = fetch_wikipedia(result.values, http: http)
  result["wikipedia"] = wiki if wiki

  result
end

def lookup_text(query, http: DEFAULT_HTTP)
  warn "Searching for: #{query}"

  google = fetch_google_books_query(query, http: http)
  openlibrary_api = fetch_openlibrary_query(query, http: http)
  openlibrary_html = fetch_openlibrary_html(query, http: http)
  goodreads = fetch_goodreads(query, http: http)

  result = {}
  result["googlebooks"] = google unless google.empty?
  result["openlibrary"] = openlibrary_api unless openlibrary_api.empty?
  result["openlibrary_html"] = openlibrary_html unless openlibrary_html.empty?
  result["goodreads"] = goodreads unless goodreads.empty?

  wiki = fetch_wikipedia(result.values, http: http)
  result["wikipedia"] = wiki if wiki

  result
end

# ---------------------------------------------------------------------------
# CLI summary
# ---------------------------------------------------------------------------

def print_record_summary(label, record)
  warn ""
  warn "── #{label} ──"
  warn "  title:     #{record["title"]}" if record["title"]
  warn "  subtitle:  #{record["subtitle"]}" if record["subtitle"]
  warn "  original:  #{record["original_title"]}" if record["original_title"]
  warn "  authors:   #{record["authors"].join(", ")}" if record["authors"]&.any?
  warn "  publisher: #{record["publisher"]}" if record["publisher"]
  warn "  first pub: #{record["first_publishing_date"]}" if record["first_publishing_date"]
  warn "  published: #{record["publish_dates"].join(", ")}" if record["publish_dates"]&.any?
  (record["identifiers"] || []).each do |id|
    warn "  #{id["type"].downcase.tr("_", "-").ljust(9)}: #{id["value"]}"
  end
  warn "  saga:      #{record["saga"]["name"]} ##{record["saga"]["order"]}" if record["saga"]
  warn "  language:  #{record["language"]}" if record["language"]
  warn "  cover:     #{record["cover_url"]}" if record["cover_url"]
  warn "  url:       #{record["url"]}" if record["url"]
end

def print_summary(result)
  result.each do |source, value|
    if value.is_a?(Array)
      value.each_with_index do |record, i|
        print_record_summary("#{source} ##{i + 1}", record)
      end
    else
      print_record_summary(source, value)
    end
  end
end

def main
  raw = ARGV.join(" ").strip
  if raw.empty?
    warn "Usage: ruby scripts/lookup.rb <ISBN-or-text-query>"
    warn "  ISBN: 10 or 13 digits, with or without dashes/spaces"
    warn "  Text: any free-text search (book title, author, etc.)"
    exit 1
  end

  result = lookup(raw)

  if result.empty?
    warn ""
    warn "No data found for #{raw.inspect} from any source."
    puts "{}"
    exit 1
  end

  print_summary(result)

  warn ""
  puts JSON.pretty_generate(result)
end

main if $PROGRAM_NAME == __FILE__
