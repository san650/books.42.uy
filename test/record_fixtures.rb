#!/usr/bin/env ruby
# frozen_string_literal: true

# record_fixtures.rb — One-shot script to capture real responses from the
# external services and write them to test/fixtures/. Wraps DEFAULT_HTTP
# with a recording proxy so every URL hit is mirrored to disk under a
# stable, content-derived filename.
#
# Usage:
#   ruby test/record_fixtures.rb
#
# Re-run any time the fixture set needs refreshing. The captured files
# replace whatever was there before.

require_relative "../scripts/common"
require_relative "../scripts/lookup"
require "digest"

FIXTURES_DIR = File.expand_path("fixtures", __dir__)
INDEX_PATH = File.join(FIXTURES_DIR, "index.json")

# Fixture set — extend this list when new lookups need coverage.
FIXTURE_QUERIES = [
  { kind: :isbn, query: "9788445078259", label: "cronicas_marcianas" },
  { kind: :text, query: "the martian chronicles bradbury", label: "martian_chronicles_text" }
].freeze

# Recording HTTP client — delegates to the real client, then writes each
# response body to disk and updates the index.
class RecordingHttpClient
  def initialize(real, sink)
    @real = real
    @sink = sink
  end

  def get(url, headers: {}, **opts)
    response = @real.get(url, headers: headers, **opts)
    @sink.record(url, response, kind: :raw)
    response
  end

  def get_json(url)
    body = @real.get_json(url)
    if body
      synthetic = FakeResponseLike.new(JSON.generate(body))
      @sink.record(url, synthetic, kind: :json)
    end
    body
  end

  def get_with_retry(url, headers: {}, **opts)
    response = @real.get_with_retry(url, headers: headers, **opts)
    @sink.record(url, response, kind: :raw)
    response
  end

  def download(url, dest)
    @real.download(url, dest)
  end
end

# Used to coerce parsed JSON responses back into something the sink can
# write — we don't have the original body string, so we re-encode.
class FakeResponseLike
  attr_reader :code, :body

  def initialize(body)
    @code = "200"
    @body = body
  end

  def [](_)
    nil
  end
end

class FixtureSink
  def initialize(dir)
    @dir = dir
    @entries = {}
    FileUtils.mkdir_p(dir)
  end

  def record(url, response, kind:)
    return unless response

    code = response.code
    body = response.body.to_s
    return if body.empty?

    digest = Digest::SHA1.hexdigest(url)[0, 16]
    ext = case kind
          when :json then "json"
          else infer_ext(url, body)
          end
    rel_path = File.join(host_segment(url), "#{digest}.#{ext}")
    abs_path = File.join(@dir, rel_path)
    FileUtils.mkdir_p(File.dirname(abs_path))
    File.write(abs_path, body)

    @entries[url] = { "code" => code, "path" => rel_path, "kind" => kind.to_s }
    warn "  recorded: #{rel_path} (#{url[0, 80]})"
  end

  def write_index!(path)
    File.write(path, JSON.pretty_generate(@entries.sort.to_h))
    warn "Wrote index with #{@entries.size} entries: #{path}"
  end

  private

  def host_segment(url)
    URI(url).host.to_s.gsub(/[^a-z0-9.\-]/i, "_")
  end

  def infer_ext(url, body)
    return "json" if body.lstrip.start_with?("{", "[")
    return "html" if body.include?("<html") || body.include?("<!doctype")
    "txt"
  end
end

def main
  # Force a fresh in-memory cache so the recorder always hits the network.
  Cache.default = MemoryCache.new

  FileUtils.mkdir_p(FIXTURES_DIR)
  sink = FixtureSink.new(FIXTURES_DIR)
  recording = RecordingHttpClient.new(DEFAULT_HTTP, sink)

  FIXTURE_QUERIES.each do |entry|
    warn "\n=== Recording #{entry[:label]} (#{entry[:query]}) ==="
    case entry[:kind]
    when :isbn then lookup_isbn(entry[:query], http: recording)
    when :text then lookup_text(entry[:query], http: recording)
    end
  end

  sink.write_index!(INDEX_PATH)
end

main if $PROGRAM_NAME == __FILE__
