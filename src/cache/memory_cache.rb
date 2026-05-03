# frozen_string_literal: true

require_relative "../constants"

# In-memory cache used by the test suite. Empty/nil results are not stored.
class MemoryCache
  def initialize(ttl: CACHE_TTL_SECONDS, clock: -> { Time.now })
    @store = {}
    @ttl = ttl
    @clock = clock
  end

  def read(source, key)
    entry = @store[[source, key]]
    return nil unless entry
    return nil if (@clock.call - entry[:cached_at]) >= @ttl

    entry[:result]
  end

  def write(source, key, result)
    return if result.nil?
    return if result.respond_to?(:empty?) && result.empty?

    @store[[source, key]] = { cached_at: @clock.call, result: result }
  end

  def clear
    @store.clear
  end

  def size
    @store.size
  end
end
