#!/usr/bin/env ruby
# frozen_string_literal: true

# add_book.rb — Interactive CLI to add books to db.json
# Primary source: Goodreads (scraping). Fallback: OpenLibrary API.

require_relative "common"

# ---------------------------------------------------------------------------
# OpenLibrary API (fallback)
# ---------------------------------------------------------------------------

def search_openlibrary(query)
  encoded = URI.encode_www_form_component(query)
  url = "https://openlibrary.org/search.json?title=#{encoded}&limit=10"
  puts "\nSearching OpenLibrary (fallback)..."
  data = http_get_json(url)

  unless data && data["docs"]
    puts "  No results or API unavailable."
    return []
  end

  data["docs"]
end

def display_openlibrary_results(docs)
  return if docs.empty?

  puts "\nResults:"
  docs.each_with_index do |doc, i|
    authors = (doc["author_name"] || []).join(", ")
    year = doc["first_publish_year"]
    title = doc["title"]
    puts "  #{i + 1}. #{title} — #{authors} (#{year || '?'})"
  end
end

def fetch_work_details(work_key)
  return nil unless work_key

  url = "https://openlibrary.org#{work_key}.json"
  http_get_json(url)
end

def fetch_editions(work_key)
  return [] unless work_key

  url = "https://openlibrary.org#{work_key}/editions.json?limit=50"
  data = http_get_json(url)
  return [] unless data && data["entries"]

  data["entries"]
end

def find_best_edition(editions)
  return nil if editions.empty?

  spanish = editions.select do |ed|
    langs = ed["languages"] || []
    langs.any? { |l| l["key"] == "/languages/spa" }
  end

  candidates = spanish.empty? ? editions : spanish
  with_isbn = candidates.select { |ed| ed["isbn_13"]&.any? || ed["isbn_10"]&.any? }
  with_isbn.first || candidates.first
end

def extract_isbn(edition)
  return nil unless edition

  isbn13 = edition["isbn_13"]&.first
  return isbn13 if isbn13

  edition["isbn_10"]&.first
end

# Build metadata from an OpenLibrary search result
def metadata_from_openlibrary(doc, title_query)
  metadata = {
    title: doc["title"] || title_query,
    subtitle: "",
    original_title: "",
    first_publishing_date: doc["first_publish_year"].to_s,
    publish_dates: [],
    authors: (doc["author_name"] || []).map { |name| { "name" => name, "aliases" => [] } },
    isbn: "",
    publisher: "",
    saga: nil,
    cover_url: nil
  }

  puts "\nFetching OpenLibrary details..."
  work_key = doc["key"]
  work = fetch_work_details(work_key)
  if work && work["title"] && work["title"] != metadata[:title]
    metadata[:original_title] = work["title"]
  end

  editions = fetch_editions(work_key)
  best_edition = find_best_edition(editions)

  if best_edition
    metadata[:isbn] = extract_isbn(best_edition) || ""
    metadata[:publisher] = best_edition["publishers"]&.first.to_s
    metadata[:publish_dates] = [best_edition["publish_date"]].compact
  end

  if metadata[:isbn].empty?
    isbn_list = doc["isbn"] || []
    metadata[:isbn] = isbn_list.first.to_s unless isbn_list.empty?
  end

  # Cover from OpenLibrary
  cover_id = doc["cover_i"]
  if cover_id
    metadata[:cover_url] = "https://covers.openlibrary.org/b/id/#{cover_id}-L.jpg"
  end

  metadata
end

# ---------------------------------------------------------------------------
# Cover download
# ---------------------------------------------------------------------------

