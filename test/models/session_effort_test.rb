require "test_helper"

# Session's `config["effort"]`: normalized on the way in, refused when the
# session's model does not take it, and reported with where it came from.
class SessionEffortTest < ActiveSupport::TestCase
  def build_session(config:, runtime: "claude_code")
    Session.new(
      prompt: "Think hard",
      agent_runtime: runtime,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      config: config
    )
  end

  test "a level the model takes is valid and normalized to lowercase" do
    session = build_session(config: { "model" => "fable", "effort" => " XHigh " })

    assert session.valid?, session.errors.full_messages.to_sentence
    assert_equal "xhigh", session.config["effort"]
  end

  test "a blank effort is dropped so the model default applies" do
    session = build_session(config: { "model" => "fable", "effort" => "  " })

    assert session.valid?
    assert_not session.config.key?("effort")
  end

  test "a level the model does not take is refused with the valid levels" do
    session = build_session(config: { "model" => "fable", "effort" => "ultra" })

    assert_not session.valid?
    assert_match(/"ultra" is not valid for model "fable".*low, medium, high, xhigh, max/, session.errors.full_messages.to_sentence)
  end

  test "an effort on haiku is refused" do
    session = build_session(config: { "model" => "haiku", "effort" => "high" })

    assert_not session.valid?
    assert_match(/"haiku" does not support an effort setting/, session.errors.full_messages.to_sentence)
  end

  test "an effort on a Codex session is refused" do
    session = build_session(runtime: "codex", config: { "model" => "gpt-5.6-terra", "effort" => "high" })

    assert_not session.valid?
    assert_match(/not supported on the codex runtime/, session.errors.full_messages.to_sentence)
  end

  test "a non-string effort is refused" do
    session = build_session(config: { "model" => "fable", "effort" => 3 })

    assert_not session.valid?
    assert_includes session.errors.full_messages, "effort must be a string"
  end

  test "changing the model to one that cannot keep the effort is refused" do
    session = build_session(config: { "model" => "fable", "effort" => "xhigh" })
    session.save!

    assert_not session.update(config: session.config.merge("model" => "haiku"))
    assert_match(/"haiku" does not support an effort setting.*effort is "xhigh"; clear or change it before switching/,
                 session.errors.full_messages.to_sentence)
  end

  test "effort_summary reports an explicit level" do
    session = build_session(config: { "model" => "fable", "effort" => "xhigh" })

    assert_equal({ level: "xhigh", source: "explicit", default: "high", levels: %w[low medium high xhigh max] }, session.effort_summary)
    assert_equal "xhigh", session.effort_override
    assert_equal "xhigh (set explicitly)", session.effort_description
  end

  test "effort_summary reports the model default when none is set" do
    session = build_session(config: { "model" => "opus" })

    assert_equal({ level: "medium", source: "default", default: "medium", levels: %w[low medium high xhigh max] }, session.effort_summary)
    assert_nil session.effort_override
    assert_equal "medium (model default)", session.effort_description
  end

  test "effort_summary on a model without effort has no level" do
    session = build_session(config: { "model" => "haiku" })

    assert_nil session.effort_summary[:level]
    assert_equal "not applicable (this model takes no effort setting)", session.effort_description
  end
end
