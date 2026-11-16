# frozen_string_literal: true

module CycleTimes
  # What a session that put itself to sleep was waiting FOR.
  #
  # A `wake_me_up_later` call records only a time and the prompt the session
  # wrote for its future self, so the purpose of the sleep is read off that
  # prompt. Agents write these prompts in a small number of recurring shapes —
  # "re-check CI on PR #12", "check whether the merge gate rated the PR", "the
  # deploy should be done, verify it" — and the patterns below are those shapes.
  # Order matters, first match wins: a prompt about "the deploy after the PR
  # merged" is a deploy wait, not a PR wait.
  #
  # `wake_me_up_when_session_changes_state` needs no reading: it is a wait on
  # another session by construction.
  module WaitClassifier
    Result = Data.define(:category, :detail)

    # The prompt shapes the vendored skills tell an agent to write, matched
    # first because they are exact: open-pr's "Self-wake N of 3" / "post-merge
    # wake N of 10" and wait-for-ci's "CI wake N" / "Blocker wake N". A blocker
    # wait is a red base branch holding up checks, so it counts as CI.
    SKILL_SHAPES = [
      [ /\bpost-merge wake\b/i, "wait_deploy" ],
      [ /\Aself-wake \d+ of \d+|open-pr skill's Terminal Step|\bmerge[- ]gate\b/i, "wait_merge_gate" ],
      [ /\A(?:CI|blocker) (?:wake|watch)\b|\bwait-for-ci\b/i, "wait_ci" ]
    ].freeze

    # Then the free-text shapes, in the same precedence: a prompt about "the
    # deploy after the PR merged" is a deploy wait, not a PR wait.
    GENERIC = [
      [ /\b(?:deploy(?:ed|ment|s)?|release (?:build|image)|kamal|rollout)\b/i, "wait_deploy" ],
      [ /\b(?:CI|gh pr checks|gh run (?:watch|view)|github actions|checks? (?:pass|passes|to (?:finish|pass|complete)|are|is) |workflow runs?)\b/i, "wait_ci" ],
      [ /\b(?:ready to merge|PR state|pull request state|merged|HELD|gate verdict|disposition)\b/i, "wait_merge_gate" ]
    ].freeze

    DETAIL_LIMIT = 140

    WATCH_TOOL = /wake_me_up_when_session_changes_state\z/
    LATER_TOOL = /wake_me_up_later\z/

    module_function

    # @param tool_name [String] the wake tool that armed the sleep
    # @param arguments [Hash] its input
    # @return [Result, nil] nil when +tool_name+ is not a wake tool
    def classify_wake(tool_name, arguments)
      args = arguments.is_a?(Hash) ? arguments : {}
      name = tool_name.to_s

      if name.match?(WATCH_TOOL)
        watched = Array(args["session_ids"] || args["session_id"]).join(", ")
        return Result.new("wait_child", truncate("watching session #{watched.presence || '?'}"))
      end
      return nil unless name.match?(LATER_TOOL)

      classify_text(args["prompt"].to_s, fallback: "wait_sleep", prefix: "wake: ")
    end

    # Classify free text (a wake prompt, a sleeping shell loop's command).
    def classify_text(text, fallback:, prefix: "")
      detail = truncate("#{prefix}#{text.strip.gsub(/\s+/, ' ')}")
      category = (SKILL_SHAPES + GENERIC).find { |pattern, _| text.match?(pattern) }&.last || fallback
      Result.new(category, detail)
    end

    def truncate(text)
      text.length > DETAIL_LIMIT ? "#{text[0, DETAIL_LIMIT - 1]}…" : text
    end
  end
end
