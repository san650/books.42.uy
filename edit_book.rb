#!/usr/bin/env ruby
# frozen_string_literal: true

# edit_book.rb — Interactive CLI to edit book metadata by refetching from Goodreads.
# Self-contained, no gem dependencies beyond stdlib.

require "json"
require "net/http"
require "uri"
require "tempfile"
require "fileutils"
require "cgi"

DB_PATH = File.join(__dir__, "db.json")
COVERS_DIR = File.join(__dir__, "covers")
HTTP_TIMEOUT = 10 # seconds
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

trap("INT") do
  puts "\nAborted."
  exit 130
end

# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def load_books
  unless File.exist?(DB_PATH)
    $stderr.puts "db.json not found. Run add_book.rb first."
    exit 1
  end

  raw = File.read(DB_PATH)
  books = JSON.parse(raw)

  unless books.is_a?(Array)
    $stderr.puts "db.json is malformed (expected an array)."
    exit 1
  end

  books
end

def save_books(books)
  sorted = books.sort_by { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }

  json = JSON.pretty_generate(sorted, indent: "  ")

  tmpfile = Tempfile.new(["db", ".json"], File.dirname(DB_PATH))
  begin
    tmpfile.write(json)
    tmpfile.write("\n")
    tmpfile.flush
    tmpfile.close
    FileUtils.mv(tmpfile.path, DB_PATH)
  rescue StandardError
    tmpfile.close
    tmpfile.unlink
    raise
  end
end

def sanitize_title(title)
  title
    .downcase
    .gsub(/[^a-z0-9]/, "-")
    .gsub(/-{2,}/, "-")
    .gsub(/\A-|-\z/, "")
end

# ---------------------------------------------------------------------------
# Display & selection (matches add_review.rb pattern)
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
    label = parts.join(" -- ")

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
    if num >= 1 && num <= books.length
      return num - 1
    end

    puts "Invalid selection. Please enter a number between 1 and #{books.length}."
  end
end

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http_get(url, headers: {}, follow_redirects: 5)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = HTTP_TIMEOUT
  http.read_timeout = HTTP_TIMEOUT

  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = USER_AGENT
  request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  headers.each { |k, v| request[k] = v }

  response = http.request(request)
  response.body&.force_encoding("UTF-8") if response.body

  # Follow redirects
  if follow_redirects > 0 && %w[301 302 303 307 308].include?(response.code)
    location = response["location"]
    if location
      location = URI.join(uri, location).to_s unless location.start_with?("http")
      return http_get(location, headers: headers, follow_redirects: follow_redirects - 1)
    end
  end

  response
rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
       Errno::ECONNRESET, SocketError, OpenSSL::SSL::SSLError => e
  warn "  Network error: #{e.message}"
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
  encoded = URI.encode_www_form_component(query)
  url = "https://www.goodreads.com/search?utf8=%E2%9C%93&q=#{encoded}&search_type=books"
  puts "\nSearching Goodreads for: #{query}"

  response = http_get(url)
  unless response&.code == "200"
    puts "  Goodreads search unavailable."
    return []
  end

  html = response.body
  results = []

  # Parse search results table rows
  # Each result has a link like /book/show/12345.Title and author info
  html.scan(/<tr itemscope.*?<\/tr>/m).each do |row|
    result = {}

    # Extract book URL and title
    if row =~ %r{<a class="bookTitle"[^>]*href="(/book/show/[^"]+)"[^>]*>\s*<span[^>]*>([^<]+)</span>}m
      result[:url] = "https://www.goodreads.com#{$1}"
      result[:title] = CGI.unescapeHTML($1.to_s) # fallback
      result[:title] = CGI.unescapeHTML($2.strip)
    else
      next
    end

    # Extract author
    if row =~ %r{<a class="authorName"[^>]*>\s*<span[^>]*>([^<]+)</span>}m
      result[:author] = CGI.unescapeHTML($1.strip)
    end

    # Extract year
    if row =~ /published\s+(\d{4})/
      result[:year] = $1
    end

    # Extract series info from title area
    if row =~ /\(([^)]+#[\d.]+)\)/
      result[:series_hint] = $1.strip
    end

    results << result
    break if results.size >= 10
  end

  results
end

def display_goodreads_results(results)
  return if results.empty?

  puts "\nGoodreads results:"
  results.each_with_index do |r, i|
    series = r[:series_hint] ? " (#{r[:series_hint]})" : ""
    year = r[:year] ? " (#{r[:year]})" : ""
    printf "  %2d. %s -- %s%s%s\n", i + 1, r[:title], r[:author] || "?", year, series
  end
  puts "   0. Skip refetch / edit manually"
end

# ---------------------------------------------------------------------------
# Goodreads detail page scraping
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

  data = {}

  # --- Title ---
  raw_title = book_obj["titleComplete"] || book_obj["title"] || ""
  data[:title] = raw_title.strip

  # --- Cover image ---
  data[:cover_url] = book_obj["imageUrl"] if book_obj["imageUrl"]

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
  data[:authors] = authors unless authors.empty?

  # --- Series/Saga ---
  series_list = book_obj["bookSeries"] || []
  series_list.each do |series_entry|
    series_ref = series_entry.dig("series", "__ref")
    series_obj = series_ref ? apollo[series_ref] : series_entry["series"]
    if series_obj && series_obj["title"]
      data[:saga_name] = series_obj["title"].strip
      data[:saga_order] = (series_entry["userPosition"] || "1").strip
      data[:saga_order] = "1" if data[:saga_order].empty?
      break
    end
  end

  # --- Original title from Work ---
  if work_obj
    orig = work_obj.dig("details", "originalTitle")
    data[:original_title] = orig.strip if orig && !orig.strip.empty?
  end

  # --- Publication year from Work timestamp ---
  if work_obj
    pub_time = work_obj.dig("details", "publicationTime")
    if pub_time
      data[:first_publishing_date] = Time.at(pub_time / 1000).year.to_s
    end
  end

  # Fallback: "First published" text in HTML for the year
  if data[:first_publishing_date].nil? || data[:first_publishing_date].to_s.empty?
    first_pub_match = html.match(/First published.*?(\d{4})/)
    data[:first_publishing_date] = first_pub_match[1] if first_pub_match
  end

  # --- ISBN from JSON-LD ---
  begin
    ld_match = html.match(/<script type="application\/ld\+json">(.*?)<\/script>/m)
    if ld_match
      ld_json = JSON.parse(ld_match[1])
      isbn_val = ld_json["isbn"]
      data[:isbn] = isbn_val if isbn_val && !isbn_val.to_s.empty?
    end
  rescue JSON::ParserError
    # ignore malformed JSON-LD
  end

  data
rescue JSON::ParserError => e
  puts "  __NEXT_DATA__ JSON parse error: #{e.message}"
  nil
end

def scrape_goodreads_detail_from_html(html)
  data = {}

  # Title
  if html =~ /<h1[^>]*class="[^"]*Text__title1[^"]*"[^>]*>([^<]+)</m
    data[:title] = CGI.unescapeHTML($1.strip)
  elsif html =~ /<h1[^>]*data-testid="bookTitle"[^>]*>([^<]+)</m
    data[:title] = CGI.unescapeHTML($1.strip)
  end

  # Series/saga
  if html =~ %r{<h3[^>]*class="[^"]*Text__title3[^"]*"[^>]*>.*?<a[^>]*href="/series/[^"]*"[^>]*>([^<]+)</a>\s*#([\d.]+)}m
    data[:saga_name] = CGI.unescapeHTML($1.strip)
    data[:saga_order] = $2.strip
  elsif html =~ /\(([^()]+?)\s*#(\d+(?:\.\d+)?)\)/
    candidate = $1.strip
    unless candidate =~ /^\d{4}$/ || candidate =~ /pages?/i
      data[:saga_name] = CGI.unescapeHTML(candidate)
      data[:saga_order] = $2.strip
    end
  end

  # Authors
  authors = []
  html.scan(%r{<a class="ContributorLink"[^>]*>.*?<span[^>]*class="[^"]*ContributorLink__name[^"]*"[^>]*>([^<]+)</span>}m).each do |match|
    name = CGI.unescapeHTML(match[0].strip)
    authors << name unless authors.include?(name)
  end
  if authors.empty?
    html.scan(%r{<a class="authorName"[^>]*>\s*<span[^>]*>([^<]+)</span>}m).each do |match|
      name = CGI.unescapeHTML(match[0].strip)
      authors << name unless authors.include?(name)
    end
  end
  data[:authors] = authors unless authors.empty?

  # Original title
  if html =~ /Original Title\s*<\/dt>\s*<dd[^>]*>\s*([^<]+)/m
    data[:original_title] = CGI.unescapeHTML($1.strip)
  elsif html =~ /Original Title.*?<[^>]+>([^<]+)</m
    val = CGI.unescapeHTML($1.strip)
    data[:original_title] = val unless val.empty?
  end

  # ISBN
  if html =~ /ISBN13[:\s]*<\/dt>\s*<dd[^>]*>\s*([\d-]+)/m
    data[:isbn] = $1.gsub("-", "").strip
  elsif html =~ /ISBN[:\s]*<\/dt>\s*<dd[^>]*>\s*([\d-]+)/m
    data[:isbn] = $1.gsub("-", "").strip
  elsif html =~ /ISBN\s*<\/dt>\s*<dd[^>]*class="[^"]*TruncatedContent[^"]*"[^>]*>\s*([\d\s-]+)/m
    data[:isbn] = $1.gsub(/[\s-]/, "").strip
  end
  if data[:isbn].nil? || data[:isbn].empty?
    if html =~ /"isbn"\s*:\s*"(\d+)"/
      data[:isbn] = $1
    end
  end

  # Publisher
  if html =~ /Publisher[:\s]*<\/dt>\s*<dd[^>]*>\s*([^<]+)/m
    data[:publisher] = CGI.unescapeHTML($1.strip)
  elsif html =~ /Published.*?by\s+([^<\n]+)/m
    data[:publisher] = CGI.unescapeHTML($1.strip)
  end

  # Publication date (year only)
  if html =~ /First published.*?(\d{4})/m
    data[:first_publishing_date] = $1
  elsif html =~ /Published.*?(\d{4})/m
    data[:first_publishing_date] = $1
  end

  # Cover image URL
  if html =~ %r{<img[^>]*class="[^"]*ResponsiveImage[^"]*"[^>]*src="(https://[^"]+)"[^>]*/?>}m
    data[:cover_url] = $1
  elsif html =~ %r{<img[^>]*id="coverImage"[^>]*src="(https://[^"]+)"}m
    data[:cover_url] = $1
  elsif html =~ %r{"image"\s*:\s*"(https://images[^"]+)"}m
    data[:cover_url] = $1
  end

  data
