# frozen_string_literal: true

require "net/http"

module ParameterStore
  # The one place a real HTTP request leaves Zimmer for GCP.
  #
  # Extracted behind an object so tests can substitute an in-memory Parameter
  # Manager / Secret Manager (test/support/fake_parameter_store.rb) and exercise
  # the PRODUCTION client against it — the client under test stays real, only the
  # network is faked.
  class HttpTransport
    # Every call is bounded. A request that hangs is worse than one that fails:
    # the snapshot cache can serve stale values around a rejection, but a
    # never-settling call pins every reader waiting behind its single flight.
    DEFAULT_TIMEOUT = 10

    def initialize(timeout: DEFAULT_TIMEOUT)
      @timeout = timeout
    end

    # @return [Array(Integer, String)] [status, body]
    def request(method, url, headers, body)
      uri = URI(url)
      klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post }.fetch(method)
      request = klass.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body if body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.request(request)
      end

      [ response.code.to_i, response.body.to_s ]
    end
  end
end
