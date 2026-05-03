# frozen_string_literal: true

require_relative "../http_client"
require_relative "../text"
require_relative "../cache/cache"
require_relative "standardize"

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

  html.scan(/<tr[^>]*>.*?<\/tr>/m).each do |row|
    next unless row.include?("bookTitle") || row.include?("/book/show/")

    title = nil
    author = nil
    book_url = nil

    if row =~ /<a[^>]+class="bookTitle"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/m
      book_url = $1
      title = decode_html(strip_tags($2)).strip
    elsif row =~ /<a[^>]+href="(\/book\/show\/[^"]+)"[^>]*>(.*?)<\/a>/m
      book_url = $1
      title = decode_html(strip_tags($2)).strip
    end

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

  raw_title = book_obj["titleComplete"] || book_obj["title"] || ""
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

  detail[:cover_url] = book_obj["imageUrl"] if book_obj["imageUrl"]

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

  unless detail[:saga_name]
    series_list = book_obj["bookSeries"] || []
    series_list.each do |series_entry|
      series_ref = series_entry.dig("series", "__ref")
      series_obj = series_ref ? apollo[series_ref] : series_entry["series"]
      if series_obj && series_obj["title"]
        name = decode_html(strip_tags(series_obj["title"])).strip
        next if name =~ /[<>"]/ || name.length > 200
        detail[:saga_name] = name
        detail[:saga_order] = (series_entry["userPosition"] || "1").to_i
        detail[:saga_order] = 1 if detail[:saga_order] < 1
        break
      end
    end
  end

  if work_obj
    orig = work_obj.dig("details", "originalTitle")
    if orig.nil?
      details_ref = work_obj.dig("details", "__ref")
      if details_ref
        work_details = apollo[details_ref]
        orig = work_details["originalTitle"] if work_details.is_a?(Hash)
      end
    end
    detail[:original_title] = orig.strip if orig && !orig.strip.empty?
  end

  if work_obj
    pub_time = work_obj.dig("details", "publicationTime")
    if pub_time
      detail[:first_publishing_date] = Time.at(pub_time / 1000).year.to_s
    end
  end

  if detail[:first_publishing_date].nil? || detail[:first_publishing_date].to_s.empty?
    first_pub_match = html.match(/First published.*?(\d{4})/)
    detail[:first_publishing_date] = first_pub_match[1] if first_pub_match
  end

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

  if html =~ /First published.*?(\d{4})/i
    detail[:first_publishing_date] = $1
  elsif html =~ /Published.*?(\d{4})/i
    detail[:first_publishing_date] = $1
  end

  if html =~ /Original Title\s*<\/dt>\s*<dd[^>]*>(.*?)<\/dd>/mi
    detail[:original_title] = decode_html(strip_tags($1)).strip
  elsif html =~ /Original Title.*?<[^>]+>\s*([^<]+)/mi
    val = decode_html($1).strip
    detail[:original_title] = val unless val.empty?
  end

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
  if detail[:isbn] && detail[:isbn].length == 13 && detail[:isbn] !~ /\A97[89]/
    detail[:isbn] = nil
  end

  if html =~ /Publisher\s*<\/dt>\s*<dd[^>]*>(.*?)<\/dd>/mi
    detail[:publisher] = decode_html(strip_tags($1)).strip
  elsif html =~ /Publisher.*?<[^>]+>\s*([^<]+)/mi
    val = decode_html($1).strip
    detail[:publisher] = val unless val.empty? || val.length > 100
  end

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
