# frozen_string_literal: true

# FakeHttpClient — drop-in replacement for HttpClient that returns canned
# responses keyed by URL. Unmatched URLs raise so tests fail loudly when
# they would have hit the network.

class FakeResponse
  attr_reader :code, :body

  def initialize(code: "200", body: "", headers: {})
    @code = code.to_s
    @body = body
    @headers = headers.transform_keys { |k| k.to_s.downcase }
  end

  def [](name)
    @headers[name.to_s.downcase]
  end
end

class FakeHttpClient
  attr_reader :requests

  def initialize
    @stubs = {}
    @prefix_stubs = []
    @requests = []
  end

  # Register a response for an exact URL.
  def stub(url, code: "200", body: "", headers: {}, parse_json: false)
    response = FakeResponse.new(code: code, body: body, headers: headers)
    @stubs[url] = { response: response, parse_json: parse_json }
    self
  end

  # Register a response for any URL whose prefix matches.
  def stub_prefix(prefix, code: "200", body: "", headers: {}, parse_json: false)
    response = FakeResponse.new(code: code, body: body, headers: headers)
    @prefix_stubs << { prefix: prefix, response: response, parse_json: parse_json }
    self
  end

  def get(url, headers: {}, **_opts)
    record(url, :get, headers)
    lookup_stub(url)[:response]
  end

  def get_json(url)
    record(url, :get_json, {})
    stub = lookup_stub(url)
    response = stub[:response]
    return nil unless response.code == "200"

    JSON.parse(response.body)
  end

  def get_with_retry(url, headers: {}, **_opts)
    record(url, :get_with_retry, headers)
    lookup_stub(url)[:response]
  end

  def download(url, dest)
    record(url, :download, {})
    stub = lookup_stub(url)
    response = stub[:response]
    return false unless response.code == "200"
    return false if response.body.nil? || response.body.empty?

    File.binwrite(dest, response.body)
    true
  end

  private

  def record(url, method, headers)
    @requests << { url: url, method: method, headers: headers }
  end

  def lookup_stub(url)
    return @stubs[url] if @stubs.key?(url)

    match = @prefix_stubs.find { |s| url.start_with?(s[:prefix]) }
    return match if match

    raise "FakeHttpClient: no stub for URL #{url.inspect}\nKnown stubs:\n#{@stubs.keys.join("\n")}"
  end
end
