# frozen_string_literal: true

require_relative "flatten"

def collect_field(pairs, exclude_context: nil)
  pairs.flat_map do |source, record|
    raw = yield(record)
    Array(raw).compact.reject { |v| v.to_s.strip.empty? }.map do |v|
      { value: v, source: source, context: record_context(record, exclude: exclude_context) }
    end
  end
end

def collect_identifiers(pairs)
  pairs.flat_map do |source, record|
    (record["identifiers"] || []).map do |id|
      next nil if id["value"].to_s.strip.empty?
      { value: { "type" => id["type"], "value" => id["value"] }, source: source, context: "Title: #{record["title"]}" }
    end.compact
  end
end

def collect_sagas(pairs)
  pairs.flat_map do |source, record|
    saga = record["saga"]
    next [] if saga.nil? || saga["name"].to_s.empty?
    [{ value: { "name" => saga["name"], "order" => saga["order"] || 1 },
       source: source,
       context: "Title: #{record["title"]}" }]
  end
end
