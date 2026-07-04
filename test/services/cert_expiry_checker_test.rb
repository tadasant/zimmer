# frozen_string_literal: true

require "test_helper"
require "socket"
require "openssl"

class CertExpiryCheckerTest < ActiveSupport::TestCase
  test "reads the served certificate's expiry and computes days remaining" do
    not_after = Time.now.utc + (40 * 86_400)
    server = start_tls_server(not_after: not_after)
    begin
      result = CertExpiryChecker.new(timeout: 5).check("127.0.0.1", port: server[:port])

      assert result.ok?, "expected a successful read, got error: #{result.error}"
      assert_in_delta not_after.to_i, result.not_after.to_i, 5
      assert_includes [ 39, 40 ], result.days_remaining
    ensure
      stop_tls_server(server)
    end
  end

  test "reports negative days remaining for an already-expired certificate" do
    not_after = Time.now.utc - (3 * 86_400)
    server = start_tls_server(not_after: not_after)
    begin
      result = CertExpiryChecker.new(timeout: 5).check("127.0.0.1", port: server[:port])

      assert result.ok?, "an expired cert should still be readable, got error: #{result.error}"
      assert_operator result.days_remaining, :<=, -3
    ensure
      stop_tls_server(server)
    end
  end

  test "captures connection/handshake errors instead of raising" do
    # A plain (non-TLS) server makes the TLS handshake fail deterministically,
    # with no port-reuse race.
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    thread = Thread.new do
      conn = tcp.accept
      conn.close
    rescue IOError
      nil
    end

    begin
      result = CertExpiryChecker.new(timeout: 5).check("127.0.0.1", port: port)

      refute result.ok?
      assert result.error.present?, "expected an error message"
      assert_nil result.days_remaining
      assert_nil result.not_after
    ensure
      tcp.close
      thread.join(2)
    end
  end

  test "uses the injected clock when computing days remaining" do
    not_after = Time.now.utc + (40 * 86_400)
    server = start_tls_server(not_after: not_after)
    begin
      # X509 notAfter has whole-second resolution, so the parsed value differs
      # from the pre-truncation timestamp by a sub-second amount. Read it back
      # and anchor the clock exactly 10 days before it for deterministic math.
      parsed_not_after = CertExpiryChecker.new(timeout: 5).check("127.0.0.1", port: server[:port]).not_after
      frozen_now = parsed_not_after - (10 * 86_400)
      checker = CertExpiryChecker.new(timeout: 5, clock: -> { frozen_now })
      result = checker.check("127.0.0.1", port: server[:port])

      assert result.ok?, "expected a successful read, got error: #{result.error}"
      assert_equal 10, result.days_remaining
    ensure
      stop_tls_server(server)
    end
  end

  private

  def start_tls_server(not_after:)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    name = OpenSSL::X509::Name.parse("/CN=test.local")
    cert.subject = name
    cert.issuer = name
    cert.public_key = key.public_key
    cert.not_before = Time.now.utc - 86_400
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new("SHA256"))

    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = cert
    ctx.key = key

    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    ssl_server = OpenSSL::SSL::SSLServer.new(tcp, ctx)

    thread = Thread.new do
      loop do
        conn = ssl_server.accept
        conn.close
      rescue OpenSSL::SSL::SSLError, IOError, Errno::EBADF
        break
      end
    end

    { ssl_server: ssl_server, tcp: tcp, thread: thread, port: port }
  end

  def stop_tls_server(server)
    server[:ssl_server].close
  rescue IOError
    nil
  ensure
    server[:thread]&.join(2)
  end
end
