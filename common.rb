# frozen_string_literal: true

# common.rb — Shared functionality for Lev book management scripts

require "json"
require "net/http"
require "uri"
require "tempfile"
require "fileutils"

DB_PATH = File.join(__dir__, "public", "db.json")
COVERS_DIR = File.join(__dir__, "public", "covers")
HTTP_TIMEOUT = 10 # seconds

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
             "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

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
  return [] unless File.exist?(DB_PATH)

  data = File.read(DB_PATH, encoding: "UTF-8")
  return [] if data.strip.empty?

  books = JSON.parse(data)
  return [] unless books.is_a?(Array)

  books
rescue JSON::ParserError => e
  warn "Warning: could not parse db.json (#{e.message})."
  []
end

def save_db(books)
  sorted = books.sort_by { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }
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

def sanitize_title(title)
  title
    .downcase
    .gsub(/[^a-z0-9]/, "-")
    .gsub(/-{2,}/, "-")
    .gsub(/\A-|-\z/, "")
end

# ---------------------------------------------------------------------------
# Prompt helpers
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

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def display_book_list(books)
  puts ""
  books.each_with_index do |book, i|
    marker = book["review"].to_s.strip.empty? ? " " : "*"
    author = book.dig("authors", 0, "name") || "Unknown"
    score  = book["score"] || "?"

    parts = [book["title"]]
    subtitle = book["subtitle"].to_s
    parts << subtitle unless subtitle.empty?
    parts << author
    label = parts.join(" — ")

    saga = book["saga"]
    saga_tag = saga ? " [#{saga["name"]} ##{saga["order"]}]" : ""

    printf "  [%s] %2d. %s (%s/10)%s\n", marker, i + 1, label, score, saga_tag
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
    return num - 1 if num >= 1 && num <= books.length

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
# Goodreads search
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

  puts "  No results found on Goodreads." if results.empty?

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
# Spanish Wikipedia augmentation
# ---------------------------------------------------------------------------

def search_wikipedia_es(title, author = nil)
  query = title.dup
  query << " #{author}" if author && !author.empty?
  encoded = URI.encode_www_form_component(query)
  url = "https://es.wikipedia.org/w/api.php?action=query&list=search&srsearch=#{encoded}&format=json&srlimit=5&srnamespace=0"

  puts "\nSearching Spanish Wikipedia..."
  data = http_get_json(url)
  return nil unless data && data.dig("query", "search")&.any?

  data.dig("query", "search").each do |result|
    page_title = result["title"]
    next unless page_title

    parse_url = "https://es.wikipedia.org/w/api.php?action=parse&page=#{URI.encode_www_form_component(page_title)}&prop=wikitext&format=json&redirects=1"
    page_data = http_get_json(parse_url)
    wikitext = page_data&.dig("parse", "wikitext", "*")
    next unless wikitext

    # Verify this is about a book or novel
    next unless wikitext =~ /(?:libro|novela|ficha de libro|t[ií]tulo[_ ]orig|isbn)/i

    info = {}

    # Extract original title
    if wikitext =~ /t[ií]tulo[_ ]orig(?:inal)?\s*=\s*(.+)/i
      val = $1.strip.sub(/\s*[|\}].*/, "").strip
      val = val.gsub(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/, '\1').gsub(/'{2,}/, "").strip
      info[:original_title] = val unless val.empty?
    end

    # Extract ISBN
    if wikitext =~ /isbn\s*=\s*([\d][-\d ]+[\dXx])/i
      isbn = $1.strip.gsub(/[- ]/, "")
      info[:isbn] = isbn if isbn =~ /\A\d{10,13}\z/
    end

    unless info.empty?
      puts "  Found: #{page_title}"
      return info
    end
  end

  puts "  No relevant information found."
  nil
rescue StandardError => e
  puts "  Wikipedia search failed: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Git auto-commit
# ---------------------------------------------------------------------------

def git_auto_commit(action, book, include_covers: false)
  author = book["authors"]&.first&.dig("name") || "Unknown"
  system("git", "add", DB_PATH)
  system("git", "add", "#{COVERS_DIR}/") if include_covers
  system("git", "commit", "-m", "#{action} #{book["title"]} - #{author} book")
rescue StandardError
  # Don't fail if git is not available or repo not initialized
end
