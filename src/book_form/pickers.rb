# frozen_string_literal: true

require_relative "../prompts"
require_relative "../interactive_select"
require_relative "../publishers"
require_relative "build_options"
require_relative "collectors"

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

  UI.current.say "\n#{field_name}:"
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

  UI.current.say "\n#{field_name} (multi-select):"
  idxs = interactive_select(items, prompt_label: field_name, multi: true, preselected: preselected)
  abort "\nCancelled." unless idxs

  values = idxs.select { |i| i < options.size }.map { |i| options[i][:value] }

  if allow_other && idxs.include?(options.size)
    custom = prompt("  Enter custom #{field_name} (comma-separated)")
    values.concat(custom.to_s.split(",").map(&:strip).reject(&:empty?))
  end

  values
end

def pick_publisher(pairs, db, current: nil)
  source_publishers = collect_field(pairs) { |r| r["publisher"] }
  source_values = source_publishers.map { |c| c[:value] }.uniq

  publishers = load_publishers(db)
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

  UI.current.say "\nPublisher:"
  idx = interactive_select(items, prompt_label: "Publisher", default: default_idx)
  abort "\nCancelled." unless idx

  if idx < combined.size
    selected = combined[idx]
    add_publisher(db, selected) unless publishers.include?(selected)
    selected
  elsif idx == combined.size
    ""
  else
    name = prompt("  Enter publisher name")
    return "" if name.empty?
    add_publisher(db, name)
    name
  end
end
