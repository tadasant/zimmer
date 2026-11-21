# frozen_string_literal: true

# Catalog entries and setup shared by the token broker's tests.
module TokenBrokerTestHelpers
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
