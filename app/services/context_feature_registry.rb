# frozen_string_literal: true

# The catalogue of context-management features whose token cost is worth knowing,
# and the only thing you edit to add another one.
#
# A "context-management feature" is anything that puts bytes into a request's
# prompt for a reason other than the user's actual task: the goal block Zimmer
# appends to every turn, the session hierarchy and human-message record that ride
# along with it, a skill body loaded on invocation, an MCP tool's response. Each
# is a decision someone made, each bills on every subsequent turn it stays in the
# context, and none of them is individually visible in a bill.
#
# ADDING A FEATURE
#
# Append one `feature` call below and re-run ingestion. That is the whole
# procedure. Ingestion is a re-runnable scanner over the transcripts on disk, so a
# detector written today is backfilled over everything still retained — nothing
# has to be instrumented at the call site, and there is no waiting for fresh data.
# (Retention bounds it: Claude Code prunes `~/.claude/projects` on its own
# schedule — about 30 days on this deployment — so a new detector can see roughly
# the last month, not all history.)
#
# TWO KINDS OF DETECTOR
#
#   region — a regexp over a text block. Claims only the characters it matches, so
#            several can share one block. This is how the Zimmer-injected blocks
#            are found: they are delimited stretches inside a user turn that also
#            contains the real prompt.
#   block  — a predicate over a whole content block. Claims everything in that
#            block that no region detector already claimed. This is how tool
#            results, thinking, and assistant output are found.
#
# Regions are matched first, then the first matching block detector takes the
# remainder, then `FALLBACK` takes anything still unclaimed. Every character of
# every block therefore lands on exactly one feature, which is what lets the
# attributor reconcile its estimate against the request's real totals instead of
# quietly losing bytes.
#
# `owner` is the field that makes the page actionable rather than merely
# interesting. `:zimmer` features are the ones this repository chose to inject and
# can therefore choose to stop injecting, shrink, or move behind a cheaper model.
# `:harness` and `:work` are cost you can see but not directly legislate.
class ContextFeatureRegistry
  Feature = Struct.new(
    :key, :label, :blurb, :owner, :kind, :pattern, :predicate,
    keyword_init: true
  ) do
    def region? = kind == :region
    def zimmer? = owner == :zimmer
  end

  # One content block from a transcript line, flattened to what a detector needs.
  # `tool_name` is resolved from the `tool_use` that a `tool_result` answers, so a
  # detector can ask "was this an MCP server's reply" without walking the file.
  Block = Struct.new(:role, :type, :text, :tool_name, keyword_init: true) do
    def size = text.to_s.length
    def user_text? = role == "user" && type == "text"
    def mcp? = tool_name.to_s.start_with?("mcp__")
  end

  # Where a character lands when nothing claims it. Named rather than nil so the
  # totals always add up and the page can show it as a real line.
  FALLBACK = "other_context"

  class << self
    def all = registry.values

    def find(key) = registry[key.to_s]

    def keys = registry.keys

    def regions = all.select(&:region?)

    def blocks = all.reject(&:region?)

    def label_for(key) = find(key)&.label || key.to_s.humanize

    def zimmer_keys = all.select(&:zimmer?).map(&:key)

    # Characters this block contributes, by feature key. Totals to `block.size`.
    def classify(block)
      claimed = Hash.new(0)
      remaining = block.text.to_s

      regions.each do |feature|
        next unless block.user_text?

        matched = 0
        remaining = remaining.gsub(feature.pattern) do |hit|
          matched += hit.length
          ""
        end
        claimed[feature.key] += matched if matched.positive?
      end

      leftover = remaining.length
      return claimed if leftover.zero?

      owner = blocks.find { |feature| feature.predicate.call(block) }
      claimed[owner&.key || FALLBACK] += leftover
      claimed
    end

    private

    def registry = @registry ||= {}

    def feature(key:, label:, blurb:, owner:, pattern: nil, &predicate)
      raise ArgumentError, "feature #{key} needs a pattern or a predicate" unless pattern || predicate
      raise ArgumentError, "duplicate feature #{key}" if registry.key?(key)

      registry[key] = Feature.new(
        key: key, label: label, blurb: blurb, owner: owner,
        kind: pattern ? :region : :block, pattern: pattern, predicate: predicate
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Region detectors — delimited stretches Zimmer appends to a user turn.
  #
  # Each pattern is paired with the code that writes it: the first three come out
  # of AgentSessionJob#build_prompt_with_goal, the fourth out of
  # SessionHumanMessages. A pattern that stops matching after a prompt is reworded
  # does not corrupt anything — the characters fall through to the prompt's own
  # feature — but the line goes to zero on the page, which is the signal to come
  # back here.
  # ---------------------------------------------------------------------------

  feature(
    key: "goal",
    label: "Session goal",
    blurb: "The goal text Zimmer appends to every turn, plus its hand-back instruction.",
    owner: :zimmer,
    pattern: /The user has indicated the goal for this task is[\s\S]*?(?=\n<session-notes>|\n<session-hierarchy>|\n<human-messages>|\z)/
  )

  feature(
    key: "session_notes",
    label: "Session notes",
    blurb: "The operator's own notes, re-sent on every turn.",
    owner: :zimmer,
    pattern: %r{<session-notes>[\s\S]*?</session-notes>}
  )

  feature(
    key: "session_hierarchy",
    label: "Session hierarchy",
    blurb: "The lineage outline that tells a session where it sits in its tree. Shrinks to a one-line pointer when provenance is offered on demand.",
    owner: :zimmer,
    pattern: %r{<session-hierarchy>[\s\S]*?</session-hierarchy>}
  )

  feature(
    key: "human_messages",
    label: "Human-message record",
    blurb: "The provenance record of which turns a real person authored. Shrinks to counts plus a pointer when provenance is offered on demand.",
    owner: :zimmer,
    pattern: %r{<human-messages>[\s\S]*?</human-messages>}
  )

  feature(
    key: "system_reminder",
    label: "System reminders",
    blurb: "Harness-injected reminders, including CLAUDE.md. Rarely persisted, so rarely counted.",
    owner: :harness,
    pattern: %r{<system-reminder>[\s\S]*?</system-reminder>}
  )

  # ---------------------------------------------------------------------------
  # Block detectors — whole content blocks, first match wins.
  # ---------------------------------------------------------------------------

  feature(
    key: "skill_body",
    label: "Skill invocations",
    blurb: "A skill's SKILL.md, loaded into the context when the Skill tool runs.",
    owner: :zimmer
  ) { |block| block.user_text? && block.text.to_s.start_with?("Base directory for this skill:") }

  # Deliberately ahead of the generic MCP detectors: with provenance offered on
  # demand the record still costs bytes, it just arrives as a tool call instead
  # of an injected block. Folding it into "MCP responses" would make the
  # experiment look free — the injected lines go to zero and the fetched ones
  # disappear into a bucket shared with every other server. This line plus the
  # two region lines above is the honest before/after.
  feature(
    key: "provenance_tool",
    label: "Provenance fetched on demand",
    blurb: "The hierarchy and human-message record a session fetched with get_session_provenance, rather than being handed it every turn.",
    owner: :zimmer
  ) { |block| block.mcp? && block.tool_name.to_s.end_with?("__#{SessionHumanMessages::MCP_TOOL_NAME}") }

  feature(
    key: "mcp_result",
    label: "MCP responses",
    blurb: "What MCP servers returned. Billed again on every later turn it stays in context.",
    owner: :zimmer
  ) { |block| block.type == "tool_result" && block.mcp? }

  feature(
    key: "mcp_call",
    label: "MCP tool calls",
    blurb: "The arguments the model wrote to call an MCP tool.",
    owner: :zimmer
  ) { |block| block.type == "tool_use" && block.mcp? }

  feature(
    key: "tool_result",
    label: "Built-in tool output",
    blurb: "Output from the harness's own tools — Bash, Read, Grep, Edit.",
    owner: :harness
  ) { |block| block.type == "tool_result" }

  feature(
    key: "tool_call",
    label: "Built-in tool calls",
    blurb: "The arguments the model wrote to call a built-in tool.",
    owner: :harness
  ) { |block| block.type == "tool_use" }

  feature(
    key: "thinking",
    label: "Extended thinking",
    blurb: "Reasoning blocks. Under-counted: the harness keeps the signature and drops the text.",
    owner: :harness
  ) { |block| block.type == "thinking" }

  feature(
    key: "assistant_text",
    label: "Assistant prose",
    blurb: "What the agent actually said.",
    owner: :work
  ) { |block| block.role == "assistant" && block.type == "text" }

  feature(
    key: "prompt",
    label: "Prompts",
    blurb: "The task itself: what a human or a calling session asked for.",
    owner: :work
  ) { |block| block.user_text? }
end
