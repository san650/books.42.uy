# frozen_string_literal: true

require_relative "constants"

def load_publishers
  return [] unless File.exist?(PUBLISHERS_PATH)

  File.readlines(PUBLISHERS_PATH, chomp: true).reject(&:empty?).sort
end

def add_publisher(name)
  publishers = load_publishers
  return if publishers.any? { |p| p.downcase == name.downcase }

  publishers << name
  File.write(PUBLISHERS_PATH, publishers.sort.join("\n") + "\n")
end

# Match against publishers.txt case-insensitively; return the canonical
# spelling if found, otherwise return the input as-is.
def sanitize_publisher(name)
  return name if name.nil? || name.to_s.strip.empty?

  match = load_publishers.find { |p| p.downcase == name.to_s.strip.downcase }
  match || name.to_s.strip
end
