# frozen_string_literal: true

require "socket"

# Helpers for exercising the X (Twitter) OAuth token path: a stubbed token
# endpoint for the ordinary response cases, and a real listening socket for the
# case the timeouts exist for — an endpoint that accepts the connection and then
# goes silent.
#
# The silent case cannot be reproduced by stubbing Net::HTTP, because the bound
# is enforced by the socket rather than by anything Ruby-visible on the request.
module XOauthTestHelpers
  # Runs the block with the URL of a TCP server that accepts connections and
  # sends nothing back, so a read against it blocks until the read timeout fires.
  #
  # Nothing calls accept: the kernel completes the handshake from the listen
  # backlog on its own, so the connection establishes and the client then waits
  # on a response that never comes. That leaves no acceptor thread to race the
  # close against, and no accepted socket to leak.
  def with_hanging_token_endpoint
    server = TCPServer.new("127.0.0.1", 0)
    yield "http://127.0.0.1:#{server.addr[1]}/2/oauth2/token"
  ensure
    server&.close
  end

  # Stubs Net::HTTP.new so refresh!/exchange hit a fake endpoint, returning the
  # caller block's result plus the captured Net::HTTP::Post request (for header/
  # body assertions). The connect/read bounds set on the way are readable
  # afterwards through observed_timeouts.
  def with_token_endpoint(code:, body:)
    captured = nil
    response = Net::HTTPResponse.new("1.1", code.to_s, "")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns(body.is_a?(String) ? body : body.to_json)
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |v| @open_timeout = v }
    mock_http.define_singleton_method(:read_timeout=) { |v| @read_timeout = v }
    mock_http.define_singleton_method(:timeouts) { [ @open_timeout, @read_timeout ] }
    mock_http.define_singleton_method(:request) { |req| captured = req; response }
    # Assigned before the block runs, so a block that raises still leaves
    # observed_timeouts answerable rather than masking the failure with a
    # NoMethodError on nil.
    @last_http = mock_http
    result = Net::HTTP.stub(:new, mock_http) { yield }
    [ result, captured ]
  end

  # The [connect, read] bounds the last with_token_endpoint call observed.
  def observed_timeouts
    @last_http.timeouts
  end

  # Seconds of wall clock the block took, off the monotonic clock.
  def elapsed_seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Shortens the bound so a hanging-endpoint test finishes in about a second
  # instead of ten. The production value is asserted separately.
  def with_token_request_timeout(seconds)
    original = XOauthCredential::TOKEN_REQUEST_TIMEOUT
    swap_const(:TOKEN_REQUEST_TIMEOUT, seconds)
    yield
  ensure
    swap_const(:TOKEN_REQUEST_TIMEOUT, original)
  end

  # XOauthBootstrap reads the token endpoint off the constant rather than a
  # column, so a bootstrap test that needs a real socket has to swap it.
  def with_default_token_endpoint(url)
    original = XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    swap_const(:DEFAULT_TOKEN_ENDPOINT, url)
    yield
  ensure
    swap_const(:DEFAULT_TOKEN_ENDPOINT, original)
  end

  private

  # Parallel test workers are processes, so this swap is process-local, and
  # tests within a worker run one at a time.
  def swap_const(name, value)
    XOauthCredential.send(:remove_const, name)
    XOauthCredential.const_set(name, value)
  end
end
