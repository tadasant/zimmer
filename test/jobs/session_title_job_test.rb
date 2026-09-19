require "test_helper"
require "minitest/mock"
require "mocha/minitest"

# SessionTitleJob names a session from a single headless inference over the
# early transcript. These tests cover the inference path, its deterministic
# prompt and failure-reason fallbacks, and the response parsing.
class SessionTitleJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:waiting)
    @job = SessionTitleJob.new
    @mock_inference_service = mock("HeadlessInferenceService")
    @job.inference_service = @mock_inference_service
  end

  # A two-message JSONL transcript (claude_code shape) for the given user and
  # assistant lines.
  def transcript_jsonl(user_text, assistant_text)
    <<~JSONL
      {"type":"user","timestamp":"2024-01-01T10:00:00Z","message":{"role":"user","content":#{user_text.to_json}}}
      {"type":"assistant","timestamp":"2024-01-01T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":#{assistant_text.to_json}}]}}
    JSONL
  end

  test "should enqueue job" do
    assert_enqueued_with(job: SessionTitleJob, args: [ @session.id ]) do
      SessionTitleJob.perform_later(@session.id)
    end
  end

  test "should use the inference queue" do
    job = SessionTitleJob.new(@session.id)
    assert_equal "inference", job.queue_name
  end

  # === Title behavior ========================================================

  test "should skip when session has a manually set title" do
    # Manual title (no auto_generated_title flag): there is nothing for the job
    # to do, and inference must not run.
    @session.update!(title: "Existing Title", metadata: {})
    @mock_inference_service.expects(:generate).never

    assert_no_difference "@session.logs.count" do
      @job.perform(@session.id)
    end

    assert_equal "Existing Title", @session.reload.title
  end

  test "should generate a title from the transcript" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Fix the authentication bug in the login system",
      transcript: transcript_jsonl("Fix the authentication bug in the login system", "I'll help you fix the authentication bug.")
    )

    @mock_inference_service.expects(:generate).returns("Fix Authentication Login Bug")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Fix Authentication Login Bug", @session.title
    assert_not @session.metadata["auto_generated_title"]
    assert_includes @session.logs.last.content, "Generated session title from transcript"
  end

  test "should run the inference with the cheap model and a multi-line response" do
    @session.update!(
      metadata: { "auto_generated_title" => true },
      prompt: "Build a user auth system",
      transcript: transcript_jsonl("Build a user auth system", "I'll build the user auth system.")
    )

    captured = {}
    @mock_inference_service.expects(:generate).with do |prompt, **opts|
      captured[:prompt] = prompt
      captured[:opts] = opts
      true
    end.returns("User Authentication System")

    @job.perform(@session.id)

    assert_equal "haiku", captured[:opts][:model]
    assert_equal false, captured[:opts][:single_line]
    assert_equal SessionTitleJob::INFERENCE_TIMEOUT, captured[:opts][:timeout]
    assert_equal "User Authentication System", @session.reload.title
  end

  test "should set deterministic title from failure reason for a failed MCP session" do
    # A misleading-transcript guard: when the session has failed due to an MCP
    # connection failure, the title must reflect the true failure reason rather
    # than an LLM summary of the crash-polluted transcript.
    @session.update!(
      status: :failed,
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true, "failure_reason" => "mcp_connection_failed" },
      custom_metadata: { "mcp_failed_servers" => [ { "name" => "good-eggs", "error" => "spawn ENOENT" } ] },
      prompt: "Plan my meals",
      transcript: transcript_jsonl("Plan my meals", "Session limit reached")
    )

    # The title is deterministic, so the inference service must not be called
    # at all.
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    @session.reload
    assert_equal "MCP server(s) failed to connect: good-eggs", @session.title
    assert_not @session.metadata["auto_generated_title"]
  end

  test "should fallback to a prompt-based title when there is no transcript" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Fix the authentication bug in the login system",
      transcript: nil
    )
    # No transcript: the title is derived deterministically from the prompt
    # without paying for an inference call.
    @mock_inference_service.expects(:generate).never

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Fix the authentication bug in the login system", @session.title
    assert_not @session.metadata["auto_generated_title"]
    assert_includes @session.logs.last.content, "Generated session title from prompt fallback"
  end

  # === The chat bubble's composed prompt (issue #809) =========================

  # The prompt a chat-bubble session hands the runtime, and the human's words
  # the controller keeps beside it in metadata.
  CHAT_BUBBLE_HUMAN_PROMPT = "Fix the broken avatar upload on the profile page".freeze
  CHAT_BUBBLE_COMPOSED_PROMPT = <<~PROMPT.strip
    <context-about-user's-current-view>
    URL: https://zimmer.example.com/sessions/12265

    Sessions index, filtered to running sessions.
    </context-about-user's-current-view>

    #{CHAT_BUBBLE_HUMAN_PROMPT}
  PROMPT

  def make_chat_bubble_session(session, created_at: nil)
    session.update!(
      title: "Session #{session.id}",
      slug: nil,
      metadata: {
        "auto_generated_title" => true,
        "source" => "chat_bubble",
        "original_prompt" => CHAT_BUBBLE_HUMAN_PROMPT,
        "current_url" => "https://zimmer.example.com/sessions/12265"
      },
      prompt: CHAT_BUBBLE_COMPOSED_PROMPT,
      transcript: nil
    )
    session.update_columns(created_at: created_at) if created_at
    session
  end

  test "titles a chat-bubble session from the human's prompt, not the composed one" do
    # The chat bubble prepends a page-context block to the prompt the runtime
    # receives and keeps the human's own text in metadata. Titling off the
    # composed prompt names every such session after the block, and truncates
    # mid-URL doing it.
    make_chat_bubble_session(@session)
    @mock_inference_service.expects(:generate).never

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal CHAT_BUBBLE_HUMAN_PROMPT, @session.title
    refute_includes @session.title, "context-about-user"
    assert_includes @session.logs.last.content, "Generated session title from prompt fallback"
  end

  test "slugs a chat-bubble session from the human's prompt, not the composed one" do
    # The slug is derived from the title at the moment the title is applied, so
    # a title taken from the context block carries the block into the URL.
    make_chat_bubble_session(@session)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    slug = @session.reload.slug
    assert slug.start_with?("fix-the-broken-avatar-upload-on-the-profile-page-"),
      "expected a slug from the human's words, got #{slug.inspect}"
    refute_includes slug, "context-about-user"
    refute_includes slug, "https-zimmer"
  end

  test "falls back to the human's prompt when transcript inference returns no title" do
    make_chat_bubble_session(@session)
    @session.update!(transcript: transcript_jsonl(CHAT_BUBBLE_HUMAN_PROMPT, "On it."))
    @mock_inference_service.expects(:generate).returns(nil)

    @job.perform(@session.id)

    @session.reload
    assert_equal CHAT_BUBBLE_HUMAN_PROMPT, @session.title
    refute_includes @session.slug, "context-about-user"
  end

  test "two chat-bubble sessions created in the same minute get distinct slugs" do
    # Same composed prompt, same human prompt, same creation minute: the slug
    # base is identical for both, and slugs are unique-indexed.
    created_at = Time.zone.parse("2026-09-02 14:35:00")
    first = make_chat_bubble_session(sessions(:waiting), created_at: created_at)
    second = make_chat_bubble_session(sessions(:needs_input), created_at: created_at)
    @mock_inference_service.expects(:generate).never

    @job.perform(first.id)
    @job.perform(second.id)

    first_slug = first.reload.slug
    second_slug = second.reload.slug
    assert_equal "fix-the-broken-avatar-upload-on-the-profile-page-20260902-1435", first_slug
    assert_equal "#{first_slug}-1", second_slug
  end

  test "keeps titling from the prompt when there is no original_prompt" do
    # Every entry point other than the chat bubble composes nothing, so the
    # prompt column is the human's own words and remains the fallback.
    @session.update!(
      title: "Session #{@session.id}",
      slug: nil,
      metadata: { "auto_generated_title" => true, "source" => "trigger" },
      prompt: "Sweep the backlog for stale issues",
      transcript: nil
    )
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    @session.reload
    assert_equal "Sweep the backlog for stale issues", @session.title
    assert @session.slug.start_with?("sweep-the-backlog-for-stale-issues-")
  end

  test "should run for old sessions without a title" do
    # Old sessions don't have the auto_generated_title flag.
    @session.update!(
      title: nil,
      metadata: {},
      prompt: "Implement user registration feature",
      transcript: nil
    )
    @mock_inference_service.expects(:generate).never

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_equal "Implement user registration feature", @session.reload.title
  end

  test "should handle session not found gracefully" do
    assert_nothing_raised do
      SessionTitleJob.perform_now(999999)
    end
  end

  test "should handle errors gracefully without failing the job" do
    @session.update!(metadata: { "auto_generated_title" => true }, transcript: nil)

    job = SessionTitleJob.new(@session.id)
    job.stub(:generate_title_from_prompt, ->(*) { raise StandardError.new("Test error") }) do
      assert_difference "@session.logs.count", 1 do
        job.perform(@session.id)
      end

      warning_log = @session.reload.logs.last
      assert_equal "warning", warning_log.level
      assert_includes warning_log.content, "Failed to generate title"
    end
  end

  test "should not update session when no title can be generated" do
    @session.update!(metadata: { "auto_generated_title" => true }, prompt: "Valid prompt", transcript: nil)

    job = SessionTitleJob.new(@session.id)
    job.stub(:generate_title_from_prompt, ->(*) { nil }) do
      assert_no_difference "@session.logs.count" do
        job.perform(@session.id)
      end

      assert_nil @session.reload.title
    end
  end

  test "should truncate long prompts to 60 characters" do
    long_prompt = "This is a very long prompt that should be truncated to sixty characters maximum length for the title"
    @session.update!(metadata: { "auto_generated_title" => true }, prompt: long_prompt, transcript: nil)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    @session.reload
    assert @session.title.length <= 60
    assert @session.title.ends_with?("...")
  end

  test "should extract first sentence if shorter than 60 chars" do
    prompt_with_sentences = "Fix the bug. This is additional context that should not be included in the title."
    @session.update!(metadata: { "auto_generated_title" => true }, prompt: prompt_with_sentences, transcript: nil)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    assert_equal "Fix the bug", @session.reload.title
  end

  test "should generate slug after setting title" do
    @session.update!(metadata: { "auto_generated_title" => true }, prompt: "Fix authentication bug", slug: nil, transcript: nil)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    @session.reload
    assert_equal "Fix authentication bug", @session.title
    assert_not_nil @session.slug
    assert @session.slug.starts_with?("fix-authentication-bug-")
  end

  test "should generate title from a Codex normalized transcript instead of the injected prompt context" do
    codex_transcript = <<~JSONL
      {"timestamp":"2026-06-04T15:45:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix async Codex session title generation"}]}}
      {"timestamp":"2026-06-04T15:45:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I updated the title job to use normalized transcript messages."}]}}
    JSONL

    @session.update!(
      agent_runtime: "codex",
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "<context-about-user's-current-view>\nURL: https://zimmer.example.com/sessions/7264\n\nPlease help with the current page",
      transcript: codex_transcript
    )

    captured_prompt = nil
    fake_inference_service = Object.new
    fake_inference_service.define_singleton_method(:generate) do |prompt, **|
      captured_prompt = prompt
      "Fix Codex Session Titles"
    end
    @job.inference_service = fake_inference_service

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Fix Codex Session Titles", @session.title
    assert_includes captured_prompt, "User: Fix async Codex session title generation"
    assert_includes captured_prompt, "Assistant: I updated the title job to use normalized transcript messages."
    refute_includes captured_prompt, "<context-about-user's-current-view>"
    refute_includes @session.title, "context-about-user"

    log = @session.logs.last
    assert_equal "info", log.level
    assert_equal "Generated session title from transcript", log.content
  end

  test "should fallback to a prompt-based title when transcript inference returns nil" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Add dark mode support to the application",
      transcript: transcript_jsonl("Add dark mode support", "I'll add dark mode support.")
    )

    @mock_inference_service.expects(:generate).returns(nil)

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Add dark mode support to the application", @session.title
    assert_equal "Generated session title from prompt fallback", @session.logs.last.content
    assert_not @session.metadata["auto_generated_title"]
  end

  test "should handle empty transcript gracefully" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Refactor database queries",
      transcript: ""
    )
    @mock_inference_service.expects(:generate).never

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Refactor database queries", @session.title
    assert_not @session.metadata["auto_generated_title"]
  end

  # === The prompt and the response ==========================================

  test "asks for a labelled title and nothing else" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Investigate the slow checkout query",
      transcript: transcript_jsonl("Investigate the slow checkout query", "Looking into the query plan and indexes.")
    )

    captured_prompt = nil
    @mock_inference_service.expects(:generate).with do |prompt, **|
      captured_prompt = prompt
      true
    end.returns("TITLE: Investigate Slow Checkout Query")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_equal "Investigate Slow Checkout Query", @session.reload.title
    # Pinned byte-for-byte: this is the title half of the prompt the combined
    # title+category call used, kept unchanged when categories were removed, so a
    # drift in it is a change to titling rather than a refactor.
    assert_equal <<~PROMPT, captured_prompt
      You are summarizing a coding-agent session.

      The session context:
      User: Investigate the slow checkout query

      Assistant: Looking into the query plan and indexes.

      Produce the following:
      - TITLE: a concise title (max 6 words, descriptive, action verbs, no quotes or formatting).

      Respond in EXACTLY this format and nothing else:
      TITLE: <title>
    PROMPT
  end

  test "reads the TITLE line even when the model adds other lines around it" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Write up notes",
      transcript: transcript_jsonl("Write up notes", "Jotting down some unstructured notes.")
    )

    @mock_inference_service.expects(:generate).returns("Sure, here it is:\nTITLE: Write Up Notes\nCATEGORY: NONE")

    @job.perform(@session.id)

    assert_equal "Write Up Notes", @session.reload.title
  end

  test "takes an unlabelled one-line answer as the title" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Write up notes",
      transcript: transcript_jsonl("Write up notes", "Jotting down some unstructured notes.")
    )

    @mock_inference_service.expects(:generate).returns("\n  Write Up Notes  \n")

    @job.perform(@session.id)

    assert_equal "Write Up Notes", @session.reload.title
  end

  test "does not raise even when recording the failure note also fails" do
    @session.update!(
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Investigate the slow checkout query",
      transcript: transcript_jsonl("Investigate the slow checkout query", "Looking into it.")
    )
    @mock_inference_service.expects(:generate).returns("TITLE: Investigate Checkout Query")
    Session.any_instance.stubs(:update!).raises(StandardError, "boom")
    Log.any_instance.stubs(:save!).raises(StandardError, "log write failed")

    assert_nothing_raised { @job.perform(@session.id) }
  end
end
