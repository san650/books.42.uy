# frozen_string_literal: true

require_relative "db"

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
