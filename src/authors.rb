# frozen_string_literal: true

require_relative "db"

# Find an author by canonical name OR by any of their aliases. Case-
# insensitive. Returns the author hash or nil.
def find_author_by_name(db, name)
  return nil if name.nil? || name.to_s.empty?

  needle = name.to_s.downcase
  db["authors"].find do |a|
    next true if a["name"].to_s.downcase == needle

    (a["aliases"] || []).any? { |al| al.to_s.downcase == needle }
  end
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
