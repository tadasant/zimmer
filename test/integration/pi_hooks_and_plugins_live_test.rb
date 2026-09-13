# frozen_string_literal: true

require "test_helper"
require "json"
require "socket"
require "mocha/minitest"
require "ostruct"
require "tmpdir"

# Drives a REAL, pinned `pi` binary through Zimmer's own runtime path, against a
# simulated localhost LLM, and asserts that an AIR hook actually fires.
#
# == Why this exists as a live test rather than a unit test ==
#
# Every claim in this area is a claim about a third party's behavior — Pi's, and
# two Pi extensions' — and a unit test can only assert that Zimmer wrote a file
# it believes in. The PR that added the Pi runtime was explicit that hooks and
# plugins were "not exercised, in any form, and not claimed to work", precisely
# because the packages were unpublished and this could not be run. It can be run
# now, so it is.
#
# == How to run it ==
#
#   PI_E2E=1 PI_EXTENSIONS_DIR=/opt/pi-extensions \
#     bin/rails test test/integration/pi_hooks_and_plugins_live_test.rb
#
# It skips unless PI_E2E is set, so CI (which has no `pi`) is unaffected. It also
# skips, loudly, when the binary or the extensions are absent — a silent pass
# would be worse than no test.
#
# == What is simulated and what is not ==
#
# Only the model provider. `pi` is the real pinned binary, the extensions are the
# real published packages, the hook body is the real catalog artifact, and the
# config comes from PiAirBridge rather than from this file. The provider is a
# Node OpenAI-completions SSE stub bound to 127.0.0.1 — no real provider, no API
# key, no network.
class PiHooksAndPluginsLiveTest < ActiveSupport::TestCase
  # Text the catalog's git-push-ci-reminder hook injects. Finding it in the
  # transcript is the proof: the model saw something only the hook could put there.
  REMINDER_MARKER = "Pushing is not the same as finishing"

  # Text the Claude-dialect hook below injects. Nothing else can produce it.
  PORTABLE_MARKER = "PORTABLE-AIR-HOOK-REACHED-THE-MODEL"

  # The bash command the simulated LLM asks Pi to run. It reads as a `git push` to
  # the hook's matcher without pushing anything.
  #
  # Quoted deliberately: this is byte-for-byte the probe zimmer#1073 ran against a
  # live Pi session, saw come back unmodified, and read as "AIR hooks do not fire on
  # Pi". They fired; the hook's own pattern declined the quote. Driving the probe
  # that produced the wrong verdict is what keeps that verdict from being reachable
  # again.
  SIMULATED_COMMAND = %q(echo "git push origin main")

  setup do
    skip "set PI_E2E=1 to run the live Pi tests" unless ENV["PI_E2E"] == "1"

    @pi_version = `pi --version 2>/dev/null`.strip
    skip "the `pi` binary is not on PATH" if @pi_version.empty?

    missing = PiExtensions.missing
    unless missing.empty?
      flunk "Pi extensions missing from #{PiExtensions::INSTALL_DIR}: #{missing.map(&:to_s).join(', ')}. " \
            "Set PI_EXTENSIONS_DIR, or `npm install --prefix <dir> " \
            "#{PiExtensions.installable.map(&:to_s).join(' ')}`."
    end

    @root = Dir.mktmpdir("pi-live")
    @clone = File.join(@root, "clone")
    @pi_home = File.join(@root, "pi-home")
    FileUtils.mkdir_p([ @clone, @pi_home ])

    @port = free_port
    write_simulated_provider!
    # PiRuntimeAdapter resolves PI_CODING_AGENT_DIR from the clone's .env, so the
    # test's provider declarations reach Pi the same way a session's would.
    File.write(File.join(@clone, ".env"), "PI_CODING_AGENT_DIR=#{@pi_home}\n")

    @session = sessions(:active_session)
    # Pi takes Zimmer's id verbatim via `--session-id`, and PiTranscriptSource
    # locates the transcript by it — a blank one makes every lookup miss.
    @session.update!(
      agent_runtime: "pi",
      session_id: SecureRandom.uuid,
      catalog_hooks: [],
      catalog_plugins: []
    )
  end

  teardown do
    stop_simulated_llm
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  test "a hook the session selected fires during a real Pi run and reaches the model" do
    @session.update!(catalog_hooks: [ "git-push-ci-reminder" ])

    run_pi!

    assert_includes stderr_log, "[pi-hooks] loaded 1 hook(s)",
      "pi-hooks did not load the generated index:\n#{stderr_log}"
    assert_includes tool_result_text, REMINDER_MARKER,
      "the hook did not rewrite the tool result the model reads:\n#{tool_result_text}"
    # `content` REPLACES the tool result on Pi, so a hook that forgot to carry the
    # original through would hide the command's real output from the model.
    assert_includes tool_result_text, "git push origin main",
      "the hook discarded the command's own output"
  end

  # The reason `PiExtensions::REGISTRY` pins 0.2.0 rather than 0.1.0.
  #
  # AIR specifies no stdin schema for a hook body and no schema for what it writes
  # back, so what a *portable* AIR hook is written against is whatever AIR's
  # reference adapter registers it with — Claude Code. Such a hook reads
  # `tool_name` / `tool_input` and answers with `hookSpecificOutput.additionalContext`,
  # and it never mentions Pi. Below 0.2.0 `@tadasant/pi-hooks` sent only its own
  # Pi-native naming and honored only its own `{"content": ...}` reply, so that hook
  # loaded, matched, spawned, exited 0 — and everything it wrote was discarded. This
  # test fails against 0.1.0 and passes against 0.2.0, which is the whole content of
  # the version floor.
  #
  # The catalog's own hook cannot show this: it branches on `PI_HOOK=1` and speaks
  # the Pi dialect, which worked all along. So the body here is written fresh, and
  # the generated index is repointed at it — the bridge's own output is already
  # covered by the test above.
  test "a portable AIR hook that speaks only Claude Code's dialect still reaches the model" do
    # No catalog selection: the generated index is replaced wholesale below, so the
    # only hook in this run is the portable one and the marker has one possible source.
    run_pi! { install_claude_dialect_hook! }

    assert_includes stderr_log, "[pi-hooks] loaded 1 hook(s)",
      "pi-hooks did not load the repointed index:\n#{stderr_log}"
    assert_includes tool_result_text, PORTABLE_MARKER,
      "the portable hook's additionalContext never reached the model — this is the " \
      "silent no-op @tadasant/pi-hooks 0.2.0 fixes:\n#{tool_result_text}"
    # `additionalContext` ADDS; it must not eat the command's own output the way a
    # substituting `content` would.
    assert_includes tool_result_text, "git push origin main",
      "appending the hook's context discarded the command's own output"
  end

  test "an AIR plugin's bundled hook activates during a real Pi run" do
    @session.update!(catalog_plugins: [ "ci-workflow" ])

    run_pi!

    assert_includes stderr_log, "[pi-plugins] activated 1 plugin(s): @local/ci-workflow",
      "pi-plugins did not resolve the generated plugin index:\n#{stderr_log}"
    assert_includes stderr_log, "1 hook(s)"
    # The hook reached Pi ONLY through the plugin: pi-hooks was handed an empty
    # index, so a reminder in the transcript cannot have come from the direct path.
    assert_includes stderr_log, "[pi-hooks] loaded 0 hook(s)"
    assert_includes tool_result_text, REMINDER_MARKER
  end

  # A plugin's own manifest bundles a skill and (for others in the catalog) MCP
  # servers, both of which have a different owner on Pi. The generated entry is
  # what keeps the extension from activating them a second time.
  test "the plugin's skills and MCP servers are not activated a second time" do
    @session.update!(catalog_plugins: [ "ci-workflow" ])

    run_pi!

    assert_includes stderr_log, "0 skill path(s)"
    assert_includes stderr_log, "0 MCP server(s)"
    assert_not File.exist?(File.join(@clone, ".pi", "mcp.json")),
      "pi-plugins wrote its own MCP config; PiMcpConfigPostProcessor owns .mcp.json"
  end

  # Pi exits 0 when the MODEL call fails, so before PiRetryStrategy#terminal_api_error
  # this took ProcessLifecycleManager's success branch and parked the session as a
  # finished turn the model never answered.
  test "a provider failure fails the session instead of parking it as a completed turn" do
    stop_simulated_llm
    start_simulated_llm(mode: :error)

    manager = ProcessLifecycleManager.new(session: @session)
    result = manager.spawn(prompt: "say hi", working_dir: @clone, model: "sim/sim-model")
    assert result.success, "spawn failed: #{result.error}"

    _pid, status = Process.waitpid2(result.pid)
    assert_equal 0, status.exitstatus, "Pi is expected to exit 0 on a provider error"

    decision = manager.handle_exit(status, working_dir: @clone)

    assert_equal :failed, decision.action,
      "a turn whose model call 401'd must not be reported as a completed turn. " \
      "Exit handling logged:\n#{@session.reload.logs.last(10).map(&:content).join("\n")}"
  end

  # The other half of #856, end to end through the real binary: a 5xx is a
  # transient failure Pi could not outlast, and Zimmer resumes the session with
  # backoff instead of ending it. Nothing here is a fixture — the real `pi`
  # writes the error, PiTurnError classifies it, ApiErrorRetryService decides,
  # and the respawn is a real process.
  test "a 5xx resumes the session with backoff instead of failing it" do
    stop_simulated_llm
    start_simulated_llm(mode: :server_error)

    # With the log buffer AgentSessionJob passes: the retry services log through it,
    # unlike the terminal-error path the 401 test above takes.
    log_buffer = LogBuffer.new(@session)
    manager = ProcessLifecycleManager.new(session: @session, log_buffer: log_buffer)
    result = manager.spawn(prompt: "say hi", working_dir: @clone, model: "sim/sim-model")
    assert result.success, "spawn failed: #{result.error}"

    _pid, status = Process.waitpid2(result.pid)
    assert_equal 0, status.exitstatus, "Pi is expected to exit 0 on a provider error"

    decision = manager.handle_exit(status, working_dir: @clone)
    log_buffer.flush

    assert_equal :continue, decision.action,
      "a 500 must be retried, not ended. Exit handling logged:\n" \
      "#{@session.reload.logs.last(10).map(&:content).join("\n")}"
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
    assert_match(/API server error detected - attempting auto-retry 1\/6/,
      @session.logs.map(&:content).join("\n"))
  ensure
    # The retry spawned a real `pi`; do not leave it running past the test.
    pid = @session&.reload&.metadata&.dig("process_pid")
    (Process.kill("TERM", -Process.getpgid(pid)) rescue nil) if pid
  end

  # The quota-wall half of #856, end to end through the real binary: an
  # OpenRouter-shaped 402 parks the session instead of failing it, the scheduler
  # fires the re-check, and — balance restored — the resumed turn completes on the
  # same Pi session and ends the streak. Only the provider and the clock are
  # simulated.
  test "a 402 parks the session, and the re-check resumes it once the balance is back" do
    stop_simulated_llm
    start_simulated_llm(mode: :insufficient_credits)

    log_buffer = LogBuffer.new(@session)
    manager = ProcessLifecycleManager.new(session: @session, log_buffer: log_buffer)
    result = manager.spawn(prompt: "say hi", working_dir: @clone, model: "sim/sim-model")
    assert result.success, "spawn failed: #{result.error}"
    _pid, status = Process.waitpid2(result.pid)
    assert_equal 0, status.exitstatus, "Pi is expected to exit 0 on a provider error"

    decision = manager.handle_exit(status, working_dir: @clone)
    log_buffer.flush

    assert_equal :needs_input, decision.action,
      "a quota wall must park, not fail. Exit handling logged:\n" \
      "#{@session.reload.logs.last(10).map(&:content).join("\n")}"
    assert_match(/Provider quota wall — session parked/, decision.error_message)
    assert_equal 0, ApiErrorRetryService::BUDGET.count_for(@session.reload)
    assert_equal 1, ProviderQuotaWallPark.streak(@session)["parks"]

    @session.pause!
    assert @session.reload.waiting?, "the park must come to rest asleep"

    # The balance is topped up while the session sleeps.
    stop_simulated_llm
    start_simulated_llm(mode: :tool_call)

    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-live-quota-wall"))
    travel_to(16.minutes.from_now) { ScheduleTriggerJob.perform_now }
    prompt = @session.reload.metadata["pending_follow_up_prompt"]
    assert AutomatedPrompts.system_recovery?(prompt), "the re-check did not resume the session"

    # What the enqueued job does with that prompt: re-invoke Pi on the same session id.
    @session.update!(status: :running)
    resumed = manager.spawn(prompt: prompt, working_dir: @clone, model: "sim/sim-model")
    assert resumed.success, "resume failed: #{resumed.error}"
    _pid, status = Process.waitpid2(resumed.pid)

    decision = manager.handle_exit(status, working_dir: @clone)
    log_buffer.flush

    assert_equal :needs_input, decision.action
    assert_nil decision.error_message, "the resumed turn completed, so nothing is wrong"
    assert_nil ProviderQuotaWallPark.streak(@session.reload), "a completed turn ends the streak"
    assert_match(/Process exited successfully/, @session.logs.map(&:content).join("\n"))
  end

  private

  # Spawn Pi exactly as a session would: PiAirBridge generates the config,
  # PiRuntimeAdapter builds the command line and the environment.
  #
  # The optional block runs after the bridge has written and before Pi starts, for
  # the one test that needs an index naming a hook body the catalog does not hold.
  def run_pi!
    AirPrepareService.new(
      session: @session, working_directory: @clone, file_system: RealFileSystemAdapter.new
    ).send(:artifact_bridge).write!
    yield if block_given?

    adapter = PiRuntimeAdapter.new
    result = adapter.execute(
      prompt: "run the command",
      session_id: @session.session_id,
      working_dir: @clone,
      model: "sim/sim-model"
    )
    Process.waitpid(result.fetch(:pid))
    @stderr_log_path = result.fetch(:stderr_log_path)
  end

  # Repoint the generated hooks index at a hook body that knows only Claude Code's
  # half of the contract. Same index shape PiAirBridge writes — `{ "<short id>":
  # { title, description, path } }` — so pi-hooks cannot tell it was not generated.
  def install_claude_dialect_hook!
    dir = File.join(@root, "portable-hook")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "HOOK.json"), JSON.generate(
      "event" => "post_tool_call", "matcher" => "Bash",
      "command" => "node", "args" => [ "./portable.mjs" ], "timeout_seconds" => 10
    ))
    # Deliberately no PI_HOOK branch and no `content` reply: this is what an AIR
    # hook written for the ecosystem at large looks like.
    File.write(File.join(dir, "portable.mjs"), <<~JS)
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(chunk);
      let payload;
      try { payload = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { process.exit(0); }
      if (String(payload?.tool_name ?? "").toLowerCase() !== "bash") process.exit(0);
      if (!String(payload?.tool_input?.command ?? "").includes("git push")) process.exit(0);
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: #{PORTABLE_MARKER.inspect} },
      }));
    JS

    index = File.join(@clone, PiAirBridge::CONFIG_DIR, PiAirBridge::HOOKS_INDEX_FILENAME)
    File.write(index, JSON.generate(
      "portable-air-hook" => {
        "title" => "Portable AIR hook", "description" => "Speaks Claude Code's dialect only.",
        "path" => dir
      }
    ))
  end

  def stderr_log
    File.read(@stderr_log_path)
  end

  # The text of the tool result Pi recorded — what the model actually read back.
  def tool_result_text
    transcript = Dir.glob(
      File.join(PiTranscriptSource.session_directory(working_directory: @clone), "*.jsonl")
    ).first
    assert transcript, "Pi wrote no session transcript"

    File.readlines(transcript).filter_map { |line| JSON.parse(line) rescue nil }
      .filter_map { |event| event.dig("message") }
      .select { |message| message["role"] == "toolResult" }
      .flat_map { |message| Array(message["content"]) }
      .filter_map { |part| part["text"] }
      .join("\n")
  end

  def write_simulated_provider!
    File.write(File.join(@pi_home, "models.json"), JSON.pretty_generate(
      "providers" => {
        "sim" => {
          "name" => "Simulated Local LLM",
          "baseUrl" => "http://127.0.0.1:#{@port}/v1",
          "api" => "openai-completions",
          "apiKey" => "sim-not-a-real-key",
          "compat" => { "supportsDeveloperRole" => false, "supportsReasoningEffort" => false },
          "models" => [ {
            "id" => "sim-model", "name" => "Sim Model", "reasoning" => false,
            "input" => [ "text" ], "contextWindow" => 128_000, "maxTokens" => 4096,
            "cost" => { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 }
          } ]
        }
      }
    ))
    File.write(File.join(@pi_home, "auth.json"), JSON.generate(
      "sim" => { "type" => "api_key", "key" => "sim-not-a-real-key" }
    ))
    start_simulated_llm(mode: :tool_call)
  end

  # A minimal OpenAI-completions SSE server. In :tool_call mode the first request
  # returns a `bash` tool call and the second a closing message; in :error mode
  # every request is a 401, which is what Pi records as `stopReason: "error"`.
  def start_simulated_llm(mode:)
    script = File.join(@root, "sim_llm_#{mode}.mjs")
    File.write(script, simulated_llm_source(mode))
    @llm_pid = Process.spawn("node", script, out: File::NULL, err: File::NULL)
    wait_for_port!
  end

  def stop_simulated_llm
    return unless @llm_pid

    Process.kill("TERM", @llm_pid)
    Process.waitpid(@llm_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @llm_pid = nil
  end

  def wait_for_port!
    40.times do
      TCPSocket.new("127.0.0.1", @port).close
      return true
    rescue Errno::ECONNREFUSED
      sleep 0.25
    end
    flunk "the simulated LLM never came up on 127.0.0.1:#{@port}"
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def simulated_llm_source(mode)
    <<~JS
      import { createServer } from "node:http";
      const PORT = #{@port};
      const MODE = #{mode.to_s.inspect};
      let turn = 0;
      const chunk = (delta, finish) => ({
        id: "chatcmpl-sim", object: "chat.completion.chunk",
        created: Math.floor(Date.now() / 1000), model: "sim-model",
        choices: [{ index: 0, delta, finish_reason: finish ?? null }],
      });
      function sse(res, chunks) {
        res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
        for (const c of chunks) res.write(`data: ${JSON.stringify(c)}\\n\\n`);
        res.write("data: [DONE]\\n\\n");
        res.end();
      }
      createServer((req, res) => {
        let body = "";
        req.on("data", (d) => (body += d));
        req.on("end", () => {
          if (MODE === "error") {
            res.writeHead(401, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { message: "Incorrect API key provided.",
              type: "invalid_request_error", code: "invalid_api_key" } }));
            return;
          }
          if (MODE === "insufficient_credits") {
            res.writeHead(402, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { message: "Insufficient credits. Add more using " +
              "https://openrouter.ai/settings/credits", code: 402 } }));
            return;
          }
          if (MODE === "server_error") {
            res.writeHead(500, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { message: "The server had an error while " +
              "processing your request. Sorry about that!", type: "server_error", code: null } }));
            return;
          }
          turn += 1;
          if (turn === 1) {
            sse(res, [
              chunk({ role: "assistant", content: "" }),
              chunk({ tool_calls: [{ index: 0, id: "call_sim_1", type: "function",
                function: { name: "bash", arguments: JSON.stringify({ command: #{SIMULATED_COMMAND.inspect} }) } }] }),
              chunk({}, "tool_calls"),
            ]);
          } else {
            sse(res, [chunk({ role: "assistant", content: "Ran it." }), chunk({}, "stop")]);
          }
        });
      }).listen(PORT, "127.0.0.1");
    JS
  end
end
