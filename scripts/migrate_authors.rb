#!/usr/bin/env ruby
# frozen_string_literal: true

# migrate_authors.rb — One-time migration to separate authors from books in db.json.
#
# Before: db.json is a flat array of books, each with embedded "authors" array.
# After:  db.json is { "authors": [...], "books": [...] } with books referencing author_ids.

require "json"
require "tempfile"
require "fileutils"

DB_PATH = File.join(File.expand_path("..", __dir__), "docs", "db.json")

abort "db.json not found at #{DB_PATH}" unless File.exist?(DB_PATH)

raw = File.read(DB_PATH, encoding: "UTF-8")
data = JSON.parse(raw)

unless data.is_a?(Array)
  abort "db.json is already migrated (not a flat array). Nothing to do."
end

# --- Collect unique authors ---
author_map = {} # name (downcased) -> { "id" => N, "name" => canonical, "aliases" => [...] }
next_author_id = 1

data.each do |book|
  (book["authors"] || []).each do |a|
    key = a["name"].downcase
    if author_map[key]
      # Merge aliases
      existing_aliases = author_map[key]["aliases"]
      new_aliases = (a["aliases"] || []) - existing_aliases
      author_map[key]["aliases"].concat(new_aliases)
    else
      author_map[key] = {
        "id" => next_author_id,
        "name" => a["name"],
        "aliases" => (a["aliases"] || []).dup
      }
      next_author_id += 1
    end
  end
end

authors = author_map.values.sort_by { |a| a["name"].unicode_normalize(:nfkd).downcase }

# Reassign sequential IDs after sorting
authors.each_with_index { |a, i| a["id"] = i + 1 }

# Rebuild lookup by name for ID resolution
name_to_id = {}
authors.each { |a| name_to_id[a["name"].downcase] = a["id"] }

# --- Transform books ---
books = data.map do |book|
  author_ids = (book["authors"] || []).map { |a| name_to_id[a["name"].downcase] }.compact
  book.delete("authors")
  book["author_ids"] = author_ids
  book
end

# Sort books by title
books.sort_by! { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }

# --- Build new structure ---
db = { "authors" => authors, "books" => books }

# --- Write atomically ---
json = JSON.pretty_generate(db, indent: "  ")
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

# --- Report ---
puts "Migration complete!"
puts "  #{authors.size} authors extracted"
puts "  #{books.size} books updated with author_ids"
puts ""
puts "Authors:"
authors.each do |a|
  book_count = books.count { |b| (b["author_ids"] || []).include?(a["id"]) }
  aliases = a["aliases"].empty? ? "" : " (aliases: #{a["aliases"].join(", ")})"
  puts "  ##{a["id"]} #{a["name"]} — #{book_count} book(s)#{aliases}"
end
