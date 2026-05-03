# frozen_string_literal: true

# test_helper.rb — boots Test::Unit, redirects the cache to memory, and
# loads the FakeHttpClient. Every test file requires this first.

require "test/unit"
require "fileutils"
require "tmpdir"
require "json"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "scripts"))
$LOAD_PATH.unshift(File.join(ROOT, "test"))

require "common"
require "lookup"
require "book_form"
require "add_book"
require "edit_book"

require "fakes/fake_http_client"

# Tests must never write to the project's real .cache/ or db.json. Swap the
# cache for an in-memory implementation by default; tests that exercise the
# disk cache create their own DiskCache pointed at a temp dir.
Cache.default = MemoryCache.new

FIXTURES_DIR = File.join(ROOT, "test", "fixtures")
FIXTURES_INDEX = File.join(FIXTURES_DIR, "index.json")

module FixtureHelpers
  def fixture_path(*parts)
    File.join(FIXTURES_DIR, *parts)
  end

  def read_fixture(*parts)
    File.read(fixture_path(*parts), encoding: "UTF-8")
  end

  def fixture_exists?(*parts)
    File.exist?(fixture_path(*parts))
  end

  # Build a FakeHttpClient pre-stubbed with every URL captured by the
  # recorder. Tests pass this as the http: argument to fetchers.
  def fixture_http_client
    raise "missing #{FIXTURES_INDEX} — run `ruby test/record_fixtures.rb`" unless File.exist?(FIXTURES_INDEX)

    @@fixture_index ||= JSON.parse(File.read(FIXTURES_INDEX))
    fake = FakeHttpClient.new
    @@fixture_index.each do |url, entry|
      body = File.read(File.join(FIXTURES_DIR, entry["path"]), encoding: "UTF-8")
      fake.stub(url, code: entry["code"], body: body)
    end
    fake
  end
end

module CacheHelpers
  def with_memory_cache
    previous = Cache.default
    Cache.default = MemoryCache.new
    yield
  ensure
    Cache.default = previous
  end
end

class Test::Unit::TestCase
  include FixtureHelpers
  include CacheHelpers

  def setup_memory_cache
    Cache.default = MemoryCache.new
  end

  def with_tmp_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end
end
