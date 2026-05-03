# frozen_string_literal: true

# ConsoleUI — abstraction over terminal I/O so prompts and key reads can be
# stubbed in tests. UI.current is the swappable global; production code uses
# the default ConsoleUI which talks to $stdin/$stdout/$stderr.

require "io/console"
require "readline"

class ConsoleUI
  def initialize(out: $stdout, err: $stderr, input: $stdin)
    @out = out
    @err = err
    @input = input
  end

  attr_reader :out, :err, :input

  def say(msg = "")
    @out.puts(msg)
  end

  def warn(msg)
    @err.puts(msg)
  end

  def print(msg)
    @out.print(msg)
  end

  # Prompt for a string with optional default and required validation.
  # Returns the entered value, or "" if `clearable` and the user typed "-".
  def ask(label, default: nil, required: false, clearable: false)
    loop do
      suffix = default && !default.to_s.empty? ? " [#{default}]" : ""
      hint = clearable && default && !default.to_s.empty? ? " (- to clear)" : ""
      input = readline("#{label}#{suffix}#{hint}: ")
      raise Interrupt unless input
      input = input.strip

      return "" if clearable && input == "-"
      input = default.to_s if input.empty? && default && !default.to_s.empty?
      return input unless input.to_s.empty? && required

      say "  This field is required."
    end
  end

  def confirm(label, default: "y")
    answer = ask(label, default: default)
    answer.downcase.start_with?("y")
  end

  def readline(prompt_str)
    Readline.readline(prompt_str, false)
  end

  # Read a single keystroke as a symbol (:up, :down, :enter, :space, :ctrl_c)
  # or the lowercase character. Used by interactive_select.
  def read_key
    @input.raw do |io|
      input = io.getc
      if input == "\e"
        if IO.select([io], nil, nil, 0.1)
          input << (io.read_nonblock(2) rescue "")
        end
      end

      case input
      when "\e[A" then :up
      when "\e[B" then :down
      when "\e[C" then :right
      when "\e[D" then :left
      when "\r", "\n" then :enter
      when " " then :space
      when "" then :ctrl_c
      else input.to_s.downcase
      end
    end
  end
end

# Singleton holder for the active UI. Tests assign UI.current = StubConsoleUI.
module UI
  class << self
    attr_writer :current

    def current
      @current ||= ConsoleUI.new
    end
  end
end