end

def scrape_goodreads_detail(url)
  puts "\nFetching Goodreads book page..."
  response = http_get(url)
  unless response&.code == "200"
    puts "  Could not load Goodreads page."
    return nil
  end

  html = response.body

  # Try structured __NEXT_DATA__ JSON first (more reliable)
  begin
    data = scrape_goodreads_detail_from_next_data(html)
    if data && data[:title] && !data[:title].empty?
      puts "  Parsed book data from structured JSON."
      return data
    end
  rescue StandardError => e
    puts "  __NEXT_DATA__ extraction failed (#{e.message}), falling back to HTML scraping..."
  end

  # Fall back to HTML scraping
  data = scrape_goodreads_detail_from_html(html)
  return data unless data.empty?

  nil
rescue StandardError => e
  puts "  Scraping error: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Field-by-field comparison
# ---------------------------------------------------------------------------

def prompt_field(field_name, current, fetched)
  current_str = current.to_s
  fetched_str = fetched.to_s

  # If fetched is empty or same as current, keep current silently
  if fetched_str.empty? || fetched_str == current_str
    return current
  end

  puts ""
  puts "#{field_name}:"
  puts "  Current: #{current_str.empty? ? "(empty)" : "\"#{current_str}\""}"
  puts "  Fetched: \"#{fetched_str}\""
  print "  [K]eep current / [U]se fetched / [C]ustom value? [K]: "

  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  choice = input.strip.downcase

  case choice
  when "u"
    fetched_str
  when "c"
    print "  Enter value: "
    custom = $stdin.gets
    if custom.nil?
      puts ""
      exit 130
    end
    custom.strip
  else
    current_str
  end
