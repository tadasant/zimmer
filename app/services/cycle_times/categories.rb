# frozen_string_literal: true

module CycleTimes
  # The fixed set of things a moment of cycle time can be spent on.
  #
  # Every segment the builder emits carries one of these keys, the rollup ranks
  # them by `priority`, and the page, the REST API and `get_cycle_time` all read
  # labels and colors from here — so a category added in one place exists
  # everywhere or nowhere.
  #
  # FAMILY is the coarse question the operator asks ("inference, network, local I/O,
  # or waiting?"); KEY is the fine one ("waiting on what?").
  #
  # PRIORITY decides what a hierarchy was doing at an instant when several of
  # its sessions were doing different things at once (see Rollup). Work beats
  # waiting — if any session was generating or running a tool, the task was not
  # blocked — and among waits the most specific one wins, which is why
  # `wait_child` is last: a parent waiting on a child is waiting on whatever
  # that child is doing, and the child's own lane names it.
  #
  # COLORS follow the dataviz reference palette: eight categorical hues in their
  # fixed order, neutral gray for Zimmer's own scheduling and for what nothing
  # explains, and a hatch as the secondary encoding where two keys share a hue.
  module Categories
    Category = Data.define(:key, :label, :family, :priority, :color, :texture, :description)

    FAMILIES = {
      "inference" => "Inference",
      "network" => "Network",
      "local" => "Local I/O & compute",
      "waiting" => "Waiting",
      "overhead" => "Overhead"
    }.freeze

    ALL = [
      Category.new("inference", "Inference", "inference", 100, "#2a78d6", nil,
        "The model generating: the gap from a prompt or tool result to the next assistant event. Includes " \
        "context compaction and API retries."),
      Category.new("network", "Network calls", "network", 90, "#eb6834", nil,
        "MCP tool calls, WebFetch/WebSearch, and shell commands that talk to the network (gh, git push/fetch, " \
        "curl, package installs)."),
      Category.new("local_io", "Local I/O & compute", "local", 80, "#1baf7a", nil,
        "Read/Edit/Write/Grep/Glob and local shell commands: tests, builds, linters."),
      Category.new("subagent", "In-process subagent", "inference", 70, "#2a78d6", "hatch",
        "A Task/Agent subagent the session started and blocked on. Its own inference and tools are inside it."),
      Category.new("wait_human", "Waiting on a human", "waiting", 60, "#e34948", nil,
        "Blocked on an MCP elicitation or AskUserQuestion. About zero on an eligible row by construction."),
      Category.new("wait_ci", "Waiting on CI", "waiting", 55, "#eda100", nil,
        "A self-wake or shell wait whose purpose was GitHub checks: wait-for-ci, gh pr checks --watch, gh run watch."),
      Category.new("wait_merge_gate", "Merge gate / PR holding", "waiting", 50, "#6250d6", nil,
        "Holding an open PR for the merge gate's rating, or sleeping on a PR-state check."),
      Category.new("wait_deploy", "Waiting on a deploy", "waiting", 48, "#008300", "hatch",
        "Sleeping on a deploy, a release build or post-merge workflow runs."),
      Category.new("wait_quota_park", "Quota park", "waiting", 45, "#6b6a66", "hatch-reverse",
        "Parked by Zimmer because every account was out of quota or the provider refused."),
      Category.new("wait_spot_hold", "Spot-gate hold", "waiting", 44, "#6b6a66", "hatch",
        "A spot session held by the spot gate until the quota window had room."),
      Category.new("wait_worker_queue", "Worker queue", "waiting", 43, "#6b6a66", nil,
        "The turn was queued and waiting for a worker thread to pick it up."),
      Category.new("turn_startup", "Turn startup", "overhead", 42, "#a8a7a1", nil,
        "From a worker taking the turn to the runtime's first transcript event: process spawn, MCP servers " \
        "booting, the CLI resuming its conversation."),
      Category.new("wait_sleep", "Timed sleep / self-wake", "waiting", 40, "#008300", nil,
        "A generic wake_me_up_later, or a shell sleep, whose purpose was not CI, a PR or a deploy."),
      Category.new("unattributed", "Unattributed", "overhead", 20, "#d6d5cf", nil,
        "Time no recorded event explains: turn wind-down, transcript gaps, a failed turn's restart. Shown rather " \
        "than spread across the other categories."),
      Category.new("wait_child", "Waiting on a child session", "waiting", 10, "#e87ba4", nil,
        "Watching a spawned session (wake_me_up_when_session_changes_state) or idle while children run. In the " \
        "hierarchy total this only shows when the child itself is accounted elsewhere or not at all.")
    ].freeze

    BY_KEY = ALL.index_by(&:key).freeze
    KEYS = ALL.map(&:key).freeze
    WAIT_KEYS = ALL.select { |c| c.family == "waiting" }.map(&:key).freeze

    module_function

    def fetch(key) = BY_KEY.fetch(key.to_s)
    def label(key) = BY_KEY[key.to_s]&.label || key.to_s.humanize
    def priority(key) = BY_KEY[key.to_s]&.priority || 0
    def wait?(key) = WAIT_KEYS.include?(key.to_s)

    # Inline CSS for a swatch or a segment: the hue, plus the hatch that tells two
    # keys sharing a hue apart without color.
    def css(key)
      category = BY_KEY[key.to_s] || BY_KEY["unattributed"]
      case category.texture
      when "hatch"
        "background: repeating-linear-gradient(45deg, #{category.color} 0 4px, #{category.color}99 4px 7px);"
      when "hatch-reverse"
        "background: repeating-linear-gradient(135deg, #{category.color} 0 4px, #{category.color}99 4px 7px);"
      else
        "background: #{category.color};"
      end
    end

    # Category totals in display order, dropping zeros.
    def ordered(totals)
      KEYS.filter_map { |key| [ key, totals[key].to_f ] if totals[key].to_f.positive? }
    end
  end
end
