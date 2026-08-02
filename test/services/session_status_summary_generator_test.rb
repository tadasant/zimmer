# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The fork-backed generation path for the Status panel's blurb, and the caching
# rule that decides when it may run at all.
class SessionStatusSummaryGeneratorTest < ActiveSupport::TestCase
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

  test "an archived session is skipped" do
    @session.update_column(:status, Session.statuses[:archived])

    assert_equal :skipped, generate.outcome
  end

  # The copy takes real time — tens of seconds on a repo with an installed
  # bundle — and the session can reach the trash during it. In production it did:
  # the source clone was deleted 12 seconds after the copy ended.
  test "a session that archives during the clone copy abandons the fork" do
    session = @session
    @fs.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      session.update_column(:status, Session.statuses[:archived])
      super(src, dest, exclude: exclude)
    end

    result = generate

    assert_equal :skipped, result.outcome
    assert summary_fork.archived?, "an abandoned fork must be archived so its copied clone is reclaimed"

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
    @fs.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      session.update_column(:status, Session.statuses[:archived])
      super(src, dest, exclude: exclude)
    end

    assert_equal :skipped, generate(force: true).outcome

    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_equal "The summary fork failed.", record.error
    assert_equal "All good.", record.summary
    assert_nil record.requested_at
  end

  # A fork that is made and then never dispatched is invisible to every operator
  # list and its clone is skipped by OrphanCloneFilesystemCleanupJob (a session
  # row still claims it), so it would hold a full copy of a repository forever.
  test "a fork that cannot be dispatched is archived rather than left holding a clone" do
    Session.any_instance.stubs(:deliver_follow_up!).raises(RuntimeError, "spawn refused")

    result = generate

    assert_equal :failed, result.outcome
    assert summary_fork.archived?
    assert_equal "failed", @session.reload.status_summary.state
  end

  # The summarizer reads the transcript and is told not to run tools, so the
  # installed-dependency trees are pure copy cost — and the copy window is what
  # makes a concurrent-mutation race likely at all.
  test "a summary fork does not copy installed-dependency trees" do
    @fs.write(File.join(@clone_path, "Gemfile"), "source 'https://rubygems.org'")
    @fs.write(File.join(@clone_path, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"), "gem")
    @fs.write(File.join(@clone_path, "node_modules/turbo/index.js"), "js")

    clone = generate.fork_session.metadata["clone_path"]

    assert @fs.exists?(File.join(clone, "Gemfile")), "the working tree itself is still copied"
    assert_not @fs.exists?(File.join(clone, "vendor/bundle/ruby/3.4.0/gems/rails-8.1.3/README.md"))
    assert_not @fs.exists?(File.join(clone, "node_modules/turbo/index.js"))
  end

  # --- Concurrency ----------------------------------------------------------
  #
  # The production defect: the record was read-or-BUILT before the fork and
  # inserted only after the clone copy had finished, so a second generation
  # landing inside that window saw no row, built its own, and lost on the unique
  # index — a PG::UniqueViolation page, plus a second full copy of a repository.
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

  test "a second generation landing during the clone copy neither forks nor collides" do
    session_id = @session.id
    competitor_fs = MockFileSystemAdapter.new
    competitor_fs.mkdir_p(@clone_path)
    competitor = nil

    # A second worker, on its own Session instance and its own filesystem, runs
    # while the first one's copy is in flight — the window the race lived in.
    @fs.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      competitor ||= SessionStatusSummaryGenerator.call(
        session: Session.find(session_id), force: true, file_system: competitor_fs
      )
      super(src, dest, exclude: exclude)
    end

    result = generate(force: true)

    assert_equal :started, result.outcome, result.message
    assert_equal :pending, competitor.outcome, "the second runner must not start a second fork"
    assert_equal 1, SessionStatusSummary.where(session_id: session_id).count
    assert_equal 1, Session.where("metadata->>? = ?", SessionStatusSummaryGenerator::FORK_MARKER, session_id.to_s).count
    assert_equal result.fork_session.id, @session.reload.status_summary.fork_session_id
  end

  # A claim is not eternal: once it ages past PENDING_TIMEOUT another runner may
  # take the record over. The runner that lost it must not stomp the newer
  # generation, and must not leave its fork holding a copy of a repository.
  test "a generation whose claim is taken over during the copy abandons its fork" do
    session_id = @session.id
    taken_over = false

    @fs.define_singleton_method(:cp_r) do |src, dest, exclude: []|
      unless taken_over
        taken_over = true
        # A takeover, compressed: in production this run's claim first ages past
        # PENDING_TIMEOUT and only then does a newer runner stamp its own
        # `requested_at`. A test cannot wait fifteen minutes for the first half,
        # and only the second half is observable from here anyway — a token on
        # the row that is not the one this run wrote.
        SessionStatusSummary.find_by(session_id: session_id).update!(requested_at: 1.second.from_now)
      end
      super(src, dest, exclude: exclude)
    end

    result = generate(force: true)

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

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing)

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

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing)

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

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing)

    assert_equal :failed, result.outcome
    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_equal "Source clone directory does not exist", record.error
  end
end
