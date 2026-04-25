#!/usr/bin/env ruby
# frozen_string_literal: true

# edit_book.rb — Interactive CLI to edit book metadata by refetching from Goodreads.

require_relative "common"

trap("INT") do
  puts "\nAborted."
  exit 130
end

# ---------------------------------------------------------------------------
# Field-by-field comparison
# ---------------------------------------------------------------------------

def prompt_field(field_name, current, fetched)
  current_str = current.to_s
  fetched_str = fetched.to_s

  # If fetched is empty or same as current, keep current silently
  if fetched_str.empty? || fetched_str == current_str
    return current
  end

  puts ""
  puts "#{field_name}:"
  puts "  Current: #{current_str.empty? ? "(empty)" : "\"#{current_str}\""}"
  puts "  Fetched: \"#{fetched_str}\""

  choice = Readline.readline("  [K]eep current / [U]se fetched / [C]ustom value? [K]: ", false)
  abort "\nCancelled." unless choice
  choice = choice.strip.downcase

  case choice
  when "u"
    fetched_str
  when "c"
    custom = Readline.readline("  Enter value: ", false)
    abort "\nCancelled." unless custom
    custom.strip
  else
    current_str
  end
end

def prompt_field_authors(current_authors, fetched_authors)
  return current_authors if fetched_authors.nil? || fetched_authors.empty?

  current_names = (current_authors || []).map { |a| a["name"] }.join(", ")
  fetched_names = fetched_authors.join(", ")

  return current_authors if fetched_names == current_names

  puts ""
  puts "Authors:"
  puts "  Current: #{current_names.empty? ? "(empty)" : "\"#{current_names}\""}"
  puts "  Fetched: \"#{fetched_names}\""

  choice = Readline.readline("  [K]eep current / [U]se fetched / [C]ustom value? [K]: ", false)
  abort "\nCancelled." unless choice
  choice = choice.strip.downcase

  case choice
  when "u"
    fetched_authors.map { |name| { "name" => name, "aliases" => [] } }
  when "c"
    custom = Readline.readline("  Enter authors (comma-separated): ", false)
    abort "\nCancelled." unless custom
    custom.strip.split(",").map(&:strip).reject(&:empty?).map do |name|
      # Preserve existing aliases if the author name matches
      existing = (current_authors || []).find { |a| a["name"] == name }
      existing || { "name" => name, "aliases" => [] }
    end
  else
    current_authors
  end
end

def prompt_field_identifiers(current_ids, fetched_isbn)
  return current_ids if fetched_isbn.nil? || fetched_isbn.empty?

  current_isbn = (current_ids || []).find { |id| id["type"] == "ISBN" }
  current_isbn_val = current_isbn ? current_isbn["value"] : ""

  return current_ids if fetched_isbn == current_isbn_val

  puts ""
  puts "ISBN:"
  puts "  Current: #{current_isbn_val.empty? ? "(empty)" : "\"#{current_isbn_val}\""}"
  puts "  Fetched: \"#{fetched_isbn}\""

  choice = Readline.readline("  [K]eep current / [U]se fetched / [C]ustom value? [K]: ", false)
  abort "\nCancelled." unless choice
  choice = choice.strip.downcase

  new_isbn = case choice
             when "u"
               fetched_isbn
             when "c"
               custom = Readline.readline("  Enter ISBN: ", false)
               abort "\nCancelled." unless custom
               custom.strip
             else
               current_isbn_val
             end

  # Rebuild identifiers array with updated ISBN
  other_ids = (current_ids || []).reject { |id| id["type"] == "ISBN" }
  if new_isbn && !new_isbn.empty?
    other_ids << { "type" => "ISBN", "value" => new_isbn }
  end
  other_ids
end

def prompt_field_saga(current_saga, fetched_saga_name, fetched_saga_order)
  fetched_name = fetched_saga_name.to_s
  fetched_order = fetched_saga_order.to_s

  current_name = current_saga ? current_saga["name"].to_s : ""
  current_order = current_saga ? current_saga["order"].to_s : ""

  # If no fetched data and no current data, skip
  return current_saga if fetched_name.empty? && current_name.empty?

  # If same, skip
  if fetched_name == current_name && fetched_order == current_order
    return current_saga
  end

  # If fetched is empty but current exists, still show option
  current_display = current_saga ? "\"#{current_name} ##{current_order}\"" : "(none)"
  fetched_display = fetched_name.empty? ? "(none)" : "\"#{fetched_name} ##{fetched_order}\""

  puts ""
  puts "Saga:"
  puts "  Current: #{current_display}"
  puts "  Fetched: #{fetched_display}"

  choice = Readline.readline("  [K]eep current / [U]se fetched / [C]ustom value? [K]: ", false)
  abort "\nCancelled." unless choice
  choice = choice.strip.downcase

  case choice
  when "u"
    if fetched_name.empty?
      nil
    else
      order = fetched_order.to_i
      order = 1 if order < 1
      { "name" => fetched_name, "order" => order }
    end
  when "c"
    name_input = Readline.readline("  Saga name (blank to remove): ", false)
    abort "\nCancelled." unless name_input
    name_input = name_input.strip
    return nil if name_input.empty?

    order_input = Readline.readline("  Order in saga: ", false)
    abort "\nCancelled." unless order_input
    order = order_input.strip.to_i
    order = 1 if order < 1
    { "name" => name_input, "order" => order }
  else
    current_saga
  end
