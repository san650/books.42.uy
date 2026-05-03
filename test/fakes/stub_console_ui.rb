# frozen_string_literal: true

# StubConsoleUI — replacement for ConsoleUI in tests. Captures all output
# and serves prompt/key inputs from queues. Tests assign UI.current to an
# instance, then read messages/errors after the unit under test runs.

class StubConsoleUI
  attr_reader :messages, :errors, :prompts, :prompt_log

  def initialize(answers: [], keys: [])
    @answers = answers.dup
    @keys = keys.dup
    @messages = []
    @errors = []
    @prompt_log = []
  end

  def say(msg = "")
    @messages << msg.to_s
  end

  def warn(msg)
    @errors << msg.to_s
  end

  def print(msg)
    @messages << msg.to_s
  end

  def ask(label, default: nil, required: false, clearable: false)
    @prompt_log << { label: label, default: default, required: required, clearable: clearable }
    raise "StubConsoleUI: no scripted answer for #{label.inspect}" if @answers.empty?

    @answers.shift
  end

  def confirm(label, default: "y")
    answer = ask(label, default: default)
    answer.to_s.downcase.start_with?("y")
  end

  def readline(_prompt)
    raise "StubConsoleUI: no scripted answer (readline)" if @answers.empty?

    @answers.shift
  end

  def read_key
    raise "StubConsoleUI: no scripted key" if @keys.empty?

    @keys.shift
  end
end
