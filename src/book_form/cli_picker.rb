# frozen_string_literal: true

require_relative "pickers"
require_relative "../prompts"

# Picker the CLI uses for add/edit flows. Each method delegates to the
# top-level pick_* helpers, which in turn read input via UI.current.
class CLIPicker
  def single(field, candidates, current: nil, required: false, format_value: ->(v) { v.to_s })
    pick_single(field, candidates, current: current, required: required, format_value: format_value)
  end

  def multi(field, candidates, current: [], format_value: ->(v) { v.to_s }, allow_other: true)
    pick_multi(field, candidates, current: current, format_value: format_value, allow_other: allow_other)
  end

  def publisher(pairs, db, current: nil)
    pick_publisher(pairs, db, current: current)
  end

  def required_score
    loop do
      input = prompt("Score (1-10)", required: true)
      score = input.to_i
      return score if score >= 1 && score <= 10

      UI.current.say "  Please enter a number between 1 and 10."
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
