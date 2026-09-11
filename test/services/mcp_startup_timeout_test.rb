# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The MCP startup budget: one default for every server, and the per-server
# override a catalog entry can declare ([#113](https://github.com/tadasant/zimmer/issues/113)).
class McpStartupTimeoutTest < ActiveSupport::TestCase
  # Put a server into the catalog ServersConfig reads, carrying whatever the test
  # needs it to declare. `.find` is `.all.find`, so this one seam covers both.
  def catalog!(name, raw_value)
    entry = { "type" => "stdio", "command" => "npx", "args" => [ "-y", "@acme/mcp" ] }
    entry[McpStartupTimeout::CATALOG_KEY] = raw_value unless raw_value == :undeclared
    others = ServersConfig.all.reject { |server| server.name == name }
    ServersConfig.stubs(:all).returns(others + [ ServersConfig::Server.new(name, entry) ])
  end

  # ---------------------------------------------------------------------------
  # The default
  # ---------------------------------------------------------------------------

  test "the two units are the same number" do
    assert_equal 180, McpStartupTimeout::SECONDS
    assert_equal 180_000, McpStartupTimeout::MILLISECONDS
    assert_equal McpStartupTimeout::SECONDS * 1000, McpStartupTimeout::MILLISECONDS
  end

  test "a server the catalog says nothing about declares nothing" do
    catalog!("quiet", :undeclared)

    assert_empty McpStartupTimeout.declared_seconds_map([ "quiet" ])
  end

  test "a server the catalog does not know at all declares nothing" do
    assert_empty McpStartupTimeout.declared_seconds_map([ "no-such-server" ])
    assert_empty McpStartupTimeout.declared_seconds_map([ nil, "" ])
    assert_empty McpStartupTimeout.declared_seconds_map(nil)
    assert_empty McpStartupTimeout.declared_seconds_map([])
  end

  # ---------------------------------------------------------------------------
  # A declared value
  # ---------------------------------------------------------------------------

  test "a declared value is read back, and only for the names asked about" do
    catalog!("fast", 15)

    assert_equal({ "fast" => 15 }, McpStartupTimeout.declared_seconds_map([ "fast" ]))
    assert_empty McpStartupTimeout.declared_seconds_map([ "someone-else" ])
  end

  test "a declared value may be longer than the default" do
    catalog!("slow", 420)

    assert_equal({ "slow" => 420 }, McpStartupTimeout.declared_seconds_map([ "slow" ]))
  end

  test "the catalog is read once however many names are asked about" do
    fast = ServersConfig::Server.new("fast", { "type" => "stdio", "command" => "npx", McpStartupTimeout::CATALOG_KEY => 15 })
    ServersConfig.expects(:all).once.returns([ fast ])

    assert_equal({ "fast" => 15 },
      McpStartupTimeout.declared_seconds_map([ "fast", "b", "c", "d", "e" ]))
  end

  test "the bounds are inclusive" do
    assert_equal McpStartupTimeout::MIN_SECONDS,
      McpStartupTimeout.normalize(McpStartupTimeout::MIN_SECONDS, server_name: "edge")
    assert_equal McpStartupTimeout::MAX_SECONDS,
      McpStartupTimeout.normalize(McpStartupTimeout::MAX_SECONDS, server_name: "edge")
  end

  # ---------------------------------------------------------------------------
  # A value Zimmer cannot honor
  # ---------------------------------------------------------------------------

  test "a value outside the bounds is ignored and the default applies" do
    [ McpStartupTimeout::MIN_SECONDS - 1, McpStartupTimeout::MAX_SECONDS + 1, 0, -30 ].each do |value|
      catalog!("out-of-range", value)

      assert_empty McpStartupTimeout.declared_seconds_map([ "out-of-range" ]), "#{value} should be ignored"
      assert_equal McpStartupTimeout::SECONDS, McpStartupTimeout.ceiling_seconds([ "out-of-range" ])
    end
  end

  test "a value that is not an integer is ignored rather than coerced" do
    [ "60", 60.0, 1.5, true, [ 60 ], { "seconds" => 60 } ].each do |value|
      catalog!("wrong-type", value)

      assert_empty McpStartupTimeout.declared_seconds_map([ "wrong-type" ]), "#{value.inspect} should be ignored"
    end
  end

  test "an ignored value is logged, because its author is in another repository" do
    Rails.logger.expects(:warn).with { |message| message.include?("startup_timeout_sec=900") && message.include?("\"loud\"") }

    McpStartupTimeout.normalize(900, server_name: "loud")
  end

  test "a missing declaration is silent" do
    Rails.logger.expects(:warn).never

    assert_nil McpStartupTimeout.normalize(nil, server_name: "quiet")
  end

  # ---------------------------------------------------------------------------
  # The ceiling — Claude's single MCP_TIMEOUT
  # ---------------------------------------------------------------------------

  test "the ceiling over no servers is the flat default" do
    assert_equal McpStartupTimeout::SECONDS, McpStartupTimeout.ceiling_seconds([])
    assert_equal McpStartupTimeout::MILLISECONDS, McpStartupTimeout.ceiling_milliseconds([])
    assert_equal McpStartupTimeout::SECONDS, McpStartupTimeout.ceiling_seconds(nil)
  end

  test "the ceiling is the longest budget any server asks for" do
    slow = ServersConfig::Server.new("slow", { "type" => "stdio", "command" => "npx", McpStartupTimeout::CATALOG_KEY => 300 })
    fast = ServersConfig::Server.new("fast", { "type" => "stdio", "command" => "npx", McpStartupTimeout::CATALOG_KEY => 15 })
    ServersConfig.stubs(:all).returns([ slow, fast ])

    assert_equal 300, McpStartupTimeout.ceiling_seconds([ "fast", "slow" ])
    assert_equal 300_000, McpStartupTimeout.ceiling_milliseconds([ "slow", "fast", "unknown" ])
  end

  test "the ceiling never drops below the flat default, however fast the servers claim to be" do
    fast = ServersConfig::Server.new("fast", { "type" => "stdio", "command" => "npx", McpStartupTimeout::CATALOG_KEY => 15 })
    ServersConfig.stubs(:all).returns([ fast ])

    assert_equal McpStartupTimeout::SECONDS, McpStartupTimeout.ceiling_seconds([ "fast" ]),
      "Claude's MCP_TIMEOUT covers every server at once, so shortening it for one would shorten it for all"
  end

  test "a catalog that cannot be resolved leaves the default standing" do
    ServersConfig.stubs(:all).returns([])

    assert_equal McpStartupTimeout::SECONDS, McpStartupTimeout.ceiling_seconds([ "anything" ])
    assert_empty McpStartupTimeout.declared_seconds_map([ "anything" ])
  end
end