end

def prompt_field_authors(current_authors, fetched_authors)
  return current_authors if fetched_authors.nil? || fetched_authors.empty?

  current_names = (current_authors || []).map { |a| a["name"] }.join(", ")
  fetched_names = fetched_authors.join(", ")

  return current_authors if fetched_names == current_names

  puts ""
  puts "Authors:"
  puts "  Current: #{current_names.empty? ? "(empty)" : "\"#{current_names}\""}"
  puts "  Fetched: \"#{fetched_names}\""
  print "  [K]eep current / [U]se fetched / [C]ustom value? [K]: "

  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  choice = input.strip.downcase

  case choice
  when "u"
    fetched_authors.map { |name| { "name" => name, "aliases" => [] } }
  when "c"
    print "  Enter authors (comma-separated): "
    custom = $stdin.gets
    if custom.nil?
      puts ""
      exit 130
    end
    custom.strip.split(",").map(&:strip).reject(&:empty?).map do |name|
      # Preserve existing aliases if the author name matches
      existing = (current_authors || []).find { |a| a["name"] == name }
      existing || { "name" => name, "aliases" => [] }
    end
  else
    current_authors
  end
end

def prompt_field_identifiers(current_ids, fetched_isbn)
  return current_ids if fetched_isbn.nil? || fetched_isbn.empty?

  current_isbn = (current_ids || []).find { |id| id["type"] == "ISBN" }
  current_isbn_val = current_isbn ? current_isbn["value"] : ""

  return current_ids if fetched_isbn == current_isbn_val

  puts ""
  puts "ISBN:"
  puts "  Current: #{current_isbn_val.empty? ? "(empty)" : "\"#{current_isbn_val}\""}"
  puts "  Fetched: \"#{fetched_isbn}\""
  print "  [K]eep current / [U]se fetched / [C]ustom value? [K]: "

  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  choice = input.strip.downcase

  new_isbn = case choice
             when "u"
               fetched_isbn
             when "c"
               print "  Enter ISBN: "
               custom = $stdin.gets
               if custom.nil?
                 puts ""
                 exit 130
               end
               custom.strip
             else
               current_isbn_val
             end

  # Rebuild identifiers array with updated ISBN
  other_ids = (current_ids || []).reject { |id| id["type"] == "ISBN" }
  if new_isbn && !new_isbn.empty?
    other_ids << { "type" => "ISBN", "value" => new_isbn }
  end
  other_ids
end

def prompt_field_saga(current_saga, fetched_saga_name, fetched_saga_order)
  fetched_name = fetched_saga_name.to_s
  fetched_order = fetched_saga_order.to_s

  current_name = current_saga ? current_saga["name"].to_s : ""
  current_order = current_saga ? current_saga["order"].to_s : ""

  # If no fetched data and no current data, skip
  return current_saga if fetched_name.empty? && current_name.empty?

  # If same, skip
  if fetched_name == current_name && fetched_order == current_order
    return current_saga
  end

  # If fetched is empty but current exists, still show option
  current_display = current_saga ? "\"#{current_name} ##{current_order}\"" : "(none)"
  fetched_display = fetched_name.empty? ? "(none)" : "\"#{fetched_name} ##{fetched_order}\""

  puts ""
  puts "Saga:"
  puts "  Current: #{current_display}"
  puts "  Fetched: #{fetched_display}"
  print "  [K]eep current / [U]se fetched / [C]ustom value? [K]: "

  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  choice = input.strip.downcase

  case choice
  when "u"
    if fetched_name.empty?
      nil
    else
      order = fetched_order.to_i
      order = 1 if order < 1
      { "name" => fetched_name, "order" => order }
    end
  when "c"
    print "  Saga name (blank to remove): "
    name_input = $stdin.gets
    if name_input.nil?
      puts ""
      exit 130
    end
    name_input = name_input.strip
    return nil if name_input.empty?

    print "  Order in saga: "
    order_input = $stdin.gets
    if order_input.nil?
      puts ""
      exit 130
    end
    order = order_input.strip.to_i
    order = 1 if order < 1
    { "name" => name_input, "order" => order }
  else
    current_saga
  end
end

