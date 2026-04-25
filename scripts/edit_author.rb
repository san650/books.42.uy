#!/usr/bin/env ruby
# frozen_string_literal: true

# edit_author.rb — Interactive CLI to manage authors in db.json.

require_relative "common"

trap("INT") do
  puts "\nAborted."
  exit 130
end

# ---------------------------------------------------------------------------
# Author display
# ---------------------------------------------------------------------------

def format_author_line(author, index, db)
  count = author_book_count(db, author)
  aliases = author["aliases"].empty? ? "" : " (#{author["aliases"].join(", ")})"
  books_label = count == 1 ? "1 book" : "#{count} books"
  format("%2d. %s — %s%s", index + 1, author["name"], books_label, aliases)
end

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

def edit_name(db, author)
  new_name = prompt("New name", default: author["name"], required: true)

  if new_name == author["name"]
    puts "  Name unchanged."
    return false
  end

  # Check for conflict
  conflict = db["authors"].find { |a| a["id"] != author["id"] && a["name"].downcase == new_name.downcase }
  if conflict
    puts "  Another author already has that name: #{conflict["name"]} (##{conflict["id"]})"
    puts "  Use 'Merge' instead to combine authors."
    return false
  end

  old_name = author["name"]
  author["name"] = new_name
  puts "  Renamed: #{old_name} -> #{new_name}"
  true
end

def edit_aliases(db, author)
  puts "\nCurrent aliases: #{author["aliases"].empty? ? "(none)" : author["aliases"].join(", ")}"

  items = ["Add alias", "Remove alias", "Back"]
  idx = interactive_select(items, prompt_label: "Action")
  return false unless idx

  case idx
  when 0 # Add
    new_alias = prompt("New alias", required: true)
    if author["aliases"].any? { |a| a.downcase == new_alias.downcase }
      puts "  Alias already exists."
      return false
    end
    author["aliases"] << new_alias
    puts "  Added alias: #{new_alias}"
    true
  when 1 # Remove
    if author["aliases"].empty?
      puts "  No aliases to remove."
      return false
    end
    rm_idx = interactive_select(author["aliases"], prompt_label: "Select alias to remove")
    return false unless rm_idx
    removed = author["aliases"].delete_at(rm_idx)
    puts "  Removed alias: #{removed}"
    true
  else
    false
  end
end

def merge_authors(db, source)
  others = db["authors"].reject { |a| a["id"] == source["id"] }
  if others.empty?
    puts "  No other authors to merge with."
    return false
  end

  puts "\nMerge #{source["name"]} into which author?"
  items = others.map { |a| "#{a["name"]} (#{author_book_count(db, a)} books)" }
  idx = interactive_select(items, prompt_label: "Select target author")
  return false unless idx

  target = others[idx]

  source_count = author_book_count(db, source)
  puts "\n  This will move #{source_count} book(s) from #{source["name"]} to #{target["name"]}"
  puts "  and delete #{source["name"]}."
  return false unless prompt_yes_no("  Continue?", default: "n")

  # Move all book references
  db["books"].each do |book|
    ids = book["author_ids"] || []
    if ids.include?(source["id"])
      ids.delete(source["id"])
      ids << target["id"] unless ids.include?(target["id"])
      book["author_ids"] = ids
    end
  end

  # Merge aliases
  merged_aliases = (target["aliases"] + source["aliases"] + [source["name"]]).uniq
  merged_aliases.reject! { |a| a.downcase == target["name"].downcase }
  target["aliases"] = merged_aliases

  # Remove source author
  db["authors"].delete(source)

  puts "  Merged: #{source["name"]} -> #{target["name"]}"
  true
end

def delete_author(db, author)
  count = author_book_count(db, author)
  if count > 0
    puts "\n  Cannot delete #{author["name"]} — referenced by #{count} book(s):"
    db["books"].select { |b| (b["author_ids"] || []).include?(author["id"]) }.each do |book|
      puts "    - #{book["title"]}"
    end
    puts "  Use 'Merge' to reassign books first."
    return false
  end

  return false unless prompt_yes_no("  Delete #{author["name"]}?", default: "n")

  db["authors"].delete(author)
  puts "  Deleted: #{author["name"]}"
  true
end

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Manage Authors"
  puts "=" * 50

  db = load_db
  authors = db["authors"]

  if authors.empty?
    puts "\nNo authors found. Add books first."
    exit 0
  end

  loop do
    authors = db["authors"].sort_by { |a| a["name"].unicode_normalize(:nfkd).downcase }

    puts "\n"
    items = authors.each_with_index.map { |a, i| format_author_line(a, i, db) }
    items << "Exit"

    idx = interactive_select(items, prompt_label: "Select an author")

    if idx.nil? || idx == authors.size
      puts "Done."
      break
    end

    author = authors[idx]
    puts "\nSelected: #{author["name"]}"
    puts "  Aliases: #{author["aliases"].empty? ? "(none)" : author["aliases"].join(", ")}"
    puts "  Books:   #{author_book_count(db, author)}"

    actions = ["Edit name", "Edit aliases", "Merge with another author", "Delete", "Back"]
    action_idx = interactive_select(actions, prompt_label: "Action")
    next unless action_idx

    changed = case action_idx
              when 0 then edit_name(db, author)
              when 1 then edit_aliases(db, author)
              when 2 then merge_authors(db, author)
              when 3 then delete_author(db, author)
              else false
              end

    if changed
      save_db(db)
      puts "  Changes saved."

      # Git auto-commit
      system("git", "add", DB_PATH)
      system("git", "commit", "-m", "Edit author #{author["name"]}")
    end
  end
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

begin
  main
rescue Interrupt
  puts "\n\nCancelled."
  exit 1
rescue StandardError => e
  warn "\nError: #{e.message}"
  warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
  exit 1
end
