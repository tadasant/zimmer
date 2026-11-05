# frozen_string_literal: true

require "test_helper"

class Sessions::ActorLabelTest < ActiveSupport::TestCase
  test "names each door the way its log rows read" do
    assert_equal "", Sessions::ActorLabel.for(:web)
    assert_equal " via MCP", Sessions::ActorLabel.for(:mcp)
    assert_equal " via the REST API", Sessions::ActorLabel.for(:rest)
  end

  test "refuses an actor it does not know" do
    assert_raises(KeyError) { Sessions::ActorLabel.for(:api) }
    assert_raises(KeyError) { Sessions::ActorLabel.for(nil) }
    assert_raises(KeyError) { Sessions::ActorLabel.for("web") }
  end
end
