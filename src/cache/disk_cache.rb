# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../constants"

# Disk-backed cache. Stores one JSON file per (source, key) under a root
# directory (default `.cache/`, overridable via `LEV_CACHE_DIR`). Entries
# older than the TTL are treated as missing.
class DiskCache
  def initialize(dir: nil, ttl: CACHE_TTL_SECONDS)
    @dir = dir || ENV["LEV_CACHE_DIR"] || DEFAULT_CACHE_DIR
    @ttl = ttl
  end

  attr_reader :dir

  def read(source, key)
    path = path_for(source, key)
    return nil unless fresh?(path)

    data = JSON.parse(File.read(path, encoding: "UTF-8"))
    data["result"]
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  def write(source, key, result)
    return if result.nil?
    return if result.respond_to?(:empty?) && result.empty?

    path = path_for(source, key)
    FileUtils.mkdir_p(File.dirname(path))
    payload = { "cached_at" => Time.now.to_i, "source" => source, "key" => key, "result" => result }
    File.write(path, JSON.pretty_generate(payload))
  rescue StandardError => e
    warn "  Cache write failed (#{source}/#{key}): #{e.message}"
  end

  def clear
    FileUtils.rm_rf(@dir)
  end

  private

  def path_for(source, key)
    File.join(@dir, source, "#{key}.json")
  end

  def fresh?(path)
    File.exist?(path) && (Time.now - File.mtime(path)) < @ttl
  end
end
