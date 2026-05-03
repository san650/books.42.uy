#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../src/edit_author"

trap("INT") do
  puts "\nAborted."
  exit 130
end

begin
  edit_author_cli
rescue Interrupt
  puts "\n\nCancelled."
  exit 1
rescue StandardError => e
  warn "\nError: #{e.message}"
  warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
  exit 1
end
