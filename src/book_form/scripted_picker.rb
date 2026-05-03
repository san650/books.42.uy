# frozen_string_literal: true

# Picker that returns scripted answers; used in tests. Construct with a hash
# keyed by field name (and a few well-known special keys: AuthorFallback,
# SagaOrder, ConfirmSave, Score).
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
