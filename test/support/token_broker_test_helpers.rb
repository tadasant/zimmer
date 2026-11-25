# frozen_string_literal: true

# Catalog entries and setup shared by the token broker's tests.
module TokenBrokerTestHelpers
  # Every test that includes this starts with the broker OFF, whatever the
  # process inherited, and says so when it needs it on.
  def self.included(base)
    base.setup do
      @saved_token_broker_enabled = ENV[TokenBroker::ENABLED_ENV]
      ENV.delete(TokenBroker::ENABLED_ENV)
    end
    base.teardown do
      @saved_token_broker_enabled.nil? ? ENV.delete(TokenBroker::ENABLED_ENV) : ENV[TokenBroker::ENABLED_ENV] = @saved_token_broker_enabled
    end
  end

  def turn_token_broker_on = ENV[TokenBroker::ENABLED_ENV] = "true"

  def turn_token_broker_off = ENV.delete(TokenBroker::ENABLED_ENV)

  # A strad entry as the catalog writes them today: the static key header.
  def static_strad_entry(slug)
    {
      "type" => "streamable-http",
      "url" => "#{FakeStrad::ORIGIN}/mcp?servers=#{slug}",
      "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
    }
  end

  # The same entry opted into brokered auth. It keeps the static header, as an
  # entry may during cutover, to prove the header is never what a session gets.
  def brokered_strad_entry(slug, **extra)
    static_strad_entry(slug).merge("brokered_auth" => { "scopes" => [ "slug:#{slug}" ] }.merge(extra.transform_keys(&:to_s)))
  end

  # Stub the MCP catalog with `entries` (name => config). Other artifact types
  # resolve empty.
  def stub_mcp_catalog(entries)
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(entries)
  end
end
