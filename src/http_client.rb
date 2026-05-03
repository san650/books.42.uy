# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"
require_relative "constants"

# Low-level HTTP helpers. Accept module-level usage so existing code keeps
# working; HttpClient wraps them for injection points used by fetchers.

def http_get(url, headers: {}, follow_redirects: true, max_redirects: 5)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = HTTP_TIMEOUT
  http.read_timeout = HTTP_TIMEOUT

  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = USER_AGENT
  headers.each { |k, v| request[k] = v }

  response = http.request(request)
  response.body&.force_encoding("UTF-8") if response.body

  if follow_redirects && %w[301 302 303 307 308].include?(response.code) && max_redirects > 0
    location = response["location"]
    if location
      location = URI.join(uri, location).to_s unless location.start_with?("http")
      return http_get(location, headers: headers, follow_redirects: true, max_redirects: max_redirects - 1)
    end
  end

  response
rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
       Errno::ECONNRESET, SocketError, OpenSSL::SSL::SSLError => e
  warn "  Network error: #{e.message}"
  nil
end

def http_get_json(url)
  response = http_get(url)
  return nil unless response&.code == "200"

  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

# Retry on 429 / 5XX / network errors. Honors Retry-After on 429.
def http_get_with_retry(url, headers: {}, retries: 3)
  delay = 1
  attempt = 0

  loop do
    response = http_get(url, headers: headers)
    retryable = response.nil? || response.code == "429" || response.code.start_with?("5")
    return response unless retryable

    attempt += 1
    break response if attempt > retries

    wait = if response && response.code == "429" && response["retry-after"] =~ /\A\d+\z/
             response["retry-after"].to_i
           else
             delay
           end

    reason = response ? "HTTP #{response.code}" : "network error"
    warn "  #{reason} — retrying in #{wait}s (attempt #{attempt}/#{retries})..."
    sleep wait
    delay *= 2
  end
end

def http_download(url, dest)
  response = http_get(url)
  return false unless response&.code == "200"
  return false if response.body.nil? || response.body.empty?

  content_type = response["content-type"].to_s
  return false if content_type.include?("text/html")

  File.open(dest, "wb") { |f| f.write(response.body) }
  true
rescue StandardError => e
  warn "  Download error: #{e.message}"
  false
end

# Object wrapper around the helpers above. Each fetcher takes `http: DEFAULT_HTTP`
# so tests can pass FakeHttpClient instead.
class HttpClient
  def get(url, headers: {}, follow_redirects: true, max_redirects: 5)
    http_get(url, headers: headers, follow_redirects: follow_redirects, max_redirects: max_redirects)
  end

  def get_json(url)
    http_get_json(url)
  end

  def get_with_retry(url, headers: {}, retries: 3)
    http_get_with_retry(url, headers: headers, retries: retries)
  end

  def download(url, dest)
    http_download(url, dest)
  end
end

DEFAULT_HTTP = HttpClient.new
