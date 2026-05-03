# frozen_string_literal: true

# book_form.rb — Shared interactive field-pickers used by add_book.rb and
# edit_book.rb. Both flows present the same per-field UI: source-suggested
# values plus an optional pre-selected "current" value (used by edit_book).

require_relative "common"
require_relative "lookup"

SOURCE_LABELS = {
  "googlebooks" => "Google Books",
  "openlibrary" => "OpenLibrary API",
  "openlibrary_html" => "OpenLibrary HTML",
  "goodreads" => "Goodreads",
  "wikipedia" => "Wikipedia"
}.freeze

# ---------------------------------------------------------------------------
# Lookup result helpers
# ---------------------------------------------------------------------------

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

# Short context string for an option label, used to disambiguate similar values.
def record_context(record, exclude: nil)
  parts = []
  isbn_id = (record["identifiers"] || []).find { |id| id["type"] == "ISBN_13" } ||
            (record["identifiers"] || []).find { |id| id["type"] == "ISBN_10" }
  parts << "ISBN: #{isbn_id["value"]}" if isbn_id && exclude != :isbn
  parts << "Title: #{record["title"]}" if record["title"] && exclude != :title
  parts.first(2).join(", ")
end

# ---------------------------------------------------------------------------
# Option building
# ---------------------------------------------------------------------------

def values_equal?(a, b)
  return true if a == b
  return a.to_s == b.to_s unless a.is_a?(Hash) || b.is_a?(Hash)

  a.is_a?(Hash) && b.is_a?(Hash) && a.sort == b.sort
end

# Build option list from raw candidates, dedupe by value, append source list
# and a per-record context to help the user disambiguate.
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
# with "Current") so the edit flow always has it available and pre-selected.
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

# ---------------------------------------------------------------------------
# Single-value picker
# ---------------------------------------------------------------------------

def pick_single(field_name, candidates, format_value: ->(v) { v.to_s }, required: false, current: nil)
  options = build_options(candidates, format_value: format_value)
  options = merge_current(options, current, format_value)

  if options.empty?
    return prompt(field_name, default: current, required: required)
  end

  items = options.map { |o| o[:label] }
  items << "Empty" unless required
  items << "Other: enter custom value"

  default_idx = options.index { |o| values_equal?(o[:value], current) } || 0

  puts "\n#{field_name}:"
  idx = interactive_select(items, prompt_label: field_name, default: default_idx)
  abort "\nCancelled." unless idx

  if idx < options.size
    options[idx][:value]
  elsif !required && idx == options.size
    ""
  else
    prompt("  Enter #{field_name}", required: required)
  end
end

# ---------------------------------------------------------------------------
# Multi-value picker — pre-selects current values (or first option) so a
# bare Enter still produces a usable selection.
# ---------------------------------------------------------------------------

def pick_multi(field_name, candidates, format_value: ->(v) { v.to_s }, allow_other: true, current: [])
  current = Array(current)
  options = build_options(candidates, format_value: format_value)
  current.reverse_each do |val|
    options = merge_current(options, val, format_value)
  end

  if options.empty?
    val = prompt("#{field_name} (comma-separated)", default: current.join(", "))
    return val.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  items = options.map { |o| o[:label] }
  items << "Other: enter custom value(s) (comma-separated)" if allow_other

  preselected = current.flat_map do |val|
    idx = options.index { |o| values_equal?(o[:value], val) }
    idx ? [idx] : []
  end
  preselected = [0] if preselected.empty? && !options.empty?

  puts "\n#{field_name} (multi-select):"
  idxs = interactive_select(items, prompt_label: field_name, multi: true, preselected: preselected)
  abort "\nCancelled." unless idxs

  values = idxs.select { |i| i < options.size }.map { |i| options[i][:value] }

  if allow_other && idxs.include?(options.size)
    custom = prompt("  Enter custom #{field_name} (comma-separated)")
    values.concat(custom.to_s.split(",").map(&:strip).reject(&:empty?))
  end

  values
end

# ---------------------------------------------------------------------------
# Field candidate extractors
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Publisher: special case — uses publishers.txt as the option set, augmented
# with any value(s) from the lookup, plus Empty / Other. Pre-selects the
# `current` publisher (used by edit_book) when supplied.
# ---------------------------------------------------------------------------