# ---------------------------------------------------------------------------
# Cover handling
# ---------------------------------------------------------------------------

def prompt_cover_update(book, fetched_cover_url)
  return unless fetched_cover_url && !fetched_cover_url.empty?

  puts ""
  print "Cover: Download new cover from Goodreads? [y/N]: "
  input = $stdin.gets
  if input.nil?
    puts ""
    exit 130
  end
  return unless input.strip.downcase == "y"

  FileUtils.mkdir_p(COVERS_DIR)
  book_id = book["id"]
  title = book["title"]
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  puts "  Downloading cover..."
  if http_download(fetched_cover_url, dest)
    # Remove old covers for this book (different filenames)
    old_covers = (book["covers"] || []).map { |c| c["file"] }
    old_covers.each do |old_file|
      old_path = File.join(__dir__, old_file)
      if File.exist?(old_path) && old_path != dest
        File.delete(old_path)
        puts "  Removed old cover: #{old_file}"
      end
    end

    book["covers"] = [{ "file" => "covers/#{filename}", "default" => true }]
    puts "  Cover saved: covers/#{filename}"
  else
    puts "  Failed to download cover."
  end
end

# ---------------------------------------------------------------------------
# Score prompt (matches add_review.rb)
# ---------------------------------------------------------------------------

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
# Main flow
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev -- Edit Book Metadata"
  puts "=" * 50

  books = load_books

  if books.empty?
    puts "No books found. Run add_book.rb first."
    exit 0
  end

  # Step 1: Display and select book
  display_book_list(books)
  index = prompt_selection(books)
  book = books[index]

  puts ""
  puts "Selected: #{book["title"]}"

  # Step 2: Build Goodreads search query
  fetched = nil
  begin
    # Determine search strategy
    isbn = (book["identifiers"] || []).find { |id| id["type"] == "ISBN" }&.dig("value")
    first_author = book.dig("authors", 0, "name")

    search_query = if isbn && !isbn.empty?
                     isbn
                   elsif first_author
                     "#{book["title"]} #{first_author}"
                   else
                     book["title"]
                   end

    results = goodreads_search(search_query)

    if results.any?
      display_goodreads_results(results)
      print "\nSelect a result (1-#{results.size}, or 0 to skip): "
      input = $stdin.gets
      if input.nil?
        puts ""
        exit 130
      end
      choice = input.strip.to_i

      if choice >= 1 && choice <= results.size
        fetched = scrape_goodreads_detail(results[choice - 1][:url])
      else
        puts "Skipping refetch. You can edit fields manually."
      end
    else
      puts "  No results found."
    end
  rescue StandardError => e
    puts "  Goodreads lookup failed: #{e.message}"
    puts "  You can still edit fields manually."
  end

  fetched ||= {}

  # Step 3: Field-by-field comparison
  puts "\n" + "-" * 50
  puts "  Edit Fields"
  puts "-" * 50

  book["title"] = prompt_field("Title", book["title"], fetched[:title])
  book["subtitle"] = prompt_field("Subtitle", book["subtitle"], fetched[:subtitle])
  book["original_title"] = prompt_field("Original title", book["original_title"], fetched[:original_title])
  book["first_publishing_date"] = prompt_field("First publishing date", book["first_publishing_date"], fetched[:first_publishing_date])
  book["publisher"] = prompt_field("Publisher", book["publisher"], fetched[:publisher])
  book["identifiers"] = prompt_field_identifiers(book["identifiers"], fetched[:isbn])
  book["authors"] = prompt_field_authors(book["authors"], fetched[:authors])
  book["saga"] = prompt_field_saga(book["saga"], fetched[:saga_name], fetched[:saga_order])

  # Step 4: Cover
  prompt_cover_update(book, fetched[:cover_url])

  # Step 5: Score
  puts ""
  new_score = prompt_score(book["score"])
  book["score"] = new_score if new_score

  # Step 6: Save
  save_books(books)

  puts ""
  puts "Book updated: \"#{book["title"]}\""

  # Step 7: Git auto-commit
  author = book["authors"]&.first&.dig("name") || "Unknown"
  system("git", "add", "db.json", "covers/")
  system("git", "commit", "-m", "Edit #{book["title"]} - #{author} book")
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
