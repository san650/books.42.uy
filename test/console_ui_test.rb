# frozen_string_literal: true

require_relative "test_helper"

class StubConsoleUITest < Test::Unit::TestCase
  def test_ask_returns_scripted_answer
    ui = StubConsoleUI.new(answers: ["alice"])
    assert_equal "alice", ui.ask("Name")
  end

  def test_ask_records_prompt_metadata
    ui = StubConsoleUI.new(answers: ["v"])
    ui.ask("Title", default: "T", required: true)
    assert_equal 1, ui.prompt_log.size
    assert_equal "Title", ui.prompt_log.first[:label]
    assert_equal "T", ui.prompt_log.first[:default]
    assert ui.prompt_log.first[:required]
  end

  def test_confirm_yes
    ui = StubConsoleUI.new(answers: ["yes"])
    assert ui.confirm("OK?")
  end

  def test_confirm_no
    ui = StubConsoleUI.new(answers: ["nope"])
    refute ui.confirm("OK?")
  end

  def test_say_captures_output
    ui = StubConsoleUI.new
    ui.say "hi"
    assert_equal ["hi"], ui.messages
  end

  def test_warn_captures_errors
    ui = StubConsoleUI.new
    ui.warn "bad"
    assert_equal ["bad"], ui.errors
  end

  def test_running_out_of_answers_raises
    ui = StubConsoleUI.new
    assert_raise(RuntimeError) { ui.ask("Name") }
  end

  def test_read_key_returns_scripted_key
    ui = StubConsoleUI.new(keys: [:up, :enter])
    assert_equal :up, ui.read_key
    assert_equal :enter, ui.read_key
  end
end

class PromptDelegatesToUITest < Test::Unit::TestCase
  def setup
    @previous = UI.current
  end

  def teardown
    UI.current = @previous
  end

  def test_prompt_uses_ui_current
    UI.current = StubConsoleUI.new(answers: ["from-stub"])
    assert_equal "from-stub", prompt("Name")
  end

  def test_prompt_yes_no_uses_ui_current
    UI.current = StubConsoleUI.new(answers: ["yes"])
    assert prompt_yes_no("OK?")
  end

  def test_read_key_uses_ui_current
    UI.current = StubConsoleUI.new(keys: [:enter])
    assert_equal :enter, read_key
  end
end
