# frozen_string_literal: true

require "test_helper"

class RootData::NamespaceTest < ActiveSupport::TestCase
  include RootDataHelpers

  test "resolves to the root's canonical name" do
    stub_root_data_catalog(root_data_root("zimmer"))
    resolved = RootData::Namespace.for_session_id(root_data_session("zimmer").id)

    assert_equal "zimmer", resolved.namespace
    assert_equal "zimmer", resolved.root.name
  end

  test "a declared data_namespace wins, so two roots can share one store" do
    stub_root_data_catalog(root_data_root("a", data_namespace: "shared"), root_data_root("b", data_namespace: "shared"))

    assert_equal "shared", RootData::Namespace.for_session_id(root_data_session("a").id).namespace
    assert_equal "shared", RootData::Namespace.for_session_id(root_data_session("b").id).namespace
  end

  test "the router alias resolves to the preferred router root, config and name" do
    stub_root_data_catalog(
      root_data_root("zimmer-orchestrator", data_collections: { "notes" => {} }),
      root_data_root("zimmer-router")
    )
    resolved = RootData::Namespace.for_session_id(root_data_session("zimmer-router").id)

    assert_equal "zimmer-orchestrator", resolved.namespace
    assert_equal [ "notes" ], RootData::Collections.declared(resolved.root).keys
  end

  test "the router alias alone still maps to the preferred name" do
    stub_root_data_catalog(root_data_root("zimmer-router"))
    assert_equal "zimmer-orchestrator", RootData::Namespace.for_session_id(root_data_session("zimmer-router").id).namespace
  end

  test "refuses without a session, without an agent_root_key, or with a root the catalog lacks" do
    stub_root_data_catalog(root_data_root("zimmer"))

    assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(nil) }
    assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(0) }

    session = sessions(:running)
    session.update_columns(metadata: (session.metadata || {}).except("agent_root_key"))
    error = assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(session.id) }
    assert_match(/not started from an agent root/, error.message)

    error = assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(root_data_session("gone").id) }
    assert_match(/not in the catalog/, error.message)
  end

  test "never falls back to matching the session's repository" do
    stub_root_data_catalog(root_data_root("zimmer"))
    session = sessions(:running)
    session.update_columns(metadata: {}, git_root: "https://github.com/tadasant/zimmer.git", subdirectory: nil)

    assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(session.id) }
  end

  test "refuses an invalid declared data_namespace" do
    stub_root_data_catalog(root_data_root("zimmer", data_namespace: "Not Valid!"))
    assert_raises(RootData::Namespace::Unresolvable) { RootData::Namespace.for_session_id(root_data_session("zimmer").id) }
  end
end
