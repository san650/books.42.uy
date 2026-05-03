# frozen_string_literal: true

require_relative "lookup/lookup"

def print_record_summary(label, record)
  warn ""
  warn "── #{label} ──"
  warn "  title:     #{record["title"]}" if record["title"]
  warn "  subtitle:  #{record["subtitle"]}" if record["subtitle"]
  warn "  original:  #{record["original_title"]}" if record["original_title"]
  warn "  authors:   #{record["authors"].join(", ")}" if record["authors"]&.any?
  warn "  publisher: #{record["publisher"]}" if record["publisher"]
  warn "  first pub: #{record["first_publishing_date"]}" if record["first_publishing_date"]
  warn "  published: #{record["publish_dates"].join(", ")}" if record["publish_dates"]&.any?
  (record["identifiers"] || []).each do |id|
    warn "  #{id["type"].downcase.tr("_", "-").ljust(9)}: #{id["value"]}"
  end
  warn "  saga:      #{record["saga"]["name"]} ##{record["saga"]["order"]}" if record["saga"]
  warn "  language:  #{record["language"]}" if record["language"]
  warn "  cover:     #{record["cover_url"]}" if record["cover_url"]
  warn "  url:       #{record["url"]}" if record["url"]
end

def print_lookup_summary(result)
  result.each do |source, value|
    if value.is_a?(Array)
      value.each_with_index do |record, i|
        print_record_summary("#{source} ##{i + 1}", record)
      end
    else
      print_record_summary(source, value)
    end
  end
end

def lookup_cli(argv = ARGV)
  raw = argv.join(" ").strip
  if raw.empty?
    warn "Usage: ruby scripts/lookup.rb <ISBN-or-text-query>"
    warn "  ISBN: 10 or 13 digits, with or without dashes/spaces"
    warn "  Text: any free-text search (book title, author, etc.)"
    exit 1
  end

  result = lookup(raw)

  if result.empty?
    warn ""
    warn "No data found for #{raw.inspect} from any source."
    puts "{}"
    exit 1
  end

  print_lookup_summary(result)

  warn ""
  puts JSON.pretty_generate(result)
end
