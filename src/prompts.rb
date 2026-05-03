# frozen_string_literal: true

require_relative "console_ui"

# Top-level helpers — thin delegators over UI.current so tests can stub
# input/output by setting UI.current = StubConsoleUI.new.

def prompt(label, default: nil, required: false, clearable: false)
  UI.current.ask(label, default: default, required: required, clearable: clearable)
end

def prompt_yes_no(label, default: "y")
  UI.current.confirm(label, default: default)
end

def read_key
  UI.current.read_key
end

def prompt_score(current_score)
  input = UI.current.readline("Update score? (current: #{current_score || "none"}) [enter to skip]: ")
  if input.nil?
    UI.current.say ""
    exit 130
  end
  input = input.strip
  return nil if input.empty?

  score = input.to_i
  if score >= 1 && score <= 10
    score
  else
    UI.current.say "Score must be 1-10. Keeping current score."
    nil
  end
end

def prompt_score_update(current_score)
  loop do
    input = UI.current.readline("New score? (current: #{current_score || "none"}) [enter to keep]: ")
    if input.nil?
      UI.current.say ""
      exit 130
    end

    input = input.strip
    return nil if input.empty?

    score = input.to_i
    return score if score >= 1 && score <= 10 && score.to_s == input

    UI.current.say "  Please enter a whole number between 1 and 10, or press enter to keep current."
  end
end

def numeric_score?(book)
  book["score"].is_a?(Numeric)
end
