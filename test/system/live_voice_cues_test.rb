require "application_system_test_case"

# The web call dock's cues, in a real browser, driven by the Realtime events a
# call would receive. No microphone and no OpenAI here, so nothing is heard: this
# proves which cue each event calls for, that each cue renders as sound, and
# that the microphone closes while one sounds.
class LiveVoiceCuesTest < ApplicationSystemTestCase
  # A dock with its player swapped for one that writes down what it was told, a
  # call in `listening`, and every event below delivered as the data channel would.
  def drive(*events)
    page.evaluate_script(<<~JS)
      (function () {
        const dock = document.getElementById("live-voice-dock");
        const live = window.Stimulus.getControllerForElementAndIdentifier(dock, "live-voice");
        const heard = [];
        live.cues = { perform: (actions) => heard.push(...actions) };
        live.call = { toolCallsUrl: "/nowhere", turnsUrl: "/nowhere" };
        live.director = new live.director.constructor();
        live.generation = 1;
        live.post = () => new Promise(() => {});
        live.setState("listening");
        heard.length = 0;
        #{events.to_json}.forEach((event) => live.handleEvent(event, 1));
        const seen = JSON.parse(JSON.stringify(heard));
        live.setState("idle");
        return seen;
      })()
    JS
  end

  def speech(kind) = { type: "input_audio_buffer.speech_#{kind}" }
  def tool(id) = { type: "response.function_call_arguments.done", call_id: id, name: "x", arguments: "{}" }

  setup do
    visit "/"
    assert_selector "#live-voice-dock", visible: :all
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        !!window.Stimulus?.getControllerForElementAndIdentifier(document.getElementById("live-voice-dock"), "live-voice")
      JS
    end
  end

  test "being heard, then thinking, then the reply" do
    assert_equal [ { "stopCues" => true }, { "startLoop" => "thinking" }, { "play" => "heard", "after" => 0.35 }, { "stopCues" => true } ],
      drive(speech("started"), speech("stopped"), { type: "response.output_audio_transcript.delta" })
  end

  test "a tool sounds different from thinking and stops the moment the person talks" do
    assert_equal [ { "stopCues" => true }, { "startLoop" => "thinking" }, { "play" => "heard", "after" => 0.35 },
                   { "stopLoop" => true }, { "startLoop" => "working" }, { "stopCues" => true } ],
      drive(speech("started"), speech("stopped"), tool("a"), speech("started"))
  end

  test "a reply cut short or failed sounds failed, and one talked over does not" do
    assert_includes drive({ type: "response.done", response: { status: "incomplete", output: [] } }), { "play" => "failed" }
    assert_includes drive({ type: "response.done", response: { status: "failed", output: [] } }), { "play" => "failed" }
    assert_not_includes drive({ type: "response.done", response: { status: "cancelled", output: [] } }), { "play" => "failed" }
  end

  test "an error fails the wait for an answer but not a call waiting for the person" do
    assert_not_includes drive({ type: "error", error: { message: "stray" } }), { "play" => "failed" }
    assert_includes drive(speech("stopped"), { type: "error", error: { message: "refused" } }), { "play" => "failed" }
  end

  test "a tool Zimmer could not run sounds failed, and a mute survives a cue" do
    results = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const dock = document.getElementById("live-voice-dock");
      const live = window.Stimulus.getControllerForElementAndIdentifier(dock, "live-voice");
      const heard = [];
      live.cues = { perform: (actions) => heard.push(...actions) };
      live.call = { toolCallsUrl: "/nowhere" };
      live.director = new live.director.constructor();
      live.generation = 1;
      live.post = () => Promise.resolve({ ok: true, json: async () => ({ output: "no", error: true }) });
      live.setState("listening");
      live.handleEvent(#{tool('b').to_json}, 1);
      live.pendingCalls.get("b").then(() => {
        const track = { enabled: true };
        live.mic = { getAudioTracks: () => [ track ], getTracks: () => [] };
        live.toggleMute();
        const muted = track.enabled;
        live.cueSounding = true; live.applyMic();
        live.cueSounding = false; live.applyMic();
        const stillMuted = track.enabled;
        live.toggleMute();
        const unmuted = track.enabled;
        live.cueSounding = true; live.applyMic();
        done({ heard, muted, stillMuted, unmuted, gated: track.enabled });
      });
    JS
    assert_includes results["heard"], { "play" => "failed" }
    assert_equal [ false, false, true, false ], results.values_at("muted", "stillMuted", "unmuted", "gated")
  end

  test "every cue renders as quiet sound and closes the microphone while it plays" do
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("lib/live_cues").then(async ({ LiveCuePlayer, cueSamples }) => {
        const peaks = {};
        for (const cue of [ "connected", "heard", "thinking", "working", "failed", "ended", "disconnected" ]) {
          peaks[cue] = Math.max(...cueSamples(cue).map(Math.abs));
        }
        const gates = [];
        const player = new LiveCuePlayer({ onMicGate: (closed) => gates.push(closed), onLoopTimeout: () => {} });
        player.context = new OfflineAudioContext(1, 12000, 24000);
        player.perform([ { play: "failed" } ]);
        const rendered = await player.context.startRendering();
        const peak = Math.max(...rendered.getChannelData(0).map(Math.abs));
        await new Promise((resolve) => setTimeout(resolve, 700));
        player.perform([ { play: "heard", after: 5 } ]);
        player.perform([ { stopCues: true } ]);
        await new Promise((resolve) => setTimeout(resolve, 50));
        done({ peaks, peak, gates, closures: player.closures });
      });
    JS
    assert_operator result["peak"], :>, 0.05, "it makes a sound"
    result["peaks"].each { |cue, peak| assert_operator peak, :<=, 0.25, cue }
    assert_equal [ true, false ], result["gates"], "closed for the cue, open after, and a cancelled cue never closes it"
    assert_equal 0, result["closures"]
  end
end
