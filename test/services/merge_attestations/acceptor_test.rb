# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A receiving Zimmer: a verified token becomes the same merge authorization a
# Merge-button tap sends, pinned to the commit, recorded three ways, and spent.
class MergeAttestations::AcceptorTest < ActiveSupport::TestCase
  PR = "https://github.com/example-org/example-repo/pull/42"

  setup do
    setup_merge_attestation_env
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
  end
  teardown { teardown_merge_attestation_env }

  def holding_session
    @holding_session ||= Session.create!(agent_runtime: "claude_code", prompt: "initial", title: "Add four connectors",
      git_root: "https://github.com/test/repo.git", branch: "main", status: :needs_input,
      custom_metadata: green_pr_metadata(PR))
  end

  def accept(token, reading: github_reading) = MergeAttestations::Acceptor.call(token, snapshot: reading)

  test "a verified approval tells the holding session to merge at that commit and records it" do
    holding_session
    result = nil
    assert_difference -> { HumanMessage.count } => 1, -> { GateDecision.count } => 1, -> { MergeAttestation.received.count } => 1 do
      result = accept(sign_attestation(attestation_claims(PR)))
    end

    assert_equal holding_session, result.session
    assert_equal "accepted", result.attestation.outcome

    delivered = TurnSource.strip(holding_session.reload.metadata["pending_follow_up_prompt"].to_s)
    assert AutomatedPrompts.merge_authorization?(delivered)
    assert_includes delivered, "--match-head-commit #{HEAD}"
    assert_includes delivered, "a new commit needs a new yes"
    assert_includes delivered, "which that Zimmer signed and this one verified"
    assert Sessions::AuthorizeMerge.authorized_at(holding_session, PR)

    message = holding_session.human_messages.sole
    assert_equal HumanMessage::ATTESTED, message.channel
    assert_equal "tadasant", message.author
    assert_equal "Yes.", message.content
    assert_equal PR, message.confirmed_pr_url
    assert_equal ISSUER, message.attestation_issuer
    assert_match(/signed approval from #{Regexp.escape(ISSUER)} \(Live Mode CarPlay, spoken; verified/, message.channel_label)
    assert_equal message, result.attestation.human_message

    decision = GateDecision.for_artifact(PR).sole
    assert_equal GateDecision::HUMAN_APPROVED, decision.decision
    assert_equal GateDecision::ATTESTATION, decision.recorded_via
    assert_equal HEAD, decision.payload.dig("human_approval", "head_sha")

    text = Mcp::Tools::GetSessionProvenance.new(context: Mcp::Context.new).call("session_id" => holding_session.id.to_s)
    assert_match(/composed by the Zimmer at #{Regexp.escape(ISSUER)} and covered by its signature/, text)
  end

  test "the same token twice merges once" do
    holding_session
    token = sign_attestation(attestation_claims(PR))
    accept(token)

    error = assert_raises(MergeAttestations::Rejected) { accept(token) }
    assert_equal "replayed", error.code
    assert_equal 1, MergeAttestation.received.count
    assert_equal 1, holding_session.human_messages.count
  end

  test "a push since the yes refuses it and spends nothing" do
    holding_session
    token = sign_attestation(attestation_claims(PR))

    error = assert_raises(MergeAttestations::Rejected) { accept(token, reading: github_reading(head_sha: "b" * 40)) }
    assert_equal "head_moved", error.code
    assert_equal 0, MergeAttestation.count
    assert_nil holding_session.reload.metadata["pending_follow_up_prompt"]

    accept(token)
    assert_equal 1, MergeAttestation.received.count, "the token was not spent by the refusal"
  end

  test "no holding session, red CI, or a closed PR refuses it" do
    error = assert_raises(MergeAttestations::Rejected) { accept(sign_attestation(attestation_claims(PR))) }
    assert_equal "not_mergeable", error.code
    assert_match(/No session on this Zimmer holds/, error.message)

    holding_session.update!(custom_metadata: green_pr_metadata(PR).merge("github_pull_request_ci_statuses" => { PR => "fail" }))
    assert_match(/CI is fail/, assert_raises(MergeAttestations::Rejected) { accept(sign_attestation(attestation_claims(PR))) }.message)

    holding_session.update!(custom_metadata: green_pr_metadata(PR))
    error = assert_raises(MergeAttestations::Rejected) { accept(sign_attestation(attestation_claims(PR)), reading: github_reading(state: "CLOSED")) }
    assert_match(/GitHub says the PR is closed/, error.message)
    assert_equal 0, MergeAttestation.count
  end

  test "an archived session holding the PR is not a target" do
    holding_session.update_columns(status: Session.statuses[:archived])
    assert_nil MergeAttestations::Target.holding_session(PR)
  end

  test "submit_merge_attestation answers refusals as JSON with a code" do
    out = JSON.parse(Mcp::Tools::SubmitMergeAttestation.new(context: Mcp::Context.new).call("attestation" => "a.b.c"))
    assert_equal false, out["accepted"]
    assert_equal "malformed", out["code"]
  end

  test "a received row's approval fields cannot be rewritten or deleted" do
    holding_session
    row = accept(sign_attestation(attestation_claims(PR))).attestation
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(head_sha: "c" * 40) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
  end
end
