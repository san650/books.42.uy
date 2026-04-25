#!/usr/bin/env ruby
# frozen_string_literal: true

# precommit.rb — Format db.json before commit.
# - Pretty-print JSON
# - Sort books by ID
# - Ensure IDs are sequential (reassign if gaps)
# - Validate resulting JSON

require "json"
require "tempfile"
require "fileutils"

DB_PATH = File.join(File.expand_path("..", __dir__), "public", "db.json")

def main
  unless File.exist?(DB_PATH)
    warn "db.json not found, skipping format."
    exit 0
  end

  raw = File.read(DB_PATH, encoding: "UTF-8")
  books = JSON.parse(raw)

  unless books.is_a?(Array)
    warn "db.json is not an array, skipping format."
    exit 1
  end

  # Sort by ID
  books.sort_by! { |b| b["id"].to_i }

  # Reassign sequential IDs if there are gaps or duplicates
  books.each_with_index do |book, i|
    book["id"] = i + 1
  end

  # Pretty-print with 2-space indent
  formatted = JSON.pretty_generate(books)

  # Validate the output is valid JSON
  JSON.parse(formatted)

  # Atomic write
  tmp = Tempfile.new("db", File.dirname(DB_PATH))
  tmp.write(formatted)
  tmp.write("\n")
  tmp.close
  FileUtils.mv(tmp.path, DB_PATH)

  # Re-stage db.json so the formatted version is what gets committed
  system("git", "add", DB_PATH)

  puts "precommit.rb: db.json formatted (#{books.size} books, sorted by ID)"
rescue JSON::ParserError => e
  warn "precommit.rb: db.json is not valid JSON — #{e.message}"
  exit 1
rescue StandardError => e
  warn "precommit.rb: error — #{e.message}"
  exit 1
end

main
