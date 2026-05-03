# frozen_string_literal: true

require_relative "../http_client"
require_relative "../text"
require_relative "../cache/cache"
require_relative "standardize"

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
