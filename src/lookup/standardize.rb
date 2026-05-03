# frozen_string_literal: true

require_relative "../publishers"
require_relative "../text"

# Normalize a raw ISBN string. Returns nil if it does not parse as ISBN-10
# or ISBN-13.
def normalize_isbn(raw)
  cleaned = raw.to_s.gsub(/[\s\-]/, "")
  return nil unless cleaned =~ /\A(\d{9}[\dXx]|\d{13})\z/

  cleaned.upcase
end

def isbn_matches?(candidate, isbn)
  return false unless candidate

  candidate.gsub(/[\s\-]/, "").upcase == isbn
end

def build_identifiers(isbn_13, isbn_10)
  identifiers = []
  identifiers << { "type" => "ISBN_13", "value" => isbn_13 } if isbn_13 && !isbn_13.to_s.empty?
  identifiers << { "type" => "ISBN_10", "value" => isbn_10 } if isbn_10 && !isbn_10.to_s.empty?
  identifiers
end

# Build a record in the canonical Lev shape from per-source data. Empty/nil
# fields are dropped so the merge step in book_form sees clean inputs.
def standardize(title:, subtitle: nil, original_title: nil, authors: [], publisher: nil,
                publish_date: nil, first_publishing_date: nil, isbn_13: nil, isbn_10: nil,
                identifiers: nil, cover_url: nil, url: nil, language: nil, saga: nil)
  ids = identifiers || build_identifiers(isbn_13, isbn_10)
  # Lev only stores the year. Both first_publishing_date and the per-source
  # publish_date may be free-form strings — pull a 4-digit year out of them
  # and keep only that.
  first_pub_year = extract_year(first_publishing_date) || extract_year(publish_date)
  {
    "title" => title,
    "subtitle" => subtitle.to_s.empty? ? nil : subtitle,
    "original_title" => original_title.to_s.empty? ? nil : original_title,
    "authors" => Array(authors).compact,
    "publisher" => sanitize_publisher(publisher),
    "first_publishing_date" => first_pub_year,
    "identifiers" => ids,
    "cover_url" => cover_url,
    "url" => url,
    "language" => language,
    "saga" => saga
  }.compact
end
