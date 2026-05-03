# frozen_string_literal: true

# common.rb — Shared functionality for Lev book management scripts

require "json"
require "net/http"
require "uri"
require "tempfile"
require "fileutils"
require "readline"
require "io/console"
require "digest"

ROOT_DIR = File.expand_path("..", __dir__)
DB_PATH = File.join(ROOT_DIR, "docs", "db.json")
COVERS_DIR = File.join(ROOT_DIR, "docs", "covers")
DEFAULT_CACHE_DIR = File.join(ROOT_DIR, ".cache")
CACHE_TTL_SECONDS = 48 * 60 * 60
HTTP_TIMEOUT = 10 # seconds

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
             "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

PUBLISHERS_PATH = File.join(ROOT_DIR, "publishers.txt")

def load_publishers
  return [] unless File.exist?(PUBLISHERS_PATH)

  File.readlines(PUBLISHERS_PATH, chomp: true).reject(&:empty?).sort
end

def add_publisher(name)
  publishers = load_publishers
  return if publishers.any? { |p| p.downcase == name.downcase }

  publishers << name
  File.write(PUBLISHERS_PATH, publishers.sort.join("\n") + "\n")
end

def select_publisher(default: nil)
  publishers = load_publishers

  items = publishers.map do |pub|
    marker = (default && pub.downcase == default.to_s.downcase) ? " *" : ""
    "#{pub}#{marker}"
  end
  items << "Other (enter custom)"

  puts "\nPublisher:"
  # Pre-select the default publisher or "Other" at the end
  default_idx = if default && !default.to_s.empty?
                  publishers.index { |p| p.downcase == default.to_s.downcase } || items.size - 1
                else
                  0
                end

  idx = interactive_select(items, prompt_label: "Publisher", default: default_idx)
  return "" unless idx

  if idx < publishers.size
    selected = publishers[idx]
  else
    name = prompt("  Enter publisher name")
    return "" if name.to_s.empty?
    add_publisher(name)
    return name
  end

  add_publisher(selected) if selected && !selected.empty?
  selected
end

# ---------------------------------------------------------------------------
# Cache layer — per-source key/value store. Key is the ISBN if the input is
# a valid ISBN-10/13, else SHA1 of the normalized text. Entries older than
# CACHE_TTL_SECONDS are ignored. Empty / nil results are NOT cached, so
# transient failures recover.
#
# Two implementations:
#   * DiskCache — JSON files at <dir>/<source>/<key>.json. Default for the
#     CLI. <dir> defaults to .cache/, overridable via LEV_CACHE_DIR.
#   * MemoryCache — in-process Hash. Used by the test suite.
#
# Swap via Cache.default = MemoryCache.new in tests.
# ---------------------------------------------------------------------------

def cache_key(query)
  cleaned = query.to_s.gsub(/[\s\-]/, "")
  if cleaned =~ /\A(\d{9}[\dXx]|\d{13})\z/
    cleaned.upcase
  else
    Digest::SHA1.hexdigest(query.to_s.strip.downcase)
  end
end

class MemoryCache
  def initialize(ttl: CACHE_TTL_SECONDS, clock: -> { Time.now })
    @store = {}
    @ttl = ttl
    @clock = clock
  end

  def read(source, key)
    entry = @store[[source, key]]
    return nil unless entry
    return nil if (@clock.call - entry[:cached_at]) >= @ttl

    entry[:result]
  end

  def write(source, key, result)
    return if result.nil?
    return if result.respond_to?(:empty?) && result.empty?

    @store[[source, key]] = { cached_at: @clock.call, result: result }
  end

  def clear
    @store.clear
  end

  def size
    @store.size
  end
end

