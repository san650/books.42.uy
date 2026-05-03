# frozen_string_literal: true

require_relative "../constants"

def flatten_lookup(result)
  pairs = []
  result.each do |source, value|
    label = SOURCE_LABELS[source] || source
    if value.is_a?(Array)
      value.each { |record| pairs << [label, record] }
    elsif value.is_a?(Hash)
      pairs << [label, value]
    end
  end
  pairs
end

def record_context(record, exclude: nil)
  parts = []
  isbn_id = (record["identifiers"] || []).find { |id| id["type"] == "ISBN_13" } ||
            (record["identifiers"] || []).find { |id| id["type"] == "ISBN_10" }
  parts << "ISBN: #{isbn_id["value"]}" if isbn_id && exclude != :isbn
  parts << "Title: #{record["title"]}" if record["title"] && exclude != :title
  parts.first(2).join(", ")
end
