require "test_helper"

class EnqueuedMessageProcessorServiceTest < ActiveJob::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "process_pid" => 12345, "clone_path" => "/tmp/test-clone" }
    )
  end

  test "process_next_message processes pending message when session is needs_input" do
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      result = service.process_next_message
      assert result, "Expected message to be processed"
    end

    @session.reload
    assert_equal "running", @session.status
    assert_not EnqueuedMessage.exists?(message.id), "Message should be deleted"
  end

  test "process_next_message returns false when no pending messages" do
    service = EnqueuedMessageProcessorService.new(@session)

    result = service.process_next_message

    assert_not result, "Expected false when no messages"
    assert_equal "needs_input", @session.status
  end

  test "process_next_message processes pending message when session is already running (handoff path)" do
    # Pre-pause handoff: AgentSessionJob calls into the service BEFORE pausing to
    # avoid a running → needs_input → running flap. The session must already be
    # running, and after processing must STILL be running (no resume! call).
    @session.update!(status: :running)
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      result = service.process_next_message
      assert result, "Expected message to be processed when session is running"
    end

    @session.reload
    assert_equal "running", @session.status, "Session should remain running (no flap)"
    assert_not EnqueuedMessage.exists?(message.id), "Message should be deleted"
  end

  test "process_next_message handoff from running does NOT call resume!" do
    # may_resume? is false from running, so resume! would raise AASM::InvalidTransition.
    # The service must detect this and skip the resume call.
    @session.update!(status: :running)
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    resume_called = false
    @session.define_singleton_method(:resume!) do
      resume_called = true
      raise "resume! should not be called from running state"
    end

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      assert service.process_next_message
    end

    refute resume_called, "resume! should not be called when session is already running"
  end

  test "process_next_message handoff from running clears running_job_id" do
    # The post-pause path's pause! callback (cleanup_running_job) clears running_job_id.
    # The handoff path skips pause!, so the service must clear it explicitly — otherwise
    # the new AgentSessionJob will see the old job_id in running_job_id and skip itself
    # via the concurrency guard in AgentSessionJob#perform.
    @session.update!(status: :running, running_job_id: "old-job-uuid")
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      assert service.process_next_message
    end

    @session.reload
    assert_nil @session.running_job_id, "running_job_id should be cleared so the new job can take over"
  end

  test "process_next_message handoff from running resets last_timeline_entry_at" do
    # The post-pause path's resume! callback (reset_elapsed_time_counter) updates
    # last_timeline_entry_at so the UI's "time since" indicator restarts at 0m.
    # The handoff path skips resume!, so the service must update it explicitly to
    # avoid the indicator showing stale time from the previous turn.
    old_time = 5.minutes.ago
    @session.update!(status: :running, last_timeline_entry_at: old_time)
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      assert service.process_next_message
    end

    @session.reload
    assert @session.last_timeline_entry_at > old_time,
      "last_timeline_entry_at should be refreshed for the new turn"
  end

  test "process_next_message post-pause path does NOT touch running_job_id manually" do
    # Sanity check: the post-pause path relies on pause!'s cleanup_running_job
    # callback (which has already cleared it before the service is called) and
    # resume!'s reset_elapsed_time_counter callback. The handoff-only manual
    # updates must NOT override running_job_id when entering from needs_input.
    @session.update!(status: :needs_input, running_job_id: nil)
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      assert service.process_next_message
    end

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.running_job_id
  end

  test "process_next_message returns false when session is failed" do
    @session.update!(status: :failed)
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)
    result = service.process_next_message

    assert_not result, "Expected false when session is failed"
  end

  test "process_next_message returns false when session is archived" do
    # Take a path that gets us to archived legitimately (needs_input → archived)
    @session.update!(status: :needs_input)
    @session.archive!
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)
    result = service.process_next_message

    assert_not result, "Expected false when session is archived"
  end

  test "process_next_message updates goal from message" do
    @session.update!(goal: "old condition")
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1,
      goal: "new condition"
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    @session.reload
    assert_equal "new condition", @session.goal
  end

  test "process_next_message preserves session goal when message has none" do
    @session.update!(goal: "existing goal")
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1,
      goal: nil
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    @session.reload
    assert_equal "existing goal", @session.goal
    assert_not @session.logs.exists?([ "content LIKE ?", "%Goal%from enqueued message%" ])
  end

  test "process_next_message leaves goal nil when neither session nor message has one" do
    @session.update!(goal: nil)
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1,
      goal: nil
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    @session.reload
    assert_nil @session.goal
  end

  test "process_next_message resets SIGTERM retry metadata" do
    @session.update!(
      metadata: @session.metadata.merge(
        "sigterm_retry_count" => 2,
        "sigterm_retry_timestamps" => [ Time.current.iso8601 ],
        "last_sigterm_at" => Time.current.iso8601
      )
    )
    @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    @session.reload
    assert_nil @session.metadata["sigterm_retry_count"]
    assert_nil @session.metadata["sigterm_retry_timestamps"]
    assert_nil @session.metadata["last_sigterm_at"]
  end

  test "process_next_message renumbers remaining messages" do
    @session.enqueued_messages.create!(content: "First", position: 1)
    second = @session.enqueued_messages.create!(content: "Second", position: 2)
    third = @session.enqueued_messages.create!(content: "Third", position: 3)

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    second.reload
    third.reload
    assert_equal 1, second.position
    assert_equal 2, third.position
  end

  test "process_next_message uses log_buffer when provided" do
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    logged_messages = []
    mock_buffer = Object.new
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end
    mock_buffer.define_singleton_method(:flush) { }

    service = EnqueuedMessageProcessorService.new(@session, log_buffer: mock_buffer)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    assert logged_messages.any? { |log| log[:content].include?("Processing enqueued message") }
    assert logged_messages.any? { |log| log[:content].include?("Sending enqueued message") }
  end

  test "process_next_message creates logs directly when no log_buffer" do
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    initial_log_count = @session.logs.count
    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      service.process_next_message
    end

    # Should have created logs directly (including state machine log)
    assert @session.logs.count > initial_log_count
  end

  test "process_next_message handles dirty session state from AASM update_all" do
    # Simulate AASM's update_all leaving dirty tracking in place
    # by updating session without using reload
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    # Simulate dirty state by making a local change
    @session.goal = "dirty value"
    # Don't save - simulate dirty tracking issue

    service = EnqueuedMessageProcessorService.new(@session)

    assert_enqueued_with(job: AgentSessionJob) do
      result = service.process_next_message
      assert result
    end

    # Session should have been reloaded and processed correctly
    @session.reload
    assert_equal "running", @session.status
  end

  test "process_next_message handles error gracefully with transaction rollback" do
    message = @session.enqueued_messages.create!(
      content: "Follow up prompt",
      position: 1
    )

    # Use a custom error-throwing mock for the session's resume! method
    # This will be called after the message is processed but before job enqueueing
    original_resume = @session.method(:resume!)
    call_count = 0
    @session.define_singleton_method(:resume!) do
      call_count += 1
      raise "Test error during resume"
    end

    service = EnqueuedMessageProcessorService.new(@session)
    result = service.process_next_message
    assert_not result, "Expected false on error"
    assert_equal 1, call_count, "resume! should have been called once"

    # Message should still exist and be pending (transaction rolled back)
    message.reload
    assert_equal "pending", message.status

    # Restore original method for cleanup
    @session.define_singleton_method(:resume!, original_resume)
  end

  test "process_next_message forwards attachments to AgentSessionJob.enqueue_with_prompt" do
    message = @session.enqueued_messages.create!(
      content: "Look at this",
      position: 1,
      images: [
        { "path" => File.join(ImageStorageService.base_dir, @session.id.to_s, "abc.png"), "media_type" => "image/png" }
      ],
      files: [
        { "path" => File.join(FileStorageService.base_dir, @session.id.to_s, "notes.md"),
          "original_filename" => "notes.md", "size" => 11 }
      ]
    )

    captured_kwargs = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(*args, **kwargs) { captured_kwargs = kwargs }) do
      service = EnqueuedMessageProcessorService.new(@session)
      assert service.process_next_message
    end

    assert captured_kwargs, "expected enqueue_with_prompt to be invoked"
    # Sessions::AttachmentDescriptors converts string-keyed jsonb hashes to symbol-keyed ones.
    assert_equal 1, captured_kwargs[:images].size
    assert_equal :path, captured_kwargs[:images].first.keys.first
    assert_equal "image/png", captured_kwargs[:images].first[:media_type]
    assert_equal 1, captured_kwargs[:files].size
    assert_equal "notes.md", captured_kwargs[:files].first[:original_filename]
    refute EnqueuedMessage.exists?(message.id)
  end

  # `path` is the only field either consumer can act on — the adapter
  # base64-encodes it, the file note tells the agent to read it — so an entry
  # without one is dropped rather than handed on as a nil path. No producer of
  # these columns writes one today; this pins it so a future one cannot.
  test "process_next_message drops an attachment entry with no path" do
    @session.enqueued_messages.create!(
      content: "Look at this",
      position: 1,
      images: [ { "media_type" => "image/png" } ],
      files: [ { "original_filename" => "notes.md", "size" => 11 } ]
    )

    captured_kwargs = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(*args, **kwargs) { captured_kwargs = kwargs }) do
      assert EnqueuedMessageProcessorService.new(@session).process_next_message
    end

    assert_nil captured_kwargs[:images]
    assert_nil captured_kwargs[:files]
  end

  test "process_next_message passes nil attachments when message has none" do
    @session.enqueued_messages.create!(content: "Plain prompt", position: 1)

    captured_kwargs = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(*args, **kwargs) { captured_kwargs = kwargs }) do
      service = EnqueuedMessageProcessorService.new(@session)
      assert service.process_next_message
    end

    assert captured_kwargs
    assert_nil captured_kwargs[:images]
    assert_nil captured_kwargs[:files]
  end

  # --- Delivery-time re-validation of a queued conflict notice (tadasant/zimmer#835) ---
  #
  # The poller reads GitHub, finds a conflict, and queues the notice because the
  # session is mid-turn or asleep. The row then sits until this turn boundary, and
  # in those minutes the session may have rebased, resolved and force-pushed. The
  # observed cost is not the wasted turn: the resume destroys the bounded self-wake
  # the session is sleeping on, so a session that finds nothing to resolve and ends
  # its turn is left with no trigger and no turn.

  test "a conflict notice whose PR became mergeable is not delivered" do
    message = queue_conflict_notice
    stub_mergeability(:mergeable)

    service = EnqueuedMessageProcessorService.new(@session)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      refute service.process_next_message, "a moot notice must not resume the session"
    end

    assert_equal "undelivered", message.reload.status
    assert_equal "needs_input", @session.reload.status
  end

  test "a suppression is logged against the session, so it reads differently from never sent" do
    queue_conflict_notice
    stub_mergeability(:mergeable)

    EnqueuedMessageProcessorService.new(@session).process_next_message

    log = @session.logs.order(:id).map(&:content).find { |c| c.include?("was not delivered") }
    assert log, "expected a session log entry naming the suppression"
    assert_includes log, "automated_merge_conflict"
  end

  test "a conflict notice against a still-conflicting PR is delivered unchanged" do
    message = queue_conflict_notice
    stub_mergeability(:conflicting)

    captured_prompt = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(_id, prompt, **_kwargs) { captured_prompt = prompt }) do
      assert EnqueuedMessageProcessorService.new(@session).process_next_message
    end

    assert_equal message.content, captured_prompt
    refute EnqueuedMessage.exists?(message.id), "a delivered message is destroyed, not retired"
    assert_equal "running", @session.reload.status
  end

  test "a conflict notice is delivered when mergeability cannot be re-read" do
    message = queue_conflict_notice
    stub_mergeability(:unknown)

    assert EnqueuedMessageProcessorService.new(@session).process_next_message
    refute EnqueuedMessage.exists?(message.id)
    assert_equal "running", @session.reload.status
  end

  test "a re-read that raises does not cost the session its message" do
    message = queue_conflict_notice
    GithubPullRequestMergeability.stubs(:read).raises(RuntimeError, "gh exploded")

    assert EnqueuedMessageProcessorService.new(@session).process_next_message
    refute EnqueuedMessage.exists?(message.id)
  end

  test "a suppressed notice does not hold up the ordinary message behind it" do
    stale_notice = queue_conflict_notice
    follow_up = @session.enqueued_messages.create!(content: "Human follow-up", position: 2)
    stub_mergeability(:mergeable)

    captured_prompt = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(_id, prompt, **_kwargs) { captured_prompt = prompt }) do
      assert EnqueuedMessageProcessorService.new(@session).process_next_message
    end

    assert_equal "Human follow-up", captured_prompt
    assert_equal "undelivered", stale_notice.reload.status
    refute EnqueuedMessage.exists?(follow_up.id)
  end

  # An explicit "send this one now" has already decided which row to deliver.
  # Sessions::InterruptService validates that row, promotes it to the front and
  # reports success naming its content — so a sweep that retired it under the
  # service would have it deliver the next message while logging the promoted
  # one as sent.
  test "revalidate: false skips the sweep entirely and delivers the notice" do
    message = queue_conflict_notice
    GithubPullRequestMergeability.expects(:read).never

    service = EnqueuedMessageProcessorService.new(@session, revalidate: false)
    assert service.process_next_message

    refute EnqueuedMessage.exists?(message.id)
  end

  test "a stale notice behind an ordinary message is retired too, not just the head" do
    follow_up = @session.enqueued_messages.create!(content: "Human follow-up", position: 1)
    stale_notice = queue_conflict_notice(position: 2)
    stub_mergeability(:mergeable)

    captured_prompt = nil
    AgentSessionJob.stub(:enqueue_with_prompt, ->(_id, prompt, **_kwargs) { captured_prompt = prompt }) do
      assert EnqueuedMessageProcessorService.new(@session).process_next_message
    end

    assert_equal "Human follow-up", captured_prompt
    refute EnqueuedMessage.exists?(follow_up.id)
    assert_equal "undelivered", stale_notice.reload.status
  end

  test "two stale notices in one queue are both retired" do
    first = queue_conflict_notice(position: 1)
    second = @session.enqueued_messages.create!(
      content: AutomatedPrompts.merge_conflict_message("https://github.com/tadasant/zimmer/pull/999"),
      position: 2,
      origin: "automated_merge_conflict"
    )
    GithubPullRequestMergeability.stubs(:read).returns(:mergeable)

    refute EnqueuedMessageProcessorService.new(@session).process_next_message

    assert_equal "undelivered", first.reload.status
    assert_equal "undelivered", second.reload.status
  end

  # The sweep mirrors the state gate inside the claim transaction. A session in
  # any other state cannot be handed a message however the sweep goes, so paying
  # for a `gh` round trip and retiring a notice nobody was going to claim is
  # work done for nothing.
  test "a session that cannot take a message is not swept" do
    queue_conflict_notice
    @session.update!(status: :failed)
    GithubPullRequestMergeability.expects(:read).never

    refute EnqueuedMessageProcessorService.new(@session).process_next_message
  end

  test "an ordinary caller message is never re-read against GitHub" do
    @session.enqueued_messages.create!(content: "Plain prompt", position: 1)
    GithubPullRequestMergeability.expects(:read).never

    assert EnqueuedMessageProcessorService.new(@session).process_next_message
  end

  private

  CONFLICT_PR_URL = "https://github.com/tadasant/zimmer/pull/834".freeze

  def queue_conflict_notice(position: 1)
    @session.enqueued_messages.create!(
      content: AutomatedPrompts.merge_conflict_message(CONFLICT_PR_URL),
      position: position,
      origin: "automated_merge_conflict"
    )
  end

  def stub_mergeability(answer)
    GithubPullRequestMergeability.stubs(:read).with(CONFLICT_PR_URL).returns(answer)
  end
end
