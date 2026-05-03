# frozen_string_literal: true

def values_equal?(a, b)
  return true if a == b
  return a.to_s == b.to_s unless a.is_a?(Hash) || b.is_a?(Hash)

  a.is_a?(Hash) && b.is_a?(Hash) && a.sort == b.sort
end

# Build option list from raw candidates: dedupes by value, merges sources,
# and appends a per-record context string for disambiguation.
def build_options(candidates, format_value: ->(v) { v.to_s })
  grouped = {}
  candidates.each do |c|
    key = c[:value].is_a?(Hash) ? c[:value].sort.to_h : c[:value]
    grouped[key] ||= { value: c[:value], sources: [], contexts: [] }
    grouped[key][:sources] << c[:source]
    grouped[key][:contexts] << c[:context] if c[:context] && !c[:context].empty?
  end

  grouped.values.map do |g|
    sources = g[:sources].uniq
    context = g[:contexts].uniq.first
    label_parts = []
    label_parts << context unless context.nil? || context.empty?
    label_parts << "Source#{sources.size == 1 ? "" : "s"}: #{sources.join(", ")}"
    {
      value: g[:value],
      label: "#{format_value.call(g[:value])} (#{label_parts.join(", ")})"
    }
  end
end

# Inject the current value as a synthetic option (or tag the existing match
# with [Current]) so the edit flow always has it available and pre-selected.
def merge_current(options, current, format_value)
  return options if current.nil?
  return options if current.is_a?(String) && current.empty?
  return options if current.is_a?(Array) && current.empty?

  match = options.find { |o| values_equal?(o[:value], current) }
  if match
    match[:label] = "#{match[:label]} [Current]" unless match[:label].include?("[Current]")
    options
  else
    [{ value: current, label: "#{format_value.call(current)} (Current)" }] + options
  end
end
