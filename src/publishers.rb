# frozen_string_literal: true

require "json"
require_relative "constants"

# Publishers live alongside authors and books inside docs/db.json under the
# "publishers" top-level key. There are two access patterns:
#
#   * Reads (load_publishers, sanitize_publisher) — happen during lookup,
#     before the orchestrator has loaded a db. They read db.json directly.
#   * Writes (add_publisher) — happen during pick_publisher, when the
#     orchestrator already has an in-memory db. They mutate that db only;
#     persistence is the orchestrator's save_db at the end of the flow.

# Returns the sorted publishers list. When `db` is given (the orchestrator's
# in-memory copy) we read from it; otherwise we parse db.json from disk.
def load_publishers(db = nil)
  arr = if db
          Array(db["publishers"])
        else
          publishers_from_disk
        end
  arr.sort_by { |p| p.to_s.unicode_normalize(:nfkd).downcase }
end

# Add a publisher to the in-memory db. No-op if it already exists
# (case-insensitive match). Persistence is handled by save_db.
def add_publisher(db, name)
  return if name.nil? || name.to_s.strip.empty?

  db["publishers"] ||= []
  return if db["publishers"].any? { |p| p.casecmp(name).zero? }

  db["publishers"] << name
end

# Match against publishers.txt-equivalent (now the publishers entry in
# db.json) case-insensitively; return the canonical spelling if found,
# otherwise return the input as-is.
def sanitize_publisher(name)
  return name if name.nil? || name.to_s.strip.empty?

  match = load_publishers.find { |p| p.casecmp(name.to_s.strip).zero? }
  match || name.to_s.strip
end

private

def publishers_from_disk
  return [] unless File.exist?(DB_PATH)

  data = JSON.parse(File.read(DB_PATH, encoding: "UTF-8"))
  arr = data["publishers"]
  arr.is_a?(Array) ? arr : []
rescue JSON::ParserError
  []
end