def pick_publisher(pairs, current: nil)
  source_publishers = collect_field(pairs) { |r| r["publisher"] }
  source_values = source_publishers.map { |c| c[:value] }.uniq

  publishers = load_publishers
  combined = (publishers + source_values + [current].compact).uniq.sort_by { |p| p.unicode_normalize(:nfkd).downcase }

  items = combined.map do |pub|
    tags = []
    tags << "Current" if current && pub.casecmp(current.to_s).zero?
    if source_values.include?(pub)
      sources = source_publishers.select { |c| c[:value] == pub }.map { |c| c[:source] }.uniq
      tags << "Source#{sources.size == 1 ? "" : "s"}: #{sources.join(", ")}"
    end
    tags.empty? ? pub : "#{pub} (#{tags.join(", ")})"
  end
  items << "Empty"
  items << "Other: enter custom publisher"

  default_idx = if current && !current.to_s.empty?
                  combined.index { |p| p.casecmp(current.to_s).zero? } || combined.size
                elsif source_values.any?
                  combined.index(source_values.first) || 0
                else
                  combined.size # "Empty"
                end

  puts "\nPublisher:"
  idx = interactive_select(items, prompt_label: "Publisher", default: default_idx)
  abort "\nCancelled." unless idx

  if idx < combined.size
    selected = combined[idx]
    add_publisher(selected) unless publishers.include?(selected)
    selected
  elsif idx == combined.size
    ""
  else
    name = prompt("  Enter publisher name")
    return "" if name.empty?
    add_publisher(name)
    name
  end
end

# ---------------------------------------------------------------------------
# Picker interfaces — the orchestrators (add_book/edit_book) take a picker
# as a parameter so tests can swap in a scripted version. CLIPicker uses the
# pick_* helpers above; ScriptedPicker returns canned answers.
# ---------------------------------------------------------------------------

class CLIPicker
  def single(field, candidates, current: nil, required: false, format_value: ->(v) { v.to_s })
    pick_single(field, candidates, current: current, required: required, format_value: format_value)
  end

  def multi(field, candidates, current: [], format_value: ->(v) { v.to_s }, allow_other: true)
    pick_multi(field, candidates, current: current, format_value: format_value, allow_other: allow_other)
  end

  def publisher(pairs, current: nil)
    pick_publisher(pairs, current: current)
  end

  def required_score
    loop do
      input = prompt("Score (1-10)", required: true)
      score = input.to_i
      return score if score >= 1 && score <= 10

      puts "  Please enter a number between 1 and 10."
    end
  end

  def score_update(current_score)
    prompt_score_update(current_score)
  end

  def author_fallback_names
    names = []
    loop do
      name = prompt("Author name (blank to finish)")
      break if name.empty?
      names << name
    end
    names
  end

  def saga_order(default: nil)
    prompt("Order in saga (number)", default: default&.to_s, required: true).to_i
  end

  def confirm_save(default: "y")
    prompt_yes_no("Save this book?", default: default)
  end
end

# Picker that returns scripted answers; used in tests. Construct with a hash
# keyed by field name (and a few well-known special keys).
class ScriptedPicker
  def initialize(answers = {})
    @answers = answers
  end

  def single(field, _candidates, **_opts)
    fetch(field)
  end

  def multi(field, _candidates, **_opts)
    fetch(field)
  end

  def publisher(_pairs, **_opts)
    fetch("Publisher")
  end

  def required_score
    fetch("Score")
  end

  def score_update(_current_score)
    @answers.fetch("Score", nil)
  end

  def author_fallback_names
    @answers.fetch("AuthorFallback", [])
  end

  def saga_order(default: nil)
    @answers.fetch("SagaOrder", default || 1)
  end

  def confirm_save(default: "y")
    @answers.fetch("ConfirmSave", true)
  end

  private

  def fetch(key)
    raise KeyError, "ScriptedPicker missing answer for #{key.inspect}" unless @answers.key?(key)

    @answers[key]
  end
end

# ---------------------------------------------------------------------------
# Author resolution — used by both add and update flows
# ---------------------------------------------------------------------------

def resolve_author_ids(db, author_names)
  author_names.map do |name|
    existing = find_author_by_name(db, name)
    if existing
      warn "  [MATCH] #{name} -> existing author ##{existing["id"]}"
      existing
    else
      author = find_or_create_author(db, name, aliases: [])
      warn "  [NEW]   #{name} -> author ##{author["id"]}"
      author
    end
  end.map { |a| a["id"] }
end
