# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The SSRF-facing half of CIMD: which client_id URLs may be fetched at all, which
# addresses may be dialled, and how a response is read.
class OauthServer::ClientMetadataDocumentTest < ActiveSupport::TestCase
  Doc = OauthServer::ClientMetadataDocument

  test "url_problem accepts a normal https URL with a path" do
    assert_nil Doc.url_problem("https://claude.ai/oauth/mcp-oauth-client-metadata")
    assert_nil Doc.url_problem("https://example.com:8443/client.json")
  end

  test "url_problem refuses everything else" do
    {
      "http://claude.ai/meta" => "https",
      "https://claude.ai" => "path",
      "https://claude.ai/" => "path",
      "https://user:pw@claude.ai/meta" => "userinfo",
      "https://claude.ai/meta#frag" => "fragment",
      "https://claude.ai/a/./b" => "dot",
      "https://claude.ai/a/../b" => "dot",
      "https://Claude.ai/meta" => "normal form",
      "https://claude.ai:443/meta" => "normal form",
      "https://127.0.0.1/meta" => "non-public",
      "https://[::1]/meta" => "non-public",
      "https://169.254.169.254/latest" => "non-public",
      "https://#{'a' * 1100}.com/x" => "too long"
    }.each do |url, why|
      problem = Doc.url_problem(url)
      assert problem, "#{url} should be refused"
      assert_includes problem, why, url
    end
  end

  test "public_address? blocks private, loopback, link-local, CGNAT and mapped addresses" do
    %w[10.1.2.3 127.0.0.1 169.254.169.254 172.16.0.1 192.168.1.1 100.64.0.1 0.0.0.0 224.0.0.1
      ::1 fe80::1 fc00::1 ::ffff:127.0.0.1 64:ff9b::7f00:1 2001:db8::1].each do |ip|
      refute Doc.public_address?(IPAddr.new(ip)), ip
    end
    %w[8.8.8.8 160.79.104.10 2606:4700::6810:84e5 ::ffff:8.8.8.8].each do |ip|
      assert Doc.public_address?(IPAddr.new(ip)), ip
    end
  end

  test "a name that resolves to any non-public address is refused before connecting" do
    doc = Doc.new("https://rebind.example/meta")
    doc.stubs(:resolve).returns([ IPAddr.new("93.184.216.34"), IPAddr.new("127.0.0.1") ])
    Net::HTTP.any_instance.expects(:start).never

    error = assert_raises(OauthServer::Error) { doc.send(:fetch) }
    assert_equal "invalid_client", error.code
    assert_includes error.description, "non-public"
  end

  test "the connection dials the vetted address, not a second lookup" do
    doc = Doc.new("https://claude.ai/oauth/mcp-oauth-client-metadata")
    doc.stubs(:resolve).returns([ IPAddr.new("160.79.104.10") ])
    Net::HTTP.any_instance.expects(:ipaddr=).with("160.79.104.10")
    Net::HTTP.any_instance.stubs(:start).raises(Errno::ECONNREFUSED)

    assert_raises(OauthServer::Error) { doc.send(:fetch) }
  end

  test "cache lifetime follows max-age, capped at an hour; no-store means none" do
    doc = Doc.allocate
    assert_equal 300.seconds, doc.send(:ttl_from, "public, max-age=300")
    assert_equal 1.hour, doc.send(:ttl_from, "max-age=999999")
    assert_equal 5.minutes, doc.send(:ttl_from, nil)
    assert_equal 0.seconds, doc.send(:ttl_from, "no-store,no-cache,max-age=0")
    assert_equal 0.seconds, doc.send(:ttl_from, "max-age=abc")
  end

  test "only JSON content types are read" do
    doc = Doc.allocate
    assert doc.send(:json_content_type?, "application/json; charset=utf-8")
    assert doc.send(:json_content_type?, "application/oauth-client+json")
    refute doc.send(:json_content_type?, "text/html")
    refute doc.send(:json_content_type?, nil)
  end
end