class DiskCache
  def initialize(dir: nil, ttl: CACHE_TTL_SECONDS)
    @dir = dir || ENV["LEV_CACHE_DIR"] || DEFAULT_CACHE_DIR
    @ttl = ttl
  end

  attr_reader :dir

  def read(source, key)
    path = path_for(source, key)
    return nil unless fresh?(path)

    data = JSON.parse(File.read(path, encoding: "UTF-8"))
    data["result"]
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  def write(source, key, result)
    return if result.nil?
    return if result.respond_to?(:empty?) && result.empty?

    path = path_for(source, key)
    FileUtils.mkdir_p(File.dirname(path))
    payload = { "cached_at" => Time.now.to_i, "source" => source, "key" => key, "result" => result }
    File.write(path, JSON.pretty_generate(payload))
  rescue StandardError => e
    warn "  Cache write failed (#{source}/#{key}): #{e.message}"
  end

  def clear
    FileUtils.rm_rf(@dir)
  end

  private

  def path_for(source, key)
    File.join(@dir, source, "#{key}.json")
  end

  def fresh?(path)
    File.exist?(path) && (Time.now - File.mtime(path)) < @ttl
  end
end

module Cache
  class << self
    attr_writer :default

    def default
      @default ||= DiskCache.new
    end
  end
end

def cached(source, query, cache: Cache.default)
  key = cache_key(query)
  hit = cache.read(source, key)
  if hit
    warn "  [cache] #{source} hit (#{key[0, 12]})"
    return hit
  end

  result = yield
  cache.write(source, key, result)
  result
end

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

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
# DB helpers
# ---------------------------------------------------------------------------

def load_db
  empty = { "authors" => [], "books" => [] }
  return empty unless File.exist?(DB_PATH)

  data = File.read(DB_PATH, encoding: "UTF-8")
  return empty if data.strip.empty?

  parsed = JSON.parse(data)

  if parsed.is_a?(Hash) && parsed.key?("authors") && parsed.key?("books")
    parsed
  elsif parsed.is_a?(Array)
    # Legacy flat-array format — wrap for compatibility
    { "authors" => [], "books" => parsed }
  else
    empty
  end
rescue JSON::ParserError => e
  warn "Warning: could not parse db.json (#{e.message})."
  empty
end

def save_db(db)
  db["authors"].sort_by! { |a| (a["name"] || "").unicode_normalize(:nfkd).downcase }
  db["books"].sort_by! { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }

  json = JSON.pretty_generate(db, indent: "  ")

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

def sanitize_title(title)
  title
    .downcase
    .gsub(/[^a-z0-9]/, "-")
    .gsub(/-{2,}/, "-")
    .gsub(/\A-|-\z/, "")
end

# ---------------------------------------------------------------------------
# Author helpers
# ---------------------------------------------------------------------------

def find_author_by_name(db, name)
  db["authors"].find { |a| a["name"].downcase == name.downcase }
end

def find_or_create_author(db, name, aliases: [])
  existing = find_author_by_name(db, name)
  return existing if existing

  author = {
    "id" => next_id(db["authors"]),
    "name" => name,
    "aliases" => aliases
  }
  db["authors"] << author
  author
end

def resolve_author_names(db, book)
  (book["author_ids"] || []).map do |aid|
    db["authors"].find { |a| a["id"] == aid }&.dig("name")
  end.compact
end

def author_book_count(db, author)
  db["books"].count { |b| (b["author_ids"] || []).include?(author["id"]) }
end

# ---------------------------------------------------------------------------
# Interactive list selector (arrow key navigation)
# ---------------------------------------------------------------------------

