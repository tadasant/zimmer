# frozen_string_literal: true

require "test_helper"

# Whether Zimmer could have captured a human message at all, per input channel.
#
# The case that matters is Slack: `slack_user_ids` ships EMPTY (this repo is
# public) and is filled in at /supervisor/users, so an unconfigured deployment
# records nothing for every Slack-origin session — and until #658 that rendered
# identically to "no human spoke".
class HumanMessageCaptureCoverageTest < ActiveSupport::TestCase
  def spawn_session(genesis:, parent: nil)
    Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "coverage",
      genesis: genesis,
      parent_session_id: parent&.id
    )
  end

  def coverage_for(session)
    HumanMessageCaptureCoverage.new(SessionHierarchy.new(session))
  end

  test "a slack-genesis hierarchy is a gap when no roster row maps a Slack user ID" do
    User.update_all(slack_user_ids: [])
    session = spawn_session(genesis: SessionGenesis::SLACK)

    gaps = coverage_for(session).gaps

    assert_equal 1, gaps.size
    gap = gaps.first
    assert_equal HumanMessage::SLACK, gap.channel
    assert_equal SessionGenesis::SLACK, gap.genesis
    assert_equal [ session.id ], gap.session_ids
    assert_equal "Slack", gap.channel_label
    assert_match "maps any Slack user ID", gap.reason
    assert_match "/supervisor/users", gap.remedy
  end

  test "mapping one Slack user ID closes the gap for the whole deployment" do
    users(:tadasant).update!(slack_user_ids: [ "U123HUMAN" ])
    session = spawn_session(genesis: SessionGenesis::SLACK)

    assert_empty coverage_for(session).gaps
    assert_not coverage_for(session).any?
  end

  test "a web_ui hierarchy is not a gap while the admin key names a roster row" do
    session = spawn_session(genesis: SessionGenesis::WEB_UI)

    assert_equal users(:tadasant).key, User.admin_key
    assert_empty coverage_for(session).gaps
  end

  test "a web_ui hierarchy IS a gap when the configured admin key names nobody" do
    users(:tadasant).destroy!
    session = spawn_session(genesis: SessionGenesis::WEB_UI)

    gaps = coverage_for(session).gaps

    assert_equal [ HumanMessage::WEB_UI ], gaps.map(&:channel)
    assert_match User::ADMIN_ENV_KEY, gaps.first.reason
  end

  # The whole reason this class does not simply say "cannot say" everywhere: a
  # genesis with no human at its boundary has no capture to be missing, and an
  # empty record there is the correct answer rather than a gap.
  test "genesis kinds with no human input boundary are never a gap" do
    User.update_all(slack_user_ids: [])

    (SessionGenesis::KEYS - HumanMessageCaptureCoverage::CHANNEL_BY_GENESIS.keys - [ SessionGenesis::MCP_EVENT ]).each do |genesis|
      session = spawn_session(genesis: genesis)
      assert_empty coverage_for(session).gaps, "#{genesis} should not report a capture gap"
    end
  end

  test "a gap is found on any session in the hierarchy, not only the one asked about" do
    User.update_all(slack_user_ids: [])
    router = spawn_session(genesis: SessionGenesis::SLACK)
    worker = spawn_session(genesis: SessionGenesis::SLACK, parent: router)

    gaps = coverage_for(worker).gaps

    assert_equal 1, gaps.size
    assert_equal [ router.id, worker.id ].sort, gaps.first.session_ids.sort
    assert_equal 2, gaps.first.session_count
  end

  # ── MCP events: answered per session, and "not established" by default ──────

  def event_session(marker: nil, genesis: SessionGenesis::MCP_EVENT, parent: nil)
    spawn_session(genesis: genesis, parent: parent).tap do |session|
      session.merge_metadata!({ "mcp_event_server" => "slack-zimmer", McpEvents::HumanCapture::METADATA_KEY => marker }.compact)
    end
  end

  test "a session an MCP event started is a gap, however complete the Slack roster is" do
    users(:tadasant).update!(slack_user_ids: [ "U123HUMAN" ])
    session = event_session

    gap = coverage_for(session).gaps.sole
    assert_equal HumanMessageCaptureCoverage::MCP_EVENT, gap.channel
    assert_equal SessionGenesis::MCP_EVENT, gap.genesis
    assert_equal "MCP events", gap.channel_label
    assert_equal [ session.id ], gap.session_ids
    assert_match McpEvents::SlackMessage::SERVERS_ENV, gap.reason
    assert_not session.human_message_record.capture_complete?
  end

  test "an event-started session is a gap under every marker but complete" do
    assert_empty coverage_for(event_session(marker: McpEvents::HumanCapture::COMPLETE)).gaps
    assert_not_empty coverage_for(event_session(marker: McpEvents::HumanCapture::INCOMPLETE)).gaps
    assert_not_empty coverage_for(event_session(marker: "anything else")).gaps
  end

  test "a trigger with a second condition type does not hide the event behind its genesis" do
    users(:tadasant).update!(slack_user_ids: [ "U123HUMAN" ])

    assert_equal [ HumanMessageCaptureCoverage::MCP_EVENT ], coverage_for(event_session(genesis: SessionGenesis::SLACK)).gaps.map(&:channel)
  end

  test "an event delivered into a session something else started is a gap when it was not attributed" do
    session = spawn_session(genesis: SessionGenesis::WEB_UI)
    session.merge_metadata!(McpEvents::HumanCapture::METADATA_KEY => McpEvents::HumanCapture::INCOMPLETE)

    assert_equal [ session.id ], coverage_for(session).gaps.sole.session_ids
  end

  test "a child that inherited the genesis is answered by the event session above it" do
    attributed = event_session(marker: McpEvents::HumanCapture::COMPLETE)
    assert_empty coverage_for(spawn_session(genesis: SessionGenesis::MCP_EVENT, parent: attributed)).gaps

    unattributed = event_session
    child = spawn_session(genesis: SessionGenesis::MCP_EVENT, parent: unattributed)
    assert_equal [ unattributed.id ], coverage_for(child).gaps.sole.session_ids
  end

  test "an mcp_event genesis with no event session above it is a gap itself" do
    session = spawn_session(genesis: SessionGenesis::MCP_EVENT)

    assert_equal [ session.id ], coverage_for(session).gaps.sole.session_ids
  end

  test "the mcp_event gap has a reason and remedy of its own and is never configured deployment-wide" do
    assert_not HumanMessageCaptureCoverage.configured?(HumanMessageCaptureCoverage::MCP_EVENT)
    assert_not_equal HumanMessageCaptureCoverage.reason("no-such-channel"), HumanMessageCaptureCoverage.reason(HumanMessageCaptureCoverage::MCP_EVENT)
    assert_not_equal HumanMessageCaptureCoverage.remedy("no-such-channel"), HumanMessageCaptureCoverage.remedy(HumanMessageCaptureCoverage::MCP_EVENT)
  end

  # `configured?` reports an unrecognised channel as a GAP rather than as
  # instrumented, which is the safe direction — but a channel that lands there is
  # still a bug, and this is what keeps it out of production. Every channel
  # CHANNEL_BY_GENESIS maps to must be one HumanMessage itself recognises, and
  # every channel HumanMessage recognises must have its own arm, so the generic
  # fallbacks stay unreachable. `assistant`, `live_mode` and `attested` are the channels
  # with no genesis of their own (see the class comment), so they alone may be unmapped.
  test "every channel is a real channel with its own configured? arm" do
    mapped = HumanMessageCaptureCoverage::CHANNEL_BY_GENESIS.values

    assert_empty mapped - HumanMessage::CHANNELS
    assert_equal [ HumanMessage::ASSISTANT, HumanMessage::LIVE_MODE, HumanMessage::ATTESTED ], HumanMessage::CHANNELS - mapped
    HumanMessageCaptureCoverage::CHANNEL_BY_GENESIS.each_key do |genesis|
      assert_includes SessionGenesis::KEYS, genesis
    end

    generic_reason = HumanMessageCaptureCoverage.reason("no-such-channel")
    generic_remedy = HumanMessageCaptureCoverage.remedy("no-such-channel")
    HumanMessage::CHANNELS.each do |channel|
      assert_not_equal generic_reason, HumanMessageCaptureCoverage.reason(channel)
      assert_not_equal generic_remedy, HumanMessageCaptureCoverage.remedy(channel)
    end

    assert_not HumanMessageCaptureCoverage.configured?("no-such-channel"),
      "an unrecognised channel must report a gap, never a clean bill of health"
  end

  test "the record exposes the gaps and answers whether silence is an answer" do
    User.update_all(slack_user_ids: [])
    slack_session = spawn_session(genesis: SessionGenesis::SLACK)
    web_session = spawn_session(genesis: SessionGenesis::WEB_UI)

    assert_not slack_session.human_message_record.capture_complete?
    assert_equal [ HumanMessage::SLACK ], slack_session.human_message_record.capture_gaps.map(&:channel)

    assert_predicate web_session.human_message_record, :capture_complete?
    assert_empty web_session.human_message_record.capture_gaps
  end
end
