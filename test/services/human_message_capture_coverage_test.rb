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

    (SessionGenesis::KEYS - HumanMessageCaptureCoverage::CHANNEL_BY_GENESIS.keys).each do |genesis|
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
