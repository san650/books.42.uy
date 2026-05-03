# frozen_string_literal: true

require_relative "../http_client"
require_relative "../cache/cache"
require_relative "standardize"

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
