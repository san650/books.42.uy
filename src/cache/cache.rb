# frozen_string_literal: true

require "digest"
require_relative "memory_cache"
require_relative "disk_cache"

# Cache key derivation: ISBN-10/13 strings are normalized; everything else
# is hashed via SHA-1.
def cache_key(query)
  cleaned = query.to_s.gsub(/[\s\-]/, "")
  if cleaned =~ /\A(\d{9}[\dXx]|\d{13})\z/
    cleaned.upcase
  else
    Digest::SHA1.hexdigest(query.to_s.strip.downcase)
  end
end

# Singleton holder for the active cache. Production defaults to DiskCache;
# tests swap to MemoryCache via `Cache.default = MemoryCache.new`.
module Cache
  class << self
    attr_writer :default

    def default
      @default ||= DiskCache.new
    end
  end
end

# `cached(source, query) { ... }` — fetch from the cache or compute. Empty
# / nil results are not stored.
def cached(source, query, cache: Cache.default)
  key = cache_key(query)
  hit = cache.read(source, key)
  if hit
    warn "  [cache] #{source} hit (#{key[0, 12]})"
    return hit
  end

  result = yield
  cache.write(source, key, result)
  result
end
