# frozen_string_literal: true

require_relative "constants"
require_relative "authors"

def git_auto_commit(action, book, db, include_covers: false)
  names = resolve_author_names(db, book)
  author = names.first || "Unknown"
  system("git", "add", DB_PATH)
  system("git", "add", "#{COVERS_DIR}/") if include_covers
  system("git", "commit", "-m", "#{action} #{book["title"]} - #{author} book")
rescue StandardError
  # Ignore — git may be unavailable.
end

def git_commit_paths(paths, message)
  Array(paths).each { |path| system("git", "add", path) }
  system("git", "commit", "-m", message)
rescue StandardError
  # Ignore — git may be unavailable.
end
