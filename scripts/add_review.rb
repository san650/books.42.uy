#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../src/add_review"

trap("INT") do
  puts "\nAborted."
  exit 130
end

add_review_cli
