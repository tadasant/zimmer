require "test_helper"
require "minitest/mock"
require "mocha/minitest"

# SessionTitleJob both names a session and auto-sorts it into a category, from a
# single headless inference over the early transcript. These tests cover:
# - title-only behavior (no candidate categories) and the deterministic
#   prompt/failure-reason fallbacks,
# - category matching/uncategorized outcomes (migrated from the former
#   SessionCategoryInferenceJob), and
# - the combined transcript path that produces BOTH a title and a category in
#   one inference call.
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

  test "should use default queue" do
    job = SessionTitleJob.new(@session.id)
    assert_equal "default", job.queue_name
  end

  # === Title behavior ========================================================

  test "should skip when session has a manually set title and no category work" do
    # Manual title (no auto_generated_title flag) and no candidate categories:
    # there is nothing for the job to do, and inference must not run.
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

    # No candidate categories, so the inference service must not be called at
    # all — the title is deterministic and there is nothing to categorize into.
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
      assert_includes warning_log.content, "Failed to generate title/category"
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

  # === Combined title + category from the transcript =========================

  test "infers both the title and the category from the transcript in one call" do
    research = Category.create!(name: "Research", description: "Investigations, spikes, and exploratory analysis")
    Category.create!(name: "Bugs", description: "Defects and regressions to fix")

    @session.update!(
      category_id: nil,
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Investigate the slow checkout query",
      transcript: transcript_jsonl("Investigate the slow checkout query", "Looking into the query plan and indexes.")
    )

    captured_prompt = nil
    @mock_inference_service.expects(:generate).with do |prompt, **|
      captured_prompt = prompt
      true
    end.returns("TITLE: Investigate Slow Checkout Query\nCATEGORY: Research")

    # Two timeline entries: one for the title, one for the category assignment.
    assert_difference "@session.logs.count", 2 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Investigate Slow Checkout Query", @session.title
    assert_equal research.id, @session.category_id

    # The single combined prompt asks for both fields and lists the candidates.
    assert_includes captured_prompt, "TITLE:"
    assert_includes captured_prompt, "CATEGORY:"
    assert_includes captured_prompt, "Research"
    assert_includes captured_prompt, "Bugs"
  end

  test "sets the title from the transcript but leaves the session uncategorized when the category answer is NONE" do
    Category.create!(name: "Research", description: "Investigations and analysis")

    @session.update!(
      category_id: nil,
      title: "Session #{@session.id}",
      metadata: { "auto_generated_title" => true },
      prompt: "Write up notes",
      transcript: transcript_jsonl("Write up notes", "Jotting down some unstructured notes.")
    )

    @mock_inference_service.expects(:generate).returns("TITLE: Write Up Notes\nCATEGORY: NONE")

    assert_difference "@session.logs.count", 2 do
      @job.perform(@session.id)
    end

    @session.reload
    assert_equal "Write Up Notes", @session.title
    assert_nil @session.category_id
    assert_includes @session.logs.last.content, "NONE"
  end

  # === Category matching (no transcript; inferred from the prompt) ===========
  #
  # These cover the matching/uncategorized logic migrated from the former
  # SessionCategoryInferenceJob. A manual title is set so no title work runs and
  # the only timeline entry is the category outcome.

  def setup_category_session
    @session.update!(
      category_id: nil,
      title: "Investigate the slow checkout query",
      metadata: {},
      prompt: "Investigate the slow checkout query and add an index",
      transcript: nil
    )
    @research = Category.create!(name: "Research", description: "Investigations, spikes, and exploratory analysis")
    @bugs = Category.create!(name: "Bugs", description: "Defects and regressions to fix")
  end

  test "assigns the category when inference returns a matching name" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("Research")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_equal @research.id, @session.reload.category_id
    assert_includes @session.logs.last.content, "Research"
  end

  test "category matching is case-insensitive and tolerant of surrounding whitespace" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("  bugs  ")

    @job.perform(@session.id)

    assert_equal @bugs.id, @session.reload.category_id
  end

  test "matches a category the model wrapped in extra words and punctuation" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("The best fit is Research.")

    @job.perform(@session.id)

    assert_equal @research.id, @session.reload.category_id
  end

  test "matches a category the model decorated with markdown" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("**Bugs**")

    @job.perform(@session.id)

    assert_equal @bugs.id, @session.reload.category_id
  end

  test "does not guess when the answer mentions more than one category name" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("Either Research or Bugs")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_nil @session.reload.category_id
    assert_equal "info", @session.logs.last.level
    assert_includes @session.logs.last.content, "matched no category"
  end

  test "leaves the session uncategorized and logs when inference answers NONE" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("NONE")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_nil @session.reload.category_id
    log = @session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "NONE"
  end

  test "leaves the session uncategorized and logs when the answer matches no category" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("Marketing")

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_nil @session.reload.category_id
    log = @session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "matched no category"
    assert_includes log.content, "Marketing"
  end

  test "leaves the session uncategorized and logs when inference returns nil (timeout/error)" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns(nil)

    assert_difference "@session.logs.count", 1 do
      @job.perform(@session.id)
    end

    assert_nil @session.reload.category_id
    log = @session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "no answer"
  end

  test "skips inference when the session already has a category" do
    setup_category_session
    @session.update!(category_id: @bugs.id)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    assert_equal @bugs.id, @session.reload.category_id
  end

  test "skips inference when the session has no prompt and a manual title" do
    setup_category_session
    @session.update!(prompt: nil)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    assert_nil @session.reload.category_id
  end

  test "excludes frozen categories from candidates" do
    setup_category_session
    # Freeze every category: there are then no valid targets, so inference must
    # never run and the session stays uncategorized.
    Category.update_all(is_frozen: true)
    @mock_inference_service.expects(:generate).never

    @job.perform(@session.id)

    assert_nil @session.reload.category_id
  end

  test "a frozen category is not a selectable target even if inference names it" do
    setup_category_session
    # Freeze Research, then have the model answer "Research" anyway. Because the
    # frozen category was never a candidate, it cannot be matched.
    @research.update!(is_frozen: true)
    @mock_inference_service.expects(:generate).returns("Research")

    @job.perform(@session.id)

    assert_nil @session.reload.category_id
    assert_includes @session.logs.last.content, "matched no category"
  end

  test "logs a warning and does not raise when assignment hits an unexpected error" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("Research")
    Session.any_instance.stubs(:update!).raises(StandardError, "boom")

    assert_difference "@session.logs.count", 1 do
      assert_nothing_raised { @job.perform(@session.id) }
    end

    assert_equal "warning", @session.logs.last.level
    assert_includes @session.logs.last.content, "Failed to generate title/category"
  end

  test "does not raise even when recording the failure note also fails" do
    setup_category_session
    @mock_inference_service.expects(:generate).returns("Research")
    Session.any_instance.stubs(:update!).raises(StandardError, "boom")
    Log.any_instance.stubs(:save!).raises(StandardError, "log write failed")

    assert_nothing_raised { @job.perform(@session.id) }
  end
end
