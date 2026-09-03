# frozen_string_literal: true

require "socket"

# Helpers for exercising the X (Twitter) OAuth token path against a token
# endpoint that accepts a connection and then never answers.
#
# This is the failure mode the timeouts exist for: Net::HTTP's 60-second default
# read timeout is applied PER READ, so a server that dribbles bytes (or, as here,
# sends nothing at all) can hold the caller's thread far longer than any single
# bound suggests. Stubbing Net::HTTP cannot reproduce it — the timeout is
# enforced by the socket — so these helpers open a real listening socket.
module XOauthTestHelpers
  # Runs the block with the URL of a TCP server that completes the handshake and
  # then stays silent, so a read against it blocks until the read timeout fires.
  def with_hanging_token_endpoint
    server = TCPServer.new("127.0.0.1", 0)
    connections = []
    acceptor = Thread.new do
      loop do
        connections << server.accept
      rescue IOError, Errno::EBADF, Errno::ECONNABORTED
        break
      end
    end

    yield "http://127.0.0.1:#{server.addr[1]}/2/oauth2/token"
  ensure
    acceptor&.kill
    connections&.each { |socket| socket.close rescue nil }
    server&.close
  end

  # Seconds of wall clock the block took, off the monotonic clock.
  def elapsed_seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Temporarily shortens the bound so a hanging-endpoint test finishes in about a
  # second instead of ten. The production value is asserted separately.
  def with_token_request_timeout(seconds)
    original = XOauthCredential::TOKEN_REQUEST_TIMEOUT
    swap_token_request_timeout(seconds)
    yield
  ensure
    swap_token_request_timeout(original)
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

  def swap_const(name, value)
    XOauthCredential.send(:remove_const, name)
    XOauthCredential.const_set(name, value)
  end

  def swap_token_request_timeout(value)
    swap_const(:TOKEN_REQUEST_TIMEOUT, value)
  end
end
