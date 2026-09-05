# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The fork-backed generation path for the Status panel's blurb, and the caching
# rule that decides when it may run at all.
class SessionStatusSummaryGeneratorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @transcript = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Ship the thing" }, "timestamp" => "2026-08-01T10:00:00Z" },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Opened the PR" } ] }, "timestamp" => "2026-08-01T10:00:01Z" }
    ].map { |line| JSON.generate(line) }.join("\n") + "\n"

    @fs = MockFileSystemAdapter.new
    @clone_path = "/home/test/.zimmer/clones/test-repo-main-1-abcd"
    @fs.mkdir_p(@clone_path)

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      transcript: @transcript,
      goal: "Open a PR and label it ready to merge",
      title: "Ship the thing",
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path }
    )
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  def generate(**opts)
    SessionStatusSummaryGenerator.call(session: @session, file_system: @fs, **opts)
  end

  # Found by its marker rather than by id order, which would depend on where the
  # fixtures left the sequence.
  def summary_fork
    Session.where("metadata->>? = ?", SessionStatusSummaryGenerator::FORK_MARKER, @session.id.to_s).sole
  end

  # A fork service that runs `during` inside the call, then delegates to the real
  # one — the seam every race test below drives.
  #
  # The window it opens is the one between this run taking the claim and its fork
  # existing: long enough in production for the session to reach the trash, for a
  # second generation to land, or for a newer runner to take the claim over. It
  # used to be held open by the clone copy, and a `cp_r` stub was how these tests
  # reached it. A summary fork copies nothing now (#771), so the copy is not a
  # seam any more — but the window is not the copy, and closing it to milliseconds
  # does not make a concurrent generation impossible. Injecting at the fork
  # service reaches the same window without depending on how the fork's directory
  # gets made.
  def fork_service_running(&during)
    Class.new do
      define_singleton_method(:call) do |**args|
        during.call
        ForkSessionService.call(**args)
      end
    end
  end

  # --- The fork-backed path -------------------------------------------------

  test "generation forks the session at its last transcript message and prompts the fork" do
    result = nil
    assert_difference -> { Session.count }, 1 do
      result = generate
    end

    assert_equal :started, result.outcome
    fork = result.fork_session

    assert_equal @session.id, fork.metadata[SessionStatusSummaryGenerator::FORK_MARKER]
    assert_equal 1, fork.metadata["forked_at_message_index"], "forks at the last line (2 lines, 0-indexed)"
    assert_equal @transcript, fork.transcript, "the fork carries the whole conversation up to the fork point"
  end

  # A fork inherits the source's goal, and a goal is an instruction to act. A
  # summarizer carrying "open a PR and label it ready to merge" would go do that.
  test "the summary fork does not inherit the source session's goal" do
    fork = generate.fork_session

    assert_nil fork.goal
    assert_equal "Status summary for session ##{@session.id}", fork.title
    assert_not fork.heartbeat_enabled
  end

  test "the fork is sent exactly one follow-up prompt asking for the summary" do
    prompts = []
    Session.any_instance.stubs(:deliver_follow_up!).with do |prompt, *|
      prompts << prompt
      true
    end

    generate

    assert_equal 1, prompts.size
    assert_match(/2-3 sentences/, prompts.first)
    assert_match(%r{#message-INDEX}, prompts.first)
    assert_match(/Do not run any tools/, prompts.first)
  end

  test "a Codex summary fork starts a fresh turn with inline transcript context" do
    @session.update!(
      agent_runtime: "codex",
      transcript: file_fixture("codex_rollout.jsonl").read
    )

    fork = generate.fork_session
    prompt = fork.reload.metadata["pending_follow_up_prompt"]

    assert_equal false, fork.metadata["runtime_started"]
    assert_equal "codex", fork.agent_runtime
    assert_match(/Write the Status panel/, prompt)
    assert_match(/Conversation so far:/, prompt)
    assert_match(/List the files in the current directory\./, prompt)
    assert_match(/The directory contains a single file: `README\.md`\./, prompt)
    assert_no_match(/"response_item"/, prompt)
  end

  test "a Claude summary fork remains resumable and does not inline the transcript" do
    prompts = []
    Session.any_instance.stubs(:deliver_follow_up!).with do |prompt, *|
      prompts << prompt
      true
    end

    fork = generate.fork_session

    assert_equal true, fork.metadata["runtime_started"]
    assert_equal 1, prompts.size
    assert_no_match(/Conversation so far:/, prompts.first)
  end

  test "inline transcript context keeps the latest messages when it is truncated" do
    rendered = "oldest message\n#{"middle\n" * 20_000}latest message"

    excerpt = StatusSummaryTranscriptExcerpt.truncate_to_tail(
      rendered, SessionStatusSummaryGenerator::INLINE_TRANSCRIPT_MAX_CHARS
    )

    assert_operator excerpt.length, :<=, SessionStatusSummaryGenerator::INLINE_TRANSCRIPT_MAX_CHARS
    assert_match(/\A\n\n\[Earlier transcript truncated\]\n\n/, excerpt)
    assert_no_match(/oldest message/, excerpt)
    assert_match(/latest message\z/, excerpt)
  end


  # --- The pool-independent path --------------------------------------------
  #
  # THE DEFECT THIS SECTION EXISTS FOR. The fork path needs a login-pool account,
  # a working directory and an agent turn. Under sustained quota pressure the
  # fork is parked before it answers, and the repair sweep that would retry it
  # used to stand down for the same outage — so a session at rest never got a
  # blurb at all, and the panel read "the summary fork was parked, it will be
  # retried" for hours. The one-shot path is the answer that does not need any of
  # that.

  # A fake standing in for HeadlessInferenceService: same #generate contract,
  # records what it was asked.
  class FakeInference
    attr_reader :prompts

    def initialize(answer) = (@answer = answer; @prompts = [])

    def generate(prompt, **)
      @prompts << prompt
      @answer
    end
  end

  def generate_headless(answer, **opts)
    inference = FakeInference.new(answer)
    result = SessionStatusSummaryGenerator.call(
      session: @session, file_system: @fs, headless: true, inference_service: inference, **opts
    )
    [ result, inference ]
  end

  test "the headless path writes the blurb without forking anything" do
    result, inference = nil

    assert_no_difference -> { Session.count } do
      result, inference = generate_headless("The PR is open and CI is green.")
    end

    assert_equal :ready, result.outcome

    stored = @session.reload.status_summary
    assert_equal "The PR is open and CI is green.", stored.summary
    assert_equal "ready", stored.state
    assert_nil stored.fork_session_id
    assert_not_nil stored.generated_at

    # Stamped at the line count it was written from, so the summary reads as
    # CURRENT and the sweep stops retrying this session.
    assert_equal @session.transcript_line_count, stored.transcript_line_count
    assert_not stored.stale?(@session.transcript_line_count)

    # It was handed the conversation, because it has none of its own.
    assert_match(/Conversation so far:/, inference.prompts.sole)
    assert_match(/Opened the PR/, inference.prompts.sole)
  end

  # The exact regression #561 fixed on the fork path, guarded on the new one:
  # `claude -p` prints the runtime's limit line to stdout just as a parked fork
  # writes it into its transcript. Stored, it would be stamped CURRENT and never
  # replaced.
  test "the headless path never publishes a runtime refusal as the summary" do
    result, = generate_headless("You've hit your session limit · resets 6:30pm (UTC)")

    assert_equal :failed, result.outcome

    stored = @session.reload.status_summary
    assert_nil stored.summary, "a refusal must not become the blurb"
    assert_equal "failed", stored.state
    assert stored.stale?(@session.transcript_line_count),
      "the session must stay a candidate for another attempt"
  end

  test "the headless path records a failure when the inference returns nothing" do
    result, = generate_headless(nil)

    assert_equal :failed, result.outcome

    stored = @session.reload.status_summary
    assert_nil stored.summary
    assert_equal "failed", stored.state
    assert stored.error.present?
  end

  # The automatic FORK path refuses a session whose clone has been reclaimed,
  # reading the missing tree as evidence that nobody is looking at the session.
  # The one-shot path costs no fork at all, so that refusal must not apply to it —
  # a session whose clone is gone is exactly the kind someone opens later to ask
  # what happened.
  test "the headless path does not need a clone on disk" do
    @session.update!(metadata: @session.metadata.merge("clone_path" => "/gone"))

    result, = generate_headless("Finished and archived.")

    assert_equal :ready, result.outcome
    assert_equal "Finished and archived.", @session.reload.status_summary.summary
  end

  test "the headless path declines a session whose summary is already current" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", summary: "Already current.",
      transcript_line_count: @session.transcript_line_count, generated_at: 1.minute.ago
    )

    result, inference = generate_headless("A newer answer.")

    assert_equal :fresh, result.outcome
    assert_empty inference.prompts, "a current summary must not cost an inference call"
    assert_equal "Already current.", @session.reload.status_summary.summary
  end

  # Both paths take the same claim, so they cannot both be writing this record —
  # and a runner whose claim was taken over must not stomp the one that replaced
  # it.
  test "the headless path does not stomp a generation that took the claim from it" do
    session_id = @session.id
    inference = Object.new
    inference.define_singleton_method(:generate) do |_prompt, **|
      # A newer generation claims the record while the completion is in flight.
      SessionStatusSummary.find_by(session_id: session_id)
        .update!(state: "pending", requested_at: Time.current, requested_line_count: 99)
      "An answer that is now too late."
    end

    result = SessionStatusSummaryGenerator.call(
      session: @session, file_system: @fs, headless: true, inference_service: inference
    )

    assert_equal :pending, result.outcome
    assert_nil @session.reload.status_summary.summary
    assert_equal "pending", @session.status_summary.state
  end

  test "a headless generation is noted on the session's own timeline" do
    generate_headless("The PR is open.")

    assert @session.logs.reload.any? { |log| log.content.include?("one-shot inference call") },
      "a reader who finds the blurb terser than usual should be able to see why"
  end


  # The parity gap this closes: the panel's Regenerate button, the REST endpoint
  # and the MCP `action_session` regenerate action are all FORCED, and none of
  # them consults the login pool. Before this, pressing Regenerate during an
  # outage stood a fork up, watched it park, and reported a failure.
  test "a forced generation falls back to the one-shot path when the pool is empty" do
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    inference = FakeInference.new("Where things stand.")

    result = nil
    assert_no_difference -> { Session.count } do
      result = SessionStatusSummaryGenerator.call(
        session: @session, file_system: @fs, force: true, inference_service: inference
      )
    end

    assert_equal :ready, result.outcome
    assert_equal "Where things stand.", @session.reload.status_summary.summary
    assert_equal 1, inference.prompts.size
  end

  test "a healthy pool still forks" do
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_difference -> { Session.count }, 1 do
      assert_equal :started, generate.outcome
    end
  end


  # Nothing renderable means there is nothing to ask about, so no call is made
  # at all — but the record must still land in a state the sweep will retry.
  test "the headless path records a failure without calling out when there is nothing to render" do
    @session.update_column(:transcript, "not json\nalso not json\n")
    inference = FakeInference.new("An answer that should never be asked for.")

    result = SessionStatusSummaryGenerator.call(
      session: @session, file_system: @fs, headless: true, inference_service: inference
    )

    assert_equal :failed, result.outcome
    assert_empty inference.prompts, "a blank excerpt must not cost an inference call"
    assert_nil @session.reload.status_summary.summary
    assert_equal "failed", @session.status_summary.state
  end

  # The refusal gate has two halves and this is the wording-independent one:
  # HeadlessInferenceService answers nil for a backend that exited non-zero, and
  # the generator must treat that as no answer rather than storing anything.
  test "the headless path records a failure when the inference reports no answer" do
    result, = generate_headless(nil)

    assert_equal :failed, result.outcome
    assert_nil @session.reload.status_summary.summary
    assert @session.status_summary.stale?(@session.transcript_line_count),
      "the session must stay a candidate for another attempt"
  end

  # --- What the blurb is allowed to assert ----------------------------------
  #
  # The defect these guard is written up on SessionStatusSummaryGenerator::
  # STATE_NOT_INTENT_RULE (#734): a blurb narrated a self-wake nobody had
  # scheduled, and a stranded session read as a healthy machine wait for 16
  # hours. Both prompts are asserted, because both write the same panel and the
  # rule is worthless in whichever one it is missing from.

  def fork_prompt
    prompts = []
    Session.any_instance.stubs(:deliver_follow_up!).with do |prompt, *|
      prompts << prompt
      true
    end

    generate

    prompts.sole
  end

  test "the fork prompt forbids inventing details and claiming unperformed actions" do
    prompt = fork_prompt

    assert_match(/do not invent a detail it does not contain/i, prompt.squish)
    assert_includes prompt, SessionStatusSummaryGenerator::STATE_NOT_INTENT_RULE
  end

  test "the one-shot prompt forbids inventing details and claiming unperformed actions" do
    _result, inference = generate_headless("The PR is open and CI is green.")

    assert_match(/do not invent a detail it does not contain/i, inference.prompts.sole.squish)
    assert_includes inference.prompts.sole, SessionStatusSummaryGenerator::STATE_NOT_INTENT_RULE
  end

  # Guards what the rule says, not just that a rule is there: cut back to "be
  # accurate", it would keep the two tests above green while leaving the blurb
  # free to narrate a wake nobody scheduled. Two anchors rather than a
  # transcription of the rule — enough to catch a gutting, loose enough that
  # rewording it is not a test failure.
  test "the rule bars first-person claims and names the wake that started this" do
    rule = SessionStatusSummaryGenerator::STATE_NOT_INTENT_RULE

    assert_match(/first person/, rule)
    assert_match(/wake/, rule)
  end

  # The dashboard broadcasts a card from after_create_commit, so a marker
  # stamped afterwards is stamped too late — the card is already on every open
  # dashboard.
  test "the fork carries its marker from the moment it is created" do
    seen = nil
    Session.any_instance.stubs(:broadcast_create_to_sessions_index).with { seen = :broadcast; true }

    fork = generate.fork_session

    assert_equal @session.id, fork.metadata[SessionStatusSummaryGenerator::FORK_MARKER]
    assert_nil seen, "a summary fork must never broadcast a card to the dashboard"
  end

  test "a summary fork never broadcasts an update to the dashboard either" do
    fork = generate.fork_session

    assert_not fork.send(:should_broadcast_to_index?)
  end

  # ForkSessionService indexes into the JSON-PARSED transcript, so a blank or
  # unparseable line makes the raw line count the wrong index space.
  test "a transcript with an unparseable line still forks at its last real message" do
    @session.update_column(:transcript, @transcript + "\n" + "not json\n")

    result = generate

    assert_equal :started, result.outcome, result.message
    assert_equal 1, result.fork_session.metadata["forked_at_message_index"]
  end

  # The fork's turn can finish before this method returns; the harvest job keys
  # off the record, so it has to name the fork before the fork is dispatched.
  test "the record names the fork before the follow-up is delivered" do
    state_at_delivery = nil
    Session.any_instance.stubs(:deliver_follow_up!).with do
      record = SessionStatusSummary.find_by(session_id: @session.id)
      state_at_delivery = [ record&.state, record&.fork_session_id.present? ]
      true
    end

    generate

    assert_equal [ "pending", true ], state_at_delivery
  end

  test "a started generation is recorded as pending against the fork and the line count" do
    fork = generate.fork_session
    record = @session.reload.status_summary

    assert_equal "pending", record.state
    assert record.pending?
    assert_equal fork.id, record.fork_session_id
    assert_equal 2, record.requested_line_count
    assert_equal 0, record.transcript_line_count, "not advanced until a summary actually lands"
  end

  # --- Caching / staleness --------------------------------------------------

  test "a current summary is not regenerated" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count, generated_at: Time.current
    )

    assert_no_difference -> { Session.count } do
      assert_equal :fresh, generate.outcome
    end
  end

  test "a summary regenerates once the transcript has moved" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count - 1, generated_at: Time.current
    )

    assert_equal :started, generate.outcome
  end

  test "force regenerates a summary Zimmer considers current" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count, generated_at: Time.current
    )

    assert_equal :started, generate(force: true).outcome
  end

  test "a generation already in flight is not started twice, even when forced" do
    generate

    assert_no_difference -> { Session.count } do
      assert_equal :pending, generate(force: true).outcome
    end
  end

  test "an abandoned generation does not block a new one" do
    generate
    @session.reload.status_summary.update!(requested_at: (SessionStatusSummary::PENDING_TIMEOUT + 1.minute).ago)

    assert_equal :started, generate(force: true).outcome
  end

  # --- Refusals -------------------------------------------------------------

  test "a status-summary fork never summarizes itself" do
    fork = generate.fork_session

    result = SessionStatusSummaryGenerator.call(session: fork, file_system: @fs)

    assert_equal :skipped, result.outcome
  end

  test "a session with no transcript is skipped" do
    @session.update_column(:transcript, nil)

    assert_equal :skipped, generate.outcome
  end

  # #519: a session wedged in its opening seconds has a one-line transcript
  # holding a title record and no conversation. Forking on that spends an agent
  # turn asking for a summary of nothing — with neither a resume file nor an
  # inline excerpt to answer from.
  test "a session whose transcript holds no conversation is skipped" do
    @session.update_column(
      :transcript,
      "#{{ "type" => "ai-title", "aiTitle" => "Ship the thing", "sessionId" => @session.session_id }.to_json}\n"
    )

    result = nil
    assert_no_difference -> { Session.count } do
      result = generate
    end
    assert_equal :skipped, result.outcome
  end

  # --- The trash -------------------------------------------------------------

  # Archive is how a Zimmer session FINISHES, and a finished session is exactly
  # the one someone opens later to ask what happened. The panel is what answers
  # that, so an operator pressing Regenerate on it gets a summary. The fork reads
  # the conversation rather than the tree, so being archived stops nothing.
  test "an archived session with a clone still on disk regenerates when asked" do
    @session.update_column(:status, Session.statuses[:archived])

    result = generate(force: true)

    assert_equal :started, result.outcome
    assert_equal @session.id, result.fork_session.metadata[SessionStatusSummaryGenerator::FORK_MARKER]
    assert_equal "pending", @session.reload.status_summary.state
  end

  # The other half: nothing enqueues an automatic generation for a session in the
  # trash on purpose, and standing a fork up for a session heading for deletion is
  # waste. Only the deliberate override gets through.
  test "an archived session is still skipped by an automatic generation" do
    @session.update_column(:status, Session.statuses[:archived])

    assert_equal :skipped, generate.outcome
    assert_nil @session.reload.status_summary, "an automatic skip claims nothing"
  end

  # The headline case, and the one #463 was filed for: DeferredCloneCleanupJob
  # reclaims an archived session's clone about ten seconds after it goes to the
  # trash, so every archived session an operator actually opens later has no tree
  # left. That must not stop a FORCED generation. The fork reads no file in the
  # tree anyway, so the only thing a missing one could do is fail the fork's
  # validation, and `scaffold_missing_clone` is what stops it doing that.
  test "an archived session whose clone is gone regenerates into a scaffolded fork" do
    @session.update_column(:status, Session.statuses[:archived])
    @fs.rm_rf(@clone_path)

    result = generate(force: true)

    assert_equal :started, result.outcome
    fork = result.fork_session
    assert_equal @session.id, fork.metadata[SessionStatusSummaryGenerator::FORK_MARKER]
    assert_equal true, fork.metadata["clone_scaffolded"]
    assert @fs.directory?(fork.metadata["clone_path"]), "the fork has a working directory to be spawned in"
    assert_equal "pending", @session.reload.status_summary.state
  end

  # A session with no clone recorded at all — one whose clone was reclaimed and
  # whose metadata never named one — is the same case one step earlier.
  test "a session with no clone path at all still regenerates when forced" do
    @session.update!(metadata: @session.metadata.except("clone_path"))

    result = generate(force: true)

    assert_equal :started, result.outcome
    assert_equal true, result.fork_session.metadata["clone_scaffolded"]
  end

  # The safety property, pinned at the argument boundary rather than only at the
  # refusal upstream of it. With no copy to make, `scaffold_missing_clone` governs
  # exactly one thing for this caller: whether a source clone that is GONE fails
  # the fork. It must, for an automatic run — a missing tree is the cheapest
  # evidence that this is a session nobody is looking at. A "simplification" of
  # `scaffold_missing_clone: force` to a bare `true` would start standing forks up
  # for those sessions, and every other test here would still pass.
  test "only a forced generation tolerates a source clone that is gone" do
    asked = []
    recorder = Class.new do
      define_singleton_method(:call) do |**args|
        asked << args[:scaffold_missing_clone]
        ForkSessionService::Result.new(success?: false, error: "stop here")
      end
    end

    SessionStatusSummaryGenerator.call(session: @session, fork_service: recorder, file_system: @fs)
    SessionStatusSummaryGenerator.call(session: @session, force: true, fork_service: recorder, file_system: @fs)

    assert_equal [ false, true ], asked
  end

  # Pinned at the same boundary, and for the same reason: the copy is invisible
  # from every other assertion here, because a fork that copies and a fork that
  # does not produce the identical summary. What it is not invisible from is the
  # two-thread `inference` lane this job runs on, where two copies of a live
  # working tree held every thread for half an hour with 48 jobs queued behind
  # them (#771). Neither path may ask for one.
  test "no generation asks the fork service to copy the source tree" do
    asked = []
    recorder = Class.new do
      define_singleton_method(:call) do |**args|
        asked << args[:copy_source_tree]
        ForkSessionService::Result.new(success?: false, error: "stop here")
      end
    end

    SessionStatusSummaryGenerator.call(session: @session, fork_service: recorder, file_system: @fs)
    SessionStatusSummaryGenerator.call(session: @session, force: true, fork_service: recorder, file_system: @fs)

    assert_equal [ false, false ], asked
  end

  # The other half of the bargain: nothing is stood up for a session nobody is
  # looking at. An automatic generation still wants a real clone.
  test "an automatic generation on a session whose clone is gone is unavailable" do
    @fs.rm_rf(@clone_path)

    result = generate

    assert_equal :unavailable, result.outcome
    assert_equal 0, Session.where("metadata->>? = ?", SessionStatusSummaryGenerator::FORK_MARKER, @session.id.to_s).count
    assert_nil @session.reload.status_summary, "an automatic refusal claims nothing"
  end

  # The pre-flight the three request surfaces share. It must answer without
  # writing anything — a panel render calls it on every page view.
  test "unavailable_reason answers without claiming, enqueuing or writing" do
    assert_nil SessionStatusSummaryGenerator.unavailable_reason(session: @session, file_system: @fs)

    @fs.rm_rf(@clone_path)

    reason = nil
    assert_no_difference -> { SessionStatusSummary.count } do
      assert_no_enqueued_jobs do
        reason = SessionStatusSummaryGenerator.unavailable_reason(session: @session, file_system: @fs)
      end
    end

    assert_equal :unavailable, reason.outcome, "an automatic generation still wants a clone"

    assert_nil SessionStatusSummaryGenerator.unavailable_reason(session: @session, force: true, file_system: @fs),
      "the three request surfaces ask as the forced run they perform, and a missing clone does not stop one"
  end

  # The post-fork re-check, from the forced side. The fork was MADE, so the
  # source reaching the trash behind it costs that fork nothing — the fork holds
  # the conversation, which is all it reads — and an operator is waiting on it.
  test "a forced generation whose session archives while the fork is made still dispatches it" do
    session = @session
    service = fork_service_running { session.update_column(:status, Session.statuses[:archived]) }

    result = generate(force: true, fork_service: service)

    assert_equal :started, result.outcome
    assert_not summary_fork.archived?, "the fork is dispatched, not abandoned"
    assert_equal "pending", @session.reload.status_summary.state, "the claim is held, not released"
    assert_equal summary_fork.id, @session.status_summary.fork_session_id
  end

  # The race the pre-flight cannot close: the clone is there when the button is
  # pressed and gone by the time the fork is made. A forced run does not need the
  # tree at all, so losing the race costs it nothing.
  test "a forced generation whose clone the trash deletes mid-flight still scaffolds" do
    session = @session
    clone = @clone_path
    fs = @fs
    service = fork_service_running do
      session.update_column(:status, Session.statuses[:archived])
      fs.rm_rf(clone)
    end

    result = generate(force: true, fork_service: service)

    assert_equal :started, result.outcome
    assert_equal true, result.fork_session.metadata["clone_scaffolded"]
    assert_equal "pending", @session.reload.status_summary.state
  end

  # A session can reach the trash while its fork is being stood up. In production
  # it did: the source clone was deleted 12 seconds after the fork was made.
  test "a session that archives while the fork is made abandons it" do
    session = @session
    service = fork_service_running { session.update_column(:status, Session.statuses[:archived]) }

    result = generate(fork_service: service)

    assert_equal :skipped, result.outcome
    assert summary_fork.archived?, "an abandoned fork must be archived so its clone is reclaimed"

    record = @session.reload.status_summary
    assert_equal "idle", record.state, "the claim is released rather than left pending with no fork behind it"
    assert_nil record.requested_at
    assert_nil record.fork_session_id
    assert_nil record.summary, "an abandoned generation records no blurb"
  end

  # Releasing the claim puts back what the claim displaced — all of it. The
  # claim clears `error` on its way in, so a partial restore would leave the
  # panel saying the last attempt failed for no recorded reason.
  test "a released claim restores the state it displaced, reason included" do
    SessionStatusSummary.create!(
      session: @session, state: "failed", error: "The summary fork failed.",
      summary: "All good.", transcript_line_count: 1, generated_at: Time.current
    )
    session = @session
    service = fork_service_running { session.update_column(:status, Session.statuses[:archived]) }

    assert_equal :skipped, generate(fork_service: service).outcome

    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_equal "The summary fork failed.", record.error
    assert_equal "All good.", record.summary
    assert_nil record.requested_at
  end

  # The other side of the same race, and the one that paged in production on
  # 2026-08-12. The archived-check above can only run on a fork that was MADE;
  # when DeferredCloneCleanupJob reaches the tree first, the fork service refuses
  # on a source clone that is no longer there, and the generation ended as
  # :failed with a paging `.error` behind it — about a summary nobody was ever
  # going to read. An automatic run still asks for a tree it does not read, as
  # the liveness proxy the refusal exists to be, so it can still lose this race.
  test "a source clone the trash deletes before the fork is made is skipped, not failed" do
    session = @session
    clone = @clone_path
    fs = @fs
    service = fork_service_running do
      session.update_column(:status, Session.statuses[:archived])
      fs.rm_rf(clone)
    end

    result = nil
    entries = capture_log_entries { result = generate(fork_service: service) }

    assert_equal :skipped, result.outcome
    assert_empty entries.select { |severity, message|
      severity == "ERROR" && (message.include?("service=ForkSessionService") || message.include?("service=SessionStatusSummaryGenerator"))
    }, "a generation the trash made moot must not page"

    assert_equal 0, Session.where("metadata->>? = ?", SessionStatusSummaryGenerator::FORK_MARKER, @session.id.to_s).count,
      "the fork was never made, so there is none to abandon"

    record = @session.reload.status_summary
    assert_equal "idle", record.state, "the claim is released rather than left pending"
    assert_nil record.error, "a moot generation records no failure against the panel"
    assert_nil record.requested_at
    assert_nil record.fork_session_id
  end

  # A fork that is made and then never dispatched is invisible to every operator
  # list and its clone is skipped by OrphanCloneFilesystemCleanupJob (a session
  # row still claims it), so it would sit on disk forever.
  test "a fork that cannot be dispatched is archived rather than left holding a clone" do
    Session.any_instance.stubs(:deliver_follow_up!).raises(RuntimeError, "spawn refused")

    result = generate

    assert_equal :failed, result.outcome
    assert summary_fork.archived?
    assert_equal "failed", @session.reload.status_summary.state
  end

  # The summarizer reads the conversation and is told not to run tools, so it
  # opens no file in the source tree and is given none of it — not the installed
  # dependency trees, and not the working tree either. Copying what nobody reads
  # is what held both `inference` threads for half an hour (#771).
  test "a summary fork's clone carries nothing from the source tree" do
    @fs.write(File.join(@clone_path, "Gemfile"), "source 'https://rubygems.org'")
    @fs.write(File.join(@clone_path, "app/models/session.rb"), "class Session; end")
    @fs.write(File.join(@clone_path, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"), "gem")
    @fs.write(File.join(@clone_path, "node_modules/turbo/index.js"), "js")

    result = generate
    clone = result.fork_session.metadata["clone_path"]

    assert_equal true, result.fork_session.metadata["clone_scaffolded"]
    assert @fs.directory?(clone), "the fork still gets a directory to be spawned in"
    assert_not @fs.exists?(File.join(clone, "Gemfile")), "the working tree is not copied either"
    assert_not @fs.exists?(File.join(clone, "app/models/session.rb"))
    assert_not @fs.exists?(File.join(clone, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"))
    assert_not @fs.exists?(File.join(clone, "node_modules/turbo/index.js"))
  end

  # --- Concurrency ----------------------------------------------------------
  #
  # The production defect: the record was read-or-BUILT before the fork and
  # inserted only after the fork had been made, so a second generation landing
  # inside that window saw no row, built its own, and lost on the unique index —
  # a PG::UniqueViolation page, plus a second fork nobody would read.
  #
  # Two of these reproduce that defect against the unfixed generator: the
  # competing generation below (which raises the production PG::UniqueViolation
  # on index_session_status_summaries_on_session_id) and the failure-handler test
  # further down (which catches the handler swallowing its own duplicate insert).
  # The claim-takeover tests cover behavior the fix introduces; against the
  # unfixed code they fail only because there is no row to take over at all.

  # A characterization test of the primitive the fix rests on, NOT a regression
  # test — it passes against the unfixed code too, which never called this. What
  # it pins is the property the generator now depends on: the losing INSERT is
  # savepointed, so the caller adopts the row that landed first and the
  # connection is still usable afterwards.
  test "a second create of the summary row adopts the first rather than colliding" do
    first = SessionStatusSummary.create_or_find_by!(session_id: @session.id)
    second = SessionStatusSummary.create_or_find_by!(session_id: @session.id)

    assert_equal first.id, second.id
    assert_equal 1, SessionStatusSummary.where(session_id: @session.id).count
    assert_equal :started, generate.outcome, "the connection is still usable afterwards"
  end

  test "a second generation landing while the first fork is made neither forks nor collides" do
    session_id = @session.id
    competitor_fs = MockFileSystemAdapter.new
    competitor_fs.mkdir_p(@clone_path)
    competitor = nil

    # A second worker, on its own Session instance and its own filesystem, runs
    # after the first has claimed the record and before its fork exists — the
    # window the race lived in.
    service = fork_service_running do
      competitor ||= SessionStatusSummaryGenerator.call(
        session: Session.find(session_id), force: true, file_system: competitor_fs
      )
    end

    result = generate(force: true, fork_service: service)

    assert_equal :started, result.outcome, result.message
    assert_equal :pending, competitor.outcome, "the second runner must not start a second fork"
    assert_equal 1, SessionStatusSummary.where(session_id: session_id).count
    assert_equal 1, Session.where("metadata->>? = ?", SessionStatusSummaryGenerator::FORK_MARKER, session_id.to_s).count
    assert_equal result.fork_session.id, @session.reload.status_summary.fork_session_id
  end

  # A claim is not eternal: once it ages past PENDING_TIMEOUT another runner may
  # take the record over. The runner that lost it must not stomp the newer
  # generation, and must not leave its fork on the floor holding a clone.
  test "a generation whose claim is taken over while its fork is made abandons the fork" do
    session_id = @session.id
    taken_over = false

    service = fork_service_running do
      unless taken_over
        taken_over = true
        # A takeover, compressed: in production this run's claim first ages past
        # PENDING_TIMEOUT and only then does a newer runner stamp its own
        # `requested_at`. A test cannot wait fifteen minutes for the first half,
        # and only the second half is observable from here anyway — a token on
        # the row that is not the one this run wrote.
        SessionStatusSummary.find_by(session_id: session_id).update!(requested_at: 1.second.from_now)
      end
    end

    result = generate(force: true, fork_service: service)

    assert_equal :pending, result.outcome
    record = @session.reload.status_summary
    assert_equal "pending", record.state
    assert_nil record.fork_session_id, "the record still belongs to the newer claim"
    assert summary_fork.archived?, "the losing runner archives its fork rather than leaving it on the floor"
  end

  # #record_failure takes no record from its caller: it reads the row back and
  # writes that, so it cannot repeat the write that just failed. In production it
  # did — it re-ran the read-or-build expression whose INSERT had collided,
  # collided again, and swallowed the second failure in its own rescue, leaving
  # the row `pending` and the panel spinning until PENDING_TIMEOUT.
  #
  # A row therefore has to EXIST by the time the failure is recorded, which is
  # what the stub arranges: that is the state in which a handler that rebuilds
  # the record instead of reloading it attempts a second INSERT and dies the way
  # the thing it is recording died.
  test "a failure is recorded against the row in the database rather than inserted again" do
    session = @session
    failing = Class.new do
      define_singleton_method(:call) do |**_args|
        SessionStatusSummary.create_or_find_by!(session_id: session.id)
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
      end
    end

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing, file_system: @fs)

    assert_equal :failed, result.outcome
    assert_equal 1, SessionStatusSummary.where(session_id: @session.id).count

    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_match(/duplicate key/, record.error)
    assert_not record.pending?, "a recorded failure must not leave the panel spinning"
  end

  test "a losing runner's failure does not overwrite the claim that took the record over" do
    session_id = @session.id
    failing = Class.new do
      define_singleton_method(:call) do |**_args|
        SessionStatusSummary.find_by(session_id: session_id).update!(requested_at: 1.second.from_now)
        ForkSessionService::Result.new(success?: false, error: "Source clone directory does not exist")
      end
    end

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing, file_system: @fs)

    assert_equal :failed, result.outcome, "the runner still reports its own failure to its caller"
    record = @session.reload.status_summary
    assert_equal "pending", record.state, "the newer generation is left in flight"
    assert_nil record.error
  end

  test "a fork failure is recorded on the summary rather than raised" do
    failing = Class.new do
      def self.call(**)
        ForkSessionService::Result.new(success?: false, error: "Source clone directory does not exist")
      end
    end

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing, file_system: @fs)

    assert_equal :failed, result.outcome
    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_equal "Source clone directory does not exist", record.error
  end
end