def interactive_select(items, prompt_label: "Select", default: 0, multi: false, preselected: [])
  return nil if items.empty?
  return [] if multi && items.empty?

  cursor = default.clamp(0, items.size - 1)
  chosen = preselected.is_a?(Array) ? preselected.select { |i| i.between?(0, items.size - 1) }.uniq : []
  max_visible = [items.size, 20].min
  offset = 0
  rendered_lines = 0

  render = lambda {
    if rendered_lines > 0
      print "\e[#{rendered_lines}A"
      rendered_lines.times { print "\e[2K\n" }
      print "\e[#{rendered_lines}A"
    end

    lines = 0

    label = multi ? "#{prompt_label} (space=toggle, enter=confirm)" : prompt_label
    if items.size > max_visible
      pos = "#{cursor + 1}/#{items.size}"
      puts "\e[2K  \e[90m#{label} (#{pos})\e[0m"
      lines += 1
    elsif multi
      puts "\e[2K  \e[90m#{label}\e[0m"
      lines += 1
    end

    max_visible.times do |i|
      idx = offset + i
      if idx < items.size
        checkbox = multi ? (chosen.include?(idx) ? "[•] " : "[ ] ") : ""
        if idx == cursor
          puts "\e[2K\e[33m>\e[0m \e[1m#{checkbox}#{items[idx]}\e[0m"
        else
          puts "\e[2K  #{checkbox}#{items[idx]}"
        end
      else
        puts "\e[2K"
      end
      lines += 1
    end

    rendered_lines = lines
  }

  render.call

  loop do
    key = read_key
    case key
    when :up
      if cursor > 0
        cursor -= 1
        offset = cursor if cursor < offset
      end
    when :down
      if cursor < items.size - 1
        cursor += 1
        offset = cursor - max_visible + 1 if cursor >= offset + max_visible
      end
    when :space
      if multi
        if chosen.include?(cursor)
          chosen.delete(cursor)
        else
          chosen << cursor
        end
      end
    when :enter
      if multi
        return chosen.empty? ? [cursor] : chosen.sort
      end
      return cursor
    when :ctrl_c
      puts ""
      exit 130
    else
      next
    end
    render.call
  end
end

def read_key
  $stdin.raw do |io|
    input = io.getc
    if input == "\e"
      # Stay in raw mode to read the rest of the escape sequence
      if IO.select([io], nil, nil, 0.1)
        input << (io.read_nonblock(2) rescue "")
      end
    end

    case input
    when "\e[A" then :up
    when "\e[B" then :down
    when "\e[C" then :right
    when "\e[D" then :left
    when "\r", "\n" then :enter
    when " " then :space
    when "\u0003" then :ctrl_c
    else input.to_s.downcase
    end
  end
end

def interactive_choice(choices, prompt_label: "Select", default: 0)
  return nil if choices.empty?

  selected = default.clamp(0, choices.size - 1)
  rendered_lines = 0

  render = lambda {
    if rendered_lines > 0
      print "\e[#{rendered_lines}A"
      rendered_lines.times { print "\e[2K\n" }
      print "\e[#{rendered_lines}A"
    end

    puts "\e[2K  \e[90m#{prompt_label}\e[0m"
    choices.each_with_index do |choice, idx|
      key = choice[:key] || choice["key"]
      label = choice[:label] || choice["label"]
      prefix = idx == selected ? "\e[33m>\e[0m \e[1m" : "  "
      suffix = idx == selected ? "\e[0m" : ""
      hotkey = key ? "[#{key}] " : ""
      puts "\e[2K  #{prefix}#{hotkey}#{label}#{suffix}"
    end
    rendered_lines = choices.size + 1
  }

  render.call

  loop do
    key = read_key
    case key
    when :up
      selected -= 1 if selected > 0
    when :down
      selected += 1 if selected < choices.size - 1
    when :enter
      return choices[selected]
    when :ctrl_c
      puts ""
      exit 130
    else
      matched = choices.find { |choice| (choice[:key] || choice["key"]).to_s.downcase == key }
      return matched if matched
      next
    end
    render.call
  end
end

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

