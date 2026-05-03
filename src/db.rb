# frozen_string_literal: true

require "json"
require "tempfile"
require "fileutils"
require_relative "constants"

def load_db
  empty = { "authors" => [], "books" => [], "publishers" => [] }
  return empty unless File.exist?(DB_PATH)

  data = File.read(DB_PATH, encoding: "UTF-8")
  return empty if data.strip.empty?

  parsed = JSON.parse(data)

  if parsed.is_a?(Hash) && parsed.key?("authors") && parsed.key?("books")
    parsed["publishers"] ||= []
    parsed
  elsif parsed.is_a?(Array)
    { "authors" => [], "books" => parsed, "publishers" => [] }
  else
    empty
  end
rescue JSON::ParserError => e
  warn "Warning: could not parse db.json (#{e.message})."
  empty
end

def save_db(db)
  db["authors"].sort_by! { |a| (a["name"] || "").unicode_normalize(:nfkd).downcase }
  db["books"].sort_by! { |b| (b["title"] || "").unicode_normalize(:nfkd).downcase }
  db["publishers"] ||= []
  db["publishers"].sort_by! { |p| p.to_s.unicode_normalize(:nfkd).downcase }

  ordered = {
    "authors" => db["authors"],
    "books" => db["books"],
    "publishers" => db["publishers"]
  }

  json = JSON.pretty_generate(ordered, indent: "  ")

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
