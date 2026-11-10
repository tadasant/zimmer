# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class MovePinnedModelsOntoFloatingAliasesTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)

    @entry = PostDeployTask::Registry.find("20261110144745")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  test "moves open Codex and Pi sessions onto the aliases, and nothing else" do
    codex = a_session("codex", "gpt-5.6-terra")
    retired = a_session("codex", "gpt-5.4-mini")
    pi = a_session("pi", "openrouter/anthropic/claude-opus-4.6")
    pinned_pi = a_session("pi", "openrouter/openai/gpt-5.4")
    archived = a_session("codex", "gpt-5.6-sol", status: :archived)
    current = a_session("codex", "terra")
    claude = a_session("claude_code", "opus")

    run, outcome = run_task

    assert_nil outcome
    assert_equal "terra", codex.reload.config["model"]
    assert_equal "luna", retired.reload.config["model"]
    assert_equal "openrouter/~anthropic/claude-opus-latest", pi.reload.config["model"]
    assert_equal "openrouter/openai/gpt-5.4", pinned_pi.reload.config["model"]
    assert_equal "gpt-5.6-sol", archived.reload.config["model"], "a finished session keeps the id it ran with"
    assert_equal "terra", current.reload.config["model"]
    assert_equal "opus", claude.reload.config["model"]
    assert_equal 3, run.stats["sessions"]

    second, = run_task
    assert_equal 0, second.stats["sessions"]
  end

  test "moves a legacy Settings default onto its family" do
    setting = AppSetting.new(default_runtime: "codex")
    setting.save!
    setting.update_columns(default_model: "gpt-5.6-sol")

    run, = run_task

    assert_equal "sol", setting.reload.default_model
    assert_equal 1, run.stats["settings"]
  end

  private

  def run_task
    run = PostDeployTaskRun.create!(version: "#{@entry.version}-#{SecureRandom.hex(4)}", name: @entry.task_name, status: "pending")
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  def a_session(runtime, model, status: :needs_input)
    Session.create!(
      prompt: "work #{SecureRandom.hex(4)}",
      agent_runtime: runtime,
      status: status,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      config: { "model" => model }
    )
  end
end