def prompt(label, default: nil, required: false, clearable: false)
  loop do
    suffix = default && !default.to_s.empty? ? " [#{default}]" : ""
    hint = clearable && default && !default.to_s.empty? ? " (- to clear)" : ""
    input = Readline.readline("#{label}#{suffix}#{hint}: ", false)
    abort "\nCancelled." unless input
    input = input.strip

    # Clearable: typing "-" explicitly clears the value
    return "" if clearable && input == "-"

    input = default.to_s if input.empty? && default && !default.to_s.empty?
    return input unless input.to_s.empty? && required

    puts "  This field is required."
  end
end

def prompt_yes_no(label, default: "y")
  answer = prompt(label, default: default)
  answer.downcase.start_with?("y")
end

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def format_book_line(book, index, db)
  marker = book["review"].to_s.strip.empty? ? " " : "*"
  names = resolve_author_names(db, book)
  author = names.first || "Unknown"
  score  = book["score"] || "?"

  parts = [book["title"]]
  subtitle = book["subtitle"].to_s
  parts << subtitle unless subtitle.empty?
  parts << author
  label = parts.join(" — ")

  saga = book["saga"]
  saga_tag = saga ? " [#{saga["name"]} ##{saga["order"]}]" : ""

  format("[%s] %2d. %s (%s/10)%s", marker, index + 1, label, score, saga_tag)
end

def display_book_list(books, db)
  puts ""
  books.each_with_index do |book, i|
    puts "  #{format_book_line(book, i, db)}"
  end
  puts ""
end

def prompt_book_selection(books, db)
  items = books.each_with_index.map { |book, i| format_book_line(book, i, db) }
  idx = interactive_select(items, prompt_label: "Select a book")
  abort "\nCancelled." unless idx
  idx
end

def prompt_score(current_score)
  input = Readline.readline("Update score? (current: #{current_score || "none"}) [enter to skip]: ", false)
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

def prompt_score_update(current_score)
  loop do
    input = Readline.readline("New score? (current: #{current_score || "none"}) [enter to keep]: ", false)
    if input.nil?
      puts ""
      exit 130
    end

    input = input.strip
    return nil if input.empty?

    score = input.to_i
    return score if score >= 1 && score <= 10 && score.to_s == input

    puts "  Please enter a whole number between 1 and 10, or press enter to keep current."
  end
end

def numeric_score?(book)
  book["score"].is_a?(Numeric)
end

def format_book_title_author(book, db)
  author = resolve_author_names(db, book).first || "Unknown"
  "#{book["title"]} — #{author}"
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

# Retry on 429, 5XX, and network errors with exponential backoff (1s, 2s, 4s).
# Honors the Retry-After header on 429 when present as a positive integer.
# Returns the final response (which may still be retryable) or nil on network failure.
# Other 4XX responses are returned immediately without retry.
def http_get_with_retry(url, headers: {}, retries: 3)
  delay = 1
  attempt = 0

  loop do
    response = http_get(url, headers: headers)
    retryable = response.nil? || response.code == "429" || response.code.start_with?("5")
    return response unless retryable

    attempt += 1
    break response if attempt > retries

    wait = if response && response.code == "429" && response["retry-after"] =~ /\A\d+\z/
             response["retry-after"].to_i
           else
             delay
           end

    reason = response ? "HTTP #{response.code}" : "network error"
    warn "  #{reason} — retrying in #{wait}s (attempt #{attempt}/#{retries})..."
    sleep wait
    delay *= 2
  end
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
# HTTP client — thin object wrapper around the module-level helpers so we
# can inject a fake in tests. Each fetcher takes `http: DEFAULT_HTTP`.
# ---------------------------------------------------------------------------

class HttpClient
  def get(url, headers: {}, follow_redirects: true, max_redirects: 5)
    http_get(url, headers: headers, follow_redirects: follow_redirects, max_redirects: max_redirects)
  end

  def get_json(url)
    http_get_json(url)
  end

  def get_with_retry(url, headers: {}, retries: 3)
    http_get_with_retry(url, headers: headers, retries: retries)
  end

  def download(url, dest)
    http_download(url, dest)
  end
