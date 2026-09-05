require "test_helper"
require "mocha/minitest"

class Sessions::UpdateCatalogSelectionTest < ActiveSupport::TestCase
  def make_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      **attrs
    )
  end

  def call(session, attribute, values, actor: :web)
    Sessions::UpdateCatalogSelection.call(session: session, attribute: attribute, values: values, actor: actor)
  end

  # --- The table every surface reads -----------------------------------------

  test "the catalog-selection table names all four session artifact lists" do
    assert_equal %i[mcp_servers catalog_skills catalog_hooks catalog_plugins],
      Session::CATALOG_SELECTIONS.keys
  end

  test "the MCP tool's catalog-list table is the same table minus mcp_servers" do
    assert_equal Session::CATALOG_SELECTIONS.except(:mcp_servers), Mcp::Tool::CATALOG_LISTS
    assert Mcp::Tool::CATALOG_LISTS.frozen?, "a shared constant that can be mutated in place fails silently"
  end

  # Two tables name the same four columns for different reasons: this one holds
  # what a *write* needs (bounds, labels, the catalog reader), and
  # CatalogArtifactReferences holds what *validation and healing* need. They are
  # allowed to differ in what they carry; they are not allowed to disagree about
  # which columns exist or which catalog decides an id.
  test "the write table and the model's catalog references agree on columns and catalogs" do
    references = Session.catalog_artifact_references.index_by(&:attribute)

    assert_equal references.keys.sort, Session::CATALOG_SELECTIONS.keys.sort
    Session::CATALOG_SELECTIONS.each do |attribute, spec|
      assert_equal references.fetch(attribute).config_name, spec[:config],
        "#{attribute} is validated against one catalog and written against another"
    end
  end

  test "an unknown attribute is a programming error, not a rejected request" do
    assert_raises(ArgumentError) { call(make_session, :not_an_artifact_list, []) }
  end

  # --- Normalization ---------------------------------------------------------

  test "normalize drops blanks and truncates to the id length cap" do
    values, invalid = Sessions::UpdateCatalogSelection.normalize(
      :mcp_servers, [ "context7", "", "   ", "  playwright-custom  ", "z" * 150 ]
    )

    assert_equal [ "context7", "playwright-custom", "z" * Session::MAX_CATALOG_SELECTION_ID_LENGTH ], values
    assert_equal [ "z" * Session::MAX_CATALOG_SELECTION_ID_LENGTH ], invalid
  end

  test "valid_ids reads names for servers and ids for the catalog artifacts" do
    assert_includes Sessions::UpdateCatalogSelection.valid_ids(:mcp_servers), "context7"
    assert_includes Sessions::UpdateCatalogSelection.valid_ids(:catalog_hooks), "git-push-ci-reminder"
  end

  # --- The write ------------------------------------------------------------

  test "a successful call persists the list and reports the delta" do
    session = make_session(mcp_servers: [ "context7" ])

    result = call(session, :mcp_servers, [ "playwright-custom" ])

    assert result.ok?
    assert_equal [ "playwright-custom" ], session.reload.mcp_servers
    assert_equal [ "playwright-custom" ], result.added
    assert_equal [ "context7" ], result.removed
  end

  test "clearing mcp_servers is recorded as deliberate" do
    session = make_session(mcp_servers: [ "context7" ])

    assert call(session, :mcp_servers, []).ok?

    assert session.reload.mcp_servers_explicitly_empty?
  end

  test "clearing a catalog list is not recorded as a deliberate mcp_servers choice" do
    session = make_session(catalog_skills: [ SkillsConfig.names.first ])

    assert call(session, :catalog_skills, []).ok?

    refute session.reload.mcp_servers_explicitly_empty?
  end

  test "a removed server's status is forgotten so a later prepare does not report a loss" do
    session = make_session(mcp_servers: [ "context7", "playwright-custom" ])
    session.update!(custom_metadata: {
      "mcp_servers_status" => {
        "context7" => { "status" => "connected" },
        "playwright-custom" => { "status" => "connected" }
      }
    })

    assert call(session, :mcp_servers, [ "context7" ]).ok?

    statuses = session.reload.custom_metadata["mcp_servers_status"]
    assert statuses.key?("context7")
    refute statuses.key?("playwright-custom"), "a deliberate removal is not an unexplained loss"
  end

  # --- Rejections ------------------------------------------------------------

  test "a list over the cap is rejected without touching the session" do
    session = make_session(mcp_servers: [ "context7" ])

    result = call(session, :mcp_servers, Array.new(51, "context7"))

    refute result.ok?
    assert_equal :too_many, result.error_code
    assert_equal "Too many MCP servers (maximum 50)", result.error
    assert_equal [ "context7" ], session.reload.mcp_servers
  end

  test "an id the catalog does not know is rejected and named" do
    session = make_session(catalog_hooks: [])

    result = call(session, :catalog_hooks, [ "not-a-hook" ])

    refute result.ok?
    assert_equal :invalid_entries, result.error_code
    assert_equal [ "not-a-hook" ], result.invalid
    assert_equal "Invalid catalog hooks: not-a-hook", result.error
    assert_equal [], session.reload.catalog_hooks
  end

  test "a write the model rejects comes back as a validation failure, not as a success" do
    session = make_session(mcp_servers: [ "context7" ])
    Session.any_instance.stubs(:update).returns(false)
    Session.any_instance.stubs(:errors).returns(
      ActiveModel::Errors.new(session).tap { |e| e.add(:mcp_servers, "is not acceptable") }
    )

    result = call(session, :mcp_servers, [ "playwright-custom" ])

    refute result.ok?
    assert_equal :update_failed, result.error_code
    assert_includes result.error, "is not acceptable"
  end

  test "a log row that cannot be written does not turn a completed write into a failure" do
    session = make_session(mcp_servers: [])
    session.logs.stubs(:create!).raises(ActiveRecord::StatementInvalid, "logs table gone")

    result = call(session, :mcp_servers, [ "context7" ])

    assert result.ok?, "the selection was saved; a log row is not what the caller asked for"
    assert_equal [ "context7" ], session.reload.mcp_servers
  end

  test "a dropped connection is reported as unavailable, not as a rejected request" do
    session = make_session(mcp_servers: [])
    Session.any_instance.stubs(:update).raises(ActiveRecord::ConnectionNotEstablished, "boom")
    Sessions::UpdateCatalogSelection.any_instance.stubs(:sleep)

    result = call(session, :mcp_servers, [ "context7" ])

    refute result.ok?
    assert_equal :database_unavailable, result.error_code
  end

  # --- The log row -----------------------------------------------------------

  test "the log sentence names the surface the change came through" do
    { web: "MCP servers updated (added: context7)",
      api: "MCP servers updated via API (added: context7)",
      mcp: "MCP servers updated via MCP (added: context7)" }.each do |actor, expected|
      session = make_session(mcp_servers: [])

      assert call(session, :mcp_servers, [ "context7" ], actor: actor).ok?

      assert_equal expected, session.reload.logs.last.content
    end
  end

  test "an unchanged list writes no log row" do
    session = make_session(mcp_servers: [ "context7" ])

    assert_no_difference "session.logs.count" do
      assert call(session, :mcp_servers, [ "context7" ]).ok?
    end
  end

  # --- Regeneration policy ---------------------------------------------------

  test "no attribute regenerates the session's runtime config" do
    Dir.mktmpdir do |dir|
      AirPrepareService.any_instance.expects(:prepare!).never
      McpOauthCredentialInjector.any_instance.stubs(:check_credentials_status).returns({})

      session = make_session(metadata: { "working_directory" => dir })

      assert call(session, :mcp_servers, [ "context7" ]).ok?
      assert call(session, :catalog_skills, [ SkillsConfig.names.first ]).ok?
      assert call(session, :catalog_hooks, [ "git-push-ci-reminder" ]).ok?
      assert call(session, :catalog_plugins, [ "ci-workflow" ]).ok?
    end
  end

  test "the OAuth probe stops asking once its wall-clock budget is spent" do
    Dir.mktmpdir do |dir|
      session = make_session(status: :needs_input, mcp_servers: [ "notion" ], metadata: { "working_directory" => dir })
      McpOauthCredentialInjector.any_instance.stubs(:check_credentials_status).returns(
        "notion" => { has_credential: false, credential_valid: false, server_url: "https://mcp.notion.com/mcp" }
      )
      McpOauthService.any_instance.expects(:check_oauth_requirement).never

      # A budget of zero is already spent by the time the first server is reached.
      needing = McpOauthProbe.new(session, budget_seconds: 0).servers_needing_oauth

      assert_equal [], needing, "a server we could not reach in time is reported as not needing OAuth"
    end
  end

  # --- The OAuth probe -------------------------------------------------------

  test "skills and hooks never run the OAuth probe" do
    Dir.mktmpdir do |dir|
      session = make_session(metadata: { "working_directory" => dir })
      McpOauthProbe.any_instance.expects(:servers_needing_oauth).never

      assert call(session, :catalog_skills, [ SkillsConfig.names.first ]).ok?
      assert call(session, :catalog_hooks, [ "git-push-ci-reminder" ]).ok?
    end
  end

  test "servers needing authorization park the session so the Authorize UI shows" do
    Dir.mktmpdir do |dir|
      session = make_session(status: :needs_input, metadata: { "working_directory" => dir })
      needing = [ { server_name: "linear", server_url: "https://mcp.linear.app/mcp" } ]
      McpOauthProbe.any_instance.stubs(:servers_needing_oauth).returns(needing)

      result = call(session, :mcp_servers, [ "linear" ])

      assert result.ok?
      assert result.oauth_required?
      session.reload
      assert_equal "failed", session.status
      assert_equal "oauth_required", session.metadata["failure_reason"]
      assert_equal "warning", session.logs.last.level
    end
  end

  test "a running session is never failed by the OAuth escalation" do
    Dir.mktmpdir do |dir|
      session = make_session(status: :running, metadata: { "working_directory" => dir })
      McpOauthProbe.any_instance.stubs(:servers_needing_oauth)
        .returns([ { server_name: "linear", server_url: "https://mcp.linear.app/mcp" } ])

      result = call(session, :mcp_servers, [ "linear" ])

      assert result.ok?
      assert result.oauth_required?, "the caller is still told which servers need authorizing"
      session.reload
      assert_equal "running", session.status, "a live turn is not killed by a config edit"
      assert_nil session.metadata["failure_reason"]
    end
  end

  test "a selection with nothing left to authorize clears stale oauth metadata" do
    Dir.mktmpdir do |dir|
      session = make_session(
        status: :failed,
        mcp_servers: [ "linear" ],
        metadata: {
          "working_directory" => dir,
          "failure_reason" => "oauth_required",
          "oauth_required_servers" => [ { "server_name" => "linear" } ]
        }
      )
      McpOauthProbe.any_instance.stubs(:servers_needing_oauth).returns([])

      assert call(session, :mcp_servers, []).ok?

      session.reload
      assert_nil session.metadata["failure_reason"]
      assert_nil session.metadata["oauth_required_servers"]
    end
  end
end