def download_cover(cover_url, isbn, book_id, title)
  FileUtils.mkdir_p(COVERS_DIR)
  sanitized = sanitize_title(title)
  filename = "#{book_id}-#{sanitized}.jpg"
  dest = File.join(COVERS_DIR, filename)

  # Try Goodreads cover URL first
  if cover_url && !cover_url.empty?
    puts "\nDownloading cover from Goodreads..."
    if http_download(cover_url, dest)
      if File.size(dest) > 1000
        puts "  Cover saved: covers/#{filename}"
        return "covers/#{filename}"
      else
        File.delete(dest) if File.exist?(dest)
        puts "  Goodreads cover too small (likely placeholder), trying fallback..."
      end
    else
      puts "  Goodreads cover download failed, trying fallback..."
    end
  end

  # Fall back to OpenLibrary covers via ISBN
  if isbn && !isbn.empty?
    puts "  Trying OpenLibrary covers..."
    ol_url = "https://covers.openlibrary.org/b/isbn/#{URI.encode_www_form_component(isbn)}-L.jpg"
    if http_download(ol_url, dest)
      if File.size(dest) > 1000
        puts "  Cover saved: covers/#{filename}"
        return "covers/#{filename}"
      else
        File.delete(dest) if File.exist?(dest)
        puts "  OpenLibrary cover too small (likely placeholder), skipping."
      end
    end
  end

  puts "  No cover available."
  nil
end

# ---------------------------------------------------------------------------
# Publisher selection
# ---------------------------------------------------------------------------

def select_publisher(default: nil)
  puts "\nPublisher:"
  PUBLISHERS.each_with_index do |pub, i|
    marker = (default && pub.downcase == default.to_s.downcase) ? " *" : ""
    puts "  #{i + 1}. #{pub}#{marker}"
  end
  puts "  #{PUBLISHERS.size + 1}. Other (enter custom)"

  if default && !default.empty?
    print "Select [#{default}]: "
  else
    print "Select: "
  end

  input = $stdin.gets
  abort "\nCancelled." unless input
  input = input.strip

  return default if input.empty? && default && !default.empty?

  num = input.to_i
  if num >= 1 && num <= PUBLISHERS.size
    PUBLISHERS[num - 1]
  elsif num == PUBLISHERS.size + 1
    prompt("  Enter publisher name", required: true)
  elsif input.empty?
    default && !default.empty? ? default : prompt("  Enter publisher name", required: true)
  else
    input
  end
end

# ---------------------------------------------------------------------------
# Score prompt (required — loops until valid)
# ---------------------------------------------------------------------------

def prompt_required_score
  loop do
    input = prompt("Score (1-10)", required: true)
    score = input.to_i
    return score if score >= 1 && score <= 10

    puts "  Please enter a number between 1 and 10."
  end