end

DEFAULT_HTTP = HttpClient.new

# ---------------------------------------------------------------------------
# Goodreads search
# ---------------------------------------------------------------------------

def goodreads_search(query, http: DEFAULT_HTTP)
  encoded = URI.encode_www_form_component(query).gsub("%20", "+")
  url = "https://www.goodreads.com/search?utf8=%E2%9C%93&q=#{encoded}&search_type=books"
  warn "Searching Goodreads..."

  response = http.get(url, headers: { "Accept" => "text/html,application/xhtml+xml" })

  unless response&.code == "200"
    warn "  Goodreads search unavailable (HTTP #{response&.code})."
    return []
  end

  html = response.body
  results = []

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

      results << { title: title, author: "Unknown", url: book_url }
      break if results.size >= 10
    end
  end

  warn "  No results found on Goodreads." if results.empty?

  results
rescue StandardError => e
  warn "  Goodreads search failed: #{e.message}"
  []
end

# ---------------------------------------------------------------------------
# Goodreads detail scraping
# ---------------------------------------------------------------------------

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

  # --- Title + Series from titleComplete ---
  raw_title = book_obj["titleComplete"] || book_obj["title"] || ""
  # Extract series from title pattern: "Title (Series Name, #N)"
  if raw_title =~ /\A(.+?)\s*\((.+?),?\s*#(\d+(?:\.\d+)?)\)\s*\z/
    title_part = $1.strip
    detail[:saga_name] = decode_html($2).strip.chomp(",").strip
    detail[:saga_order] = $3.to_i
    detail[:saga_order] = 1 if detail[:saga_order] < 1
    if title_part.include?(":")
      parts = title_part.split(":", 2)
      detail[:title] = parts[0].strip
      detail[:subtitle] = parts[1].strip
    else
      detail[:title] = title_part
    end
  elsif raw_title.include?(":")
    parts = raw_title.split(":", 2)
    detail[:title] = parts[0].strip
    detail[:subtitle] = parts[1].strip
  else
    detail[:title] = raw_title.strip
  end

  # --- Cover image ---
  detail[:cover_url] = book_obj["imageUrl"] if book_obj["imageUrl"]

  # --- Contributors with roles ---
  contributors = []
  primary = book_obj["primaryContributorEdge"]
  if primary
    ref = primary.dig("node", "__ref")
    contributor = apollo[ref] if ref
    if contributor&.dig("name")
      contributors << { name: contributor["name"], role: primary["role"] || "Author" }
    end
  end
  (book_obj["secondaryContributorEdges"] || []).each do |edge|
    ref = edge.dig("node", "__ref")
    contributor = apollo[ref] if ref
    if contributor&.dig("name")
      contributors << { name: contributor["name"], role: edge["role"] || "Contributor" }
    end
  end
  detail[:contributors] = contributors unless contributors.empty?
  detail[:authors] = contributors.map { |c| c[:name] } unless contributors.empty?

  # --- Series/Saga (augment from Apollo if not found in title) ---
  unless detail[:saga_name]
    series_list = book_obj["bookSeries"] || []
    series_list.each do |series_entry|
      series_ref = series_entry.dig("series", "__ref")
      series_obj = series_ref ? apollo[series_ref] : series_entry["series"]
      if series_obj && series_obj["title"]
        name = decode_html(strip_tags(series_obj["title"])).strip
        # Skip if contaminated with HTML fragments
        next if name =~ /[<>"]/ || name.length > 200
        detail[:saga_name] = name
        detail[:saga_order] = (series_entry["userPosition"] || "1").to_i
        detail[:saga_order] = 1 if detail[:saga_order] < 1
        break
      end
    end
  end

  # --- Original title from Work ---
  if work_obj
    orig = work_obj.dig("details", "originalTitle")
    # If details is a ref, follow it
    if orig.nil?
      details_ref = work_obj.dig("details", "__ref")
      if details_ref
        work_details = apollo[details_ref]
        orig = work_details["originalTitle"] if work_details.is_a?(Hash)
      end
    end
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

  # Also check Apollo state for ISBN
  if detail[:isbn].nil? || detail[:isbn].to_s.empty?
    details_ref = book_obj.dig("details", "__ref")
    details_obj = details_ref ? apollo[details_ref] : book_obj["details"]
    if details_obj.is_a?(Hash)
      isbn13 = details_obj["isbn13"]
      isbn10 = details_obj["isbn"]
      if isbn13 && isbn13.to_s =~ /\A97[89]\d{10}\z/
        detail[:isbn] = isbn13.to_s.strip
      elsif isbn10 && isbn10.to_s =~ /\A\d{9}[\dXx]\z/
        detail[:isbn] = isbn10.to_s.strip
      end
    end
  end

  detail
rescue JSON::ParserError => e
  warn "  __NEXT_DATA__ JSON parse error: #{e.message}"
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
  # Extract from JSON-LD name (reliable, properly encoded) instead of raw HTML regex
  saga_source = nil
  begin
    ld_match = html.match(/<script type="application\/ld\+json">(.*?)<\/script>/m)
    if ld_match
      ld_data = JSON.parse(ld_match[1])
      saga_source = ld_data["name"] if ld_data["name"]
    end
  rescue JSON::ParserError
    # ignore
  end
  saga_source ||= detail[:title]
  if saga_source && saga_source =~ /\((.+?),?\s*#(\d+(?:\.\d+)?)\)/
    detail[:saga_name] = decode_html($1).strip.chomp(",").strip
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
  unless authors.empty?
    # Detect contributor roles from nearby HTML context
    detail[:contributors] = authors.map do |name|
      role = "Author"
      escaped = Regexp.escape(name)
      if html =~ /#{escaped}<\/span>[\s\S]{0,200}?ContributorLink__role[^>]*>\s*\(?(\w+)\)?/m
        detected = $1.strip
        role = detected if %w[Translator Editor Illustrator Narrator].include?(detected)
      end
      { name: name, role: role }
    end
    detail[:authors] = authors
  end

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
  begin
    ld_match = html.match(/<script type="application\/ld\+json">(.*?)<\/script>/m)
    if ld_match
      ld_isbn = JSON.parse(ld_match[1])["isbn"]
      detail[:isbn] = ld_isbn if ld_isbn && !ld_isbn.to_s.empty?
    end
  rescue JSON::ParserError
    # ignore
  end
  if detail[:isbn].nil? || detail[:isbn].to_s.empty?
    if html =~ /ISBN13.*?(\d{13})/m
      detail[:isbn] = $1
    elsif html =~ /ISBN.*?(\d{13})/m
      detail[:isbn] = $1
    elsif html =~ /ISBN.*?(\d{9}[\dXx])/m
      detail[:isbn] = $1
    end
  end
  if detail[:isbn].nil? || detail[:isbn].to_s.empty?
    if html =~ /<meta[^>]+property="books:isbn"[^>]+content="([^"]+)"/
      detail[:isbn] = $1.strip
    end
  end
  # Validate ISBN-13 prefix (must start with 978 or 979)
  if detail[:isbn] && detail[:isbn].length == 13 && detail[:isbn] !~ /\A97[89]/
    detail[:isbn] = nil
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

def scrape_goodreads_detail(url, http: DEFAULT_HTTP)
  warn "Fetching Goodreads book page (#{url})..."
  response = http.get(url, headers: { "Accept" => "text/html,application/xhtml+xml" })

  unless response&.code == "200"
    warn "  Could not fetch book page (HTTP #{response&.code})."
    return nil
  end

  html = response.body

  begin
    detail = scrape_goodreads_detail_from_next_data(html)
    if detail && detail[:title] && !detail[:title].empty?
      warn "  Parsed book data from structured JSON."
      return detail
    end
  rescue StandardError => e
    warn "  __NEXT_DATA__ extraction failed (#{e.message}), falling back to HTML scraping..."
  end

  detail = scrape_goodreads_detail_from_html(html)
  return detail unless detail.empty?

  nil
rescue StandardError => e
  warn "  Goodreads detail scraping failed: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Spanish Wikipedia augmentation
# ---------------------------------------------------------------------------

WIKIPEDIA_BOOK_KEYWORDS = {
  "es" => /(?:libro|novela|ficha de libro|t[ií]tulo[_ ]orig|isbn)/i,
  "en" => /(?:novel|book|original[_ ]title|isbn)/i
}.freeze

WIKIPEDIA_ORIG_TITLE_RE = {
  "es" => /t[ií]tulo[_ ]orig(?:inal)?\s*=\s*(.+)/i,
  "en" => /(?:orig[_ ]title|name[_ ]orig|original[_ ]title)\s*=\s*(.+)/i
}.freeze

def search_wikipedia(title, author = nil, language: "es", http: DEFAULT_HTTP)
  language = language.to_s.downcase
  language = "es" unless WIKIPEDIA_BOOK_KEYWORDS.key?(language)

  query = title.dup
  query << " #{author}" if author && !author.empty?
  encoded = URI.encode_www_form_component(query)
  url = "https://#{language}.wikipedia.org/w/api.php?action=query&list=search&srsearch=#{encoded}&format=json&srlimit=5&srnamespace=0"

  warn "Searching #{language.upcase} Wikipedia..."
  data = http.get_json(url)
  return nil unless data && data.dig("query", "search")&.any?

  book_keywords = WIKIPEDIA_BOOK_KEYWORDS[language]
  orig_title_re = WIKIPEDIA_ORIG_TITLE_RE[language]

  data.dig("query", "search").each do |result|
    page_title = result["title"]
    next unless page_title

    parse_url = "https://#{language}.wikipedia.org/w/api.php?action=parse&page=#{URI.encode_www_form_component(page_title)}&prop=wikitext&format=json&redirects=1"
    page_data = http.get_json(parse_url)
    wikitext = page_data&.dig("parse", "wikitext", "*")
    next unless wikitext
    next unless wikitext =~ book_keywords

    info = {}

    if wikitext =~ orig_title_re
      val = $1.strip.sub(/\s*[|\}].*/, "").strip
      val = val.gsub(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/, '\1').gsub(/'{2,}/, "").strip
      info[:original_title] = val unless val.empty?
    end

    if wikitext =~ /isbn\s*=\s*([\d][-\d ]+[\dXx])/i
      isbn = $1.strip.gsub(/[- ]/, "")
      info[:isbn] = isbn if isbn =~ /\A\d{10,13}\z/
    end

    next if info.empty?

    info[:page_title] = page_title
    info[:url] = "https://#{language}.wikipedia.org/wiki/#{URI.encode_www_form_component(page_title)}"
    info[:language] = language
    warn "  Found: #{page_title}"
    return info
  end

  warn "  No relevant information found."
  nil
rescue StandardError => e
  warn "  Wikipedia search failed: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Git auto-commit
# ---------------------------------------------------------------------------

def git_auto_commit(action, book, db, include_covers: false)
  names = resolve_author_names(db, book)
  author = names.first || "Unknown"
  system("git", "add", DB_PATH)
  system("git", "add", "#{COVERS_DIR}/") if include_covers
  system("git", "commit", "-m", "#{action} #{book["title"]} - #{author} book")
rescue StandardError
  # Don't fail if git is not available or repo not initialized
end

def git_commit_paths(paths, message)
  Array(paths).each { |path| system("git", "add", path) }
  system("git", "commit", "-m", message)
rescue StandardError
  # Don't fail if git is not available or repo not initialized
end
