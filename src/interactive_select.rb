# frozen_string_literal: true

require_relative "prompts"

# Interactive list selector with arrow-key navigation. Multi-select rows
# render as "> [•] option" / "  [ ] option"; single-select rows as
# "> option" / "  option".
def interactive_select(items, prompt_label: "Select", default: 0, multi: false, preselected: [])
  return nil if items.empty?
  return [] if multi && items.empty?

  cursor = default.clamp(0, items.size - 1)
  chosen = preselected.is_a?(Array) ? preselected.select { |i| i.between?(0, items.size - 1) }.uniq : []
  max_visible = [items.size, 20].min
  offset = 0
  rendered_lines = 0

  render = lambda {
    if rendered_lines > 0
      UI.current.print "\e[#{rendered_lines}A"
      rendered_lines.times { UI.current.print "\e[2K\n" }
      UI.current.print "\e[#{rendered_lines}A"
    end

    lines = 0

    label = multi ? "#{prompt_label} (space=toggle, enter=confirm)" : prompt_label
    if items.size > max_visible
      pos = "#{cursor + 1}/#{items.size}"
      UI.current.say "\e[2K  \e[90m#{label} (#{pos})\e[0m"
      lines += 1
    elsif multi
      UI.current.say "\e[2K  \e[90m#{label}\e[0m"
      lines += 1
    end

    max_visible.times do |i|
      idx = offset + i
      if idx < items.size
        checkbox = multi ? (chosen.include?(idx) ? "[•] " : "[ ] ") : ""
        if idx == cursor
          UI.current.say "\e[2K\e[33m>\e[0m \e[1m#{checkbox}#{items[idx]}\e[0m"
        else
          UI.current.say "\e[2K  #{checkbox}#{items[idx]}"
        end
      else
        UI.current.say "\e[2K"
      end
      lines += 1
    end

    rendered_lines = lines
  }

  render.call

  loop do
    key = read_key
    case key
    when :up
      if cursor > 0
        cursor -= 1
        offset = cursor if cursor < offset
      end
    when :down
      if cursor < items.size - 1
        cursor += 1
        offset = cursor - max_visible + 1 if cursor >= offset + max_visible
      end
    when :space
      if multi
        if chosen.include?(cursor)
          chosen.delete(cursor)
        else
          chosen << cursor
        end
      end
    when :enter
      if multi
        return chosen.empty? ? [cursor] : chosen.sort
      end
      return cursor
    when :ctrl_c
      UI.current.say ""
      exit 130
    else
      next
    end
    render.call
  end
end

def interactive_choice(choices, prompt_label: "Select", default: 0)
  return nil if choices.empty?

  selected = default.clamp(0, choices.size - 1)
  rendered_lines = 0

  render = lambda {
    if rendered_lines > 0
      UI.current.print "\e[#{rendered_lines}A"
      rendered_lines.times { UI.current.print "\e[2K\n" }
      UI.current.print "\e[#{rendered_lines}A"
    end

    UI.current.say "\e[2K  \e[90m#{prompt_label}\e[0m"
    choices.each_with_index do |choice, idx|
      key = choice[:key] || choice["key"]
      label = choice[:label] || choice["label"]
      prefix = idx == selected ? "\e[33m>\e[0m \e[1m" : "  "
      suffix = idx == selected ? "\e[0m" : ""
      hotkey = key ? "[#{key}] " : ""
      UI.current.say "\e[2K  #{prefix}#{hotkey}#{label}#{suffix}"
    end
    rendered_lines = choices.size + 1
  }

  render.call

  loop do
    key = read_key
    case key
    when :up
      selected -= 1 if selected > 0
    when :down
      selected += 1 if selected < choices.size - 1
    when :enter
      return choices[selected]
    when :ctrl_c
      UI.current.say ""
      exit 130
    else
      matched = choices.find { |choice| (choice[:key] || choice["key"]).to_s.downcase == key }
      return matched if matched
      next
    end
    render.call
  end
end