end

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def main
  puts "=" * 50
  puts "  Lev — Add a Book"
  puts "=" * 50

  books = load_db

  # Step 1: Prompt for search query (or take from ARGV)
  search_query = ARGV.join(" ").strip
  if search_query.empty?
    search_query = prompt("\nSearch query (e.g. 'Anochecer Isaac')", required: true)
  else
    puts "\nSearching for: #{search_query}"
  end

  # Step 2: Search Goodreads (primary)
  metadata = nil
  gr_results = goodreads_search(search_query)

  if gr_results.any?
    display_goodreads_results(gr_results)
    puts "\n  0. None of these — enter manually"
    choice = prompt("Select a result (1-#{gr_results.size}, or 0)")
    num = choice.to_i

    if num >= 1 && num <= gr_results.size
      selected = gr_results[num - 1]
      detail = scrape_goodreads_detail(selected[:url])

      if detail
        metadata = {
          title: detail[:title] || selected[:title],
          subtitle: detail[:subtitle] || "",
          original_title: detail[:original_title] || "",
          first_publishing_date: detail[:first_publishing_date] || "",
          publish_dates: [],
          authors: (detail[:authors] || [selected[:author]]).map { |name| { "name" => name, "aliases" => [] } },
          contributors: detail[:contributors],
          isbn: detail[:isbn] || "",
          publisher: detail[:publisher] || "",
          saga: nil,
          cover_url: detail[:cover_url]
        }

        if detail[:saga_name]
          metadata[:saga] = { "name" => detail[:saga_name], "order" => detail[:saga_order] || 1 }
        end

        puts "\n  Goodreads data loaded successfully."
      else
        puts "\n  Could not scrape book details. Falling back..."
      end
    end
  end

  # Step 3: Fall back to OpenLibrary if Goodreads yielded nothing
  if metadata.nil?
    docs = search_openlibrary(search_query)

    if docs.any?
      display_openlibrary_results(docs)
      puts "\n  0. None of these — enter manually"
      choice = prompt("Select a result (1-#{docs.size}, or 0)")
      num = choice.to_i

      if num >= 1 && num <= docs.size
        metadata = metadata_from_openlibrary(docs[num - 1], search_query)
      end
    else
      puts "\nNo results found on either service. You'll enter details manually."
    end
  end

  # Step 4: If still no metadata, start with empty defaults
  metadata ||= {
    title: search_query,
    subtitle: "",
    original_title: "",
    first_publishing_date: "",
    publish_dates: [],
    authors: [],
    isbn: "",
    publisher: "",
    saga: nil,
    cover_url: nil
  }

  # Step 4.5: Augment with Spanish Wikipedia if original title or ISBN is missing
  if metadata[:original_title].to_s.empty? || metadata[:isbn].to_s.empty?
    author_name = metadata[:contributors]&.find { |c| c[:role] == "Author" }&.dig(:name)
    author_name ||= metadata[:authors].first&.dig("name")
    wiki = search_wikipedia_es(metadata[:title], author_name)
    if wiki
      if metadata[:original_title].to_s.empty? && wiki[:original_title]
        metadata[:original_title] = wiki[:original_title]
        puts "  Wikipedia: found original title"
      end
      if metadata[:isbn].to_s.empty? && wiki[:isbn]
        metadata[:isbn] = wiki[:isbn]
        puts "  Wikipedia: found ISBN"
      end
    end
  end

  # Step 5: Interactive field review — show each scraped field, let user confirm or override
  puts "\n" + "-" * 50
  puts "  Review & Edit Book Details"
  puts "-" * 50

  metadata[:title] = prompt("Title", default: metadata[:title], required: true)

  # Check for duplicate
  existing = books.find { |b| b["title"].downcase == metadata[:title].downcase }
  if existing
    author_name = existing["authors"]&.first&.dig("name") || "Unknown"
    puts "\n  Book already exists: \"#{existing["title"]}\" by #{author_name} (ID: #{existing["id"]})"
    puts "  To edit it, run:"
    puts "    ruby edit_book.rb"
    exit 0
  end

  metadata[:subtitle] = prompt("Subtitle (press enter to skip)", default: metadata[:subtitle])
  metadata[:original_title] = prompt("Original title", default: metadata[:original_title])
  metadata[:first_publishing_date] = prompt("First publishing date", default: metadata[:first_publishing_date])

  # Publish dates
  pd_default = metadata[:publish_dates].join(", ")
  pd_input = prompt("Publish dates (comma-separated)", default: pd_default)
  metadata[:publish_dates] = pd_input.to_s.split(",").map(&:strip).reject(&:empty?)

  # Authors — select which contributors to keep
  if metadata[:contributors]&.any?
    puts "\nContributors found:"
    metadata[:contributors].each_with_index do |c, i|
      role_label = c[:role] && c[:role] != "Author" ? " (#{c[:role]})" : ""
      puts "  #{i + 1}. #{c[:name]}#{role_label}"
    end
    author_indices = metadata[:contributors].each_with_index
      .select { |c, _| c[:role] == "Author" }
      .map { |_, i| i }
    default_selection = author_indices.map { |i| i + 1 }.join(",")
    default_selection = (1..metadata[:contributors].size).to_a.join(",") if default_selection.empty?
    input = prompt("Select authors to keep (e.g. 1,2)", default: default_selection)
    selected_nums = input.to_s.split(",").map { |s| s.strip.to_i }
      .select { |n| n >= 1 && n <= metadata[:contributors].size }
    metadata[:authors] = selected_nums.map do |n|
      { "name" => metadata[:contributors][n - 1][:name], "aliases" => [] }
    end
  elsif metadata[:authors].any?
    puts "\nAuthors:"
    metadata[:authors].each_with_index do |a, i|
      puts "  #{i + 1}. #{a["name"]}"
    end
    input = prompt("Select authors to keep (e.g. 1,2)", default: (1..metadata[:authors].size).to_a.join(","))
    selected_nums = input.to_s.split(",").map { |s| s.strip.to_i }
      .select { |n| n >= 1 && n <= metadata[:authors].size }
    metadata[:authors] = selected_nums.map { |n| metadata[:authors][n - 1] }
  end

  if metadata[:authors].empty?
    loop do
      name = prompt("Author name (blank to finish)", required: false)
      break if name.empty?

      aliases_input = prompt("  Aliases for #{name} (comma-separated, blank for none)")
      aliases = aliases_input.split(",").map(&:strip).reject(&:empty?)
      metadata[:authors] << { "name" => name, "aliases" => aliases }
    end
  end

  puts "  Warning: no authors entered." if metadata[:authors].empty?

  # ISBN
  metadata[:isbn] = prompt("ISBN", default: metadata[:isbn])

  # Publisher
  metadata[:publisher] = select_publisher(default: metadata[:publisher])

  # Saga
  if metadata[:saga]
    saga_default_name = metadata[:saga]["name"]
    saga_default_order = metadata[:saga]["order"]
    saga_name = prompt("Book saga/series name", default: saga_default_name)
    if saga_name.empty?
      metadata[:saga] = nil
    else
      loop do
        order_input = prompt("Order in saga (number)", default: saga_default_order.to_s, required: true)
        order = order_input.to_i
        if order >= 1
          metadata[:saga] = { "name" => saga_name, "order" => order }
          break
        end
        puts "  Please enter a positive number."
      end
    end
  else
    saga_name = prompt("Book saga/series name (press enter to skip)")
    unless saga_name.empty?
      loop do
        order_input = prompt("Order in saga (number)", required: true)
        order = order_input.to_i
        if order >= 1
          metadata[:saga] = { "name" => saga_name, "order" => order }
          break
        end
        puts "  Please enter a positive number."
      end
    end
  end

  # Score
  score = prompt_required_score

  # Step 6: Assign ID
  book_id = next_id(books)

  # Step 7: Download cover
  cover_path = download_cover(metadata[:cover_url], metadata[:isbn], book_id, metadata[:title])
  covers = []
  if cover_path
    covers << { "file" => cover_path, "default" => true }
  end

  # Step 8: Build book object
  book = {
    "id" => book_id,
    "title" => metadata[:title],
    "subtitle" => metadata[:subtitle].to_s,
    "original_title" => metadata[:original_title].to_s,
    "first_publishing_date" => metadata[:first_publishing_date].to_s,
    "publish_dates" => metadata[:publish_dates],
    "authors" => metadata[:authors],
    "identifiers" => [],
    "covers" => covers,
    "publisher" => metadata[:publisher],
    "saga" => metadata[:saga],
    "score" => score,
    "review" => ""
  }

  unless metadata[:isbn].to_s.empty?
    book["identifiers"] << { "type" => "ISBN", "value" => metadata[:isbn] }
  end

  # Step 9: Confirm
  puts "\n" + "=" * 50
  puts "  Book Summary"
  puts "=" * 50
  puts "  Title:       #{book["title"]}"
  puts "  Subtitle:    #{book["subtitle"]}" unless book["subtitle"].empty?
  puts "  Original:    #{book["original_title"]}" unless book["original_title"].empty?
  puts "  Authors:     #{book["authors"].map { |a| a["name"] }.join(", ")}"
  puts "  Published:   #{book["first_publishing_date"]}"
  puts "  ISBN:        #{metadata[:isbn]}" unless metadata[:isbn].to_s.empty?
  puts "  Publisher:   #{book["publisher"]}"
  puts "  Score:       #{book["score"]}/10"
  puts "  Saga:        #{metadata[:saga]["name"]} ##{metadata[:saga]["order"]}" if metadata[:saga]
  puts "  Cover:       #{cover_path || "none"}"
  puts "  ID:          #{book_id}"
  puts ""

  unless prompt_yes_no("Save this book?", default: "y")
    puts "Cancelled. Book not saved."
    exit 0
  end

  # Step 10: Save
  books << book
  save_db(books)
  puts "\nBook saved to db.json! (ID: #{book_id})"

  # Step 11: Git auto-commit
  git_auto_commit("Add", book, include_covers: true)
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