end

# ---------------------------------------------------------------------------
# Cover handling
# ---------------------------------------------------------------------------

def prompt_cover_update(book, fetched_cover_url)
  return unless fetched_cover_url && !fetched_cover_url.empty?

  puts ""
  input = Readline.readline("Cover: Download new cover from Goodreads? [y/N]: ", false)
  return unless input&.strip&.downcase == "y"

  FileUtils.mkdir_p(COVERS_DIR)
  book_id = book["id"]
  title = book["title"]
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  puts "  Downloading cover..."
  if http_download(fetched_cover_url, dest)
    # Remove old covers for this book (different filenames)
    old_covers = (book["covers"] || []).map { |c| c["file"] }
    old_covers.each do |old_file|
      old_path = File.join(ROOT_DIR, old_file)
      if File.exist?(old_path) && old_path != dest
        File.delete(old_path)
        puts "  Removed old cover: #{old_file}"
      end
    end

    book["covers"] = [{ "file" => "covers/#{filename}", "default" => true }]
    puts "  Cover saved: covers/#{filename}"
  else
    puts "  Failed to download cover."
  end
end

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Edit Book Metadata"
  puts "=" * 50

  books = load_db

  if books.empty?
    puts "No books found. Run add_book.rb first."
    exit 0
  end

  # Step 1: Display and select book
  display_book_list(books)
  index = prompt_selection(books)
  book = books[index]

  puts ""
  puts "Selected: #{book["title"]}"

  # Step 2: Build Goodreads search query
  fetched = nil
  begin
    # Determine search strategy
    isbn = (book["identifiers"] || []).find { |id| id["type"] == "ISBN" }&.dig("value")
    first_author = book.dig("authors", 0, "name")

    search_query = if isbn && !isbn.empty?
                     isbn
                   elsif first_author
                     "#{book["title"]} #{first_author}"
                   else
                     book["title"]
                   end

    results = goodreads_search(search_query)

    if results.any?
      display_goodreads_results(results)
      puts "\n  0. Skip refetch / edit manually"
      input = Readline.readline("\nSelect a result (1-#{results.size}, or 0 to skip): ", false)
      abort "\nCancelled." unless input
      choice = input.strip.to_i

      if choice >= 1 && choice <= results.size
        fetched = scrape_goodreads_detail(results[choice - 1][:url])
      else
        puts "Skipping refetch. You can edit fields manually."
      end
    else
      puts "  No results found."
    end
  rescue StandardError => e
    puts "  Goodreads lookup failed: #{e.message}"
    puts "  You can still edit fields manually."
  end

  fetched ||= {}

  # Step 3: Field-by-field comparison
  puts "\n" + "-" * 50
  puts "  Edit Fields"
  puts "-" * 50

  book["title"] = prompt_field("Title", book["title"], fetched[:title])
  book["subtitle"] = prompt_field("Subtitle", book["subtitle"], fetched[:subtitle])
  book["original_title"] = prompt_field("Original title", book["original_title"], fetched[:original_title])
  book["first_publishing_date"] = prompt_field("First publishing date", book["first_publishing_date"], fetched[:first_publishing_date])
  book["publisher"] = select_publisher(default: fetched[:publisher] || book["publisher"])
  book["identifiers"] = prompt_field_identifiers(book["identifiers"], fetched[:isbn])
  book["authors"] = prompt_field_authors(book["authors"], fetched[:authors])
  book["saga"] = prompt_field_saga(book["saga"], fetched[:saga_name], fetched[:saga_order])

  # Step 4: Cover
  prompt_cover_update(book, fetched[:cover_url])

  # Step 5: Score
  puts ""
  new_score = prompt_score(book["score"])
  book["score"] = new_score if new_score

  # Step 6: Save
  save_db(books)

  puts ""
  puts "Book updated: \"#{book["title"]}\""

  # Step 7: Git auto-commit
  git_auto_commit("Edit", book, include_covers: true)
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
