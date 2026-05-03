# frozen_string_literal: true

# Text helpers: HTML decoding, tag stripping, slug generation.

# Decode HTML entities (minimal, stdlib-only).
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

# Strip HTML tags.
def strip_tags(str)
  return "" unless str

  str.gsub(/<[^>]+>/, "")
end

# Pull a 4-digit year out of a free-form date string. Returns the year as a
# String, or nil if no plausible year is found. Picks the first standalone
# 4-digit run — "2011-04-12" → "2011", "April 1946" → "1946", "1990s" →
# "1990", "12345" → nil.
def extract_year(value)
  return nil if value.nil?

  m = value.to_s.match(/(?<!\d)(\d{4})(?!\d)/)
  m ? m[1] : nil
end

# Convert a book title to a URL/file-friendly slug:
#   1. lowercase
#   2. remove diacritics
#   3. replace whitespace with "-"
#   4. replace any other non-ASCII character with "_"
# Trailing/leading and repeated separators are collapsed.
def sanitize_title(title)
  s = title.to_s.unicode_normalize(:nfkd)
  s = s.gsub(/\p{M}+/, "")
  s = s.downcase
  s = s.gsub(/\s+/, "-")
  s = s.gsub(/[^[:ascii:]]/, "_")
  s = s.gsub(/[^a-z0-9\-_]/, "_")
  s = s.gsub(/-{2,}/, "-").gsub(/_{2,}/, "_")
  s.gsub(/\A[\-_]+|[\-_]+\z/, "")
end
