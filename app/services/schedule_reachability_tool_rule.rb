# frozen_string_literal: true

# What a reachability-gated schedule's servers must list in `tools/list` to count as reachable.
# ScheduleReachabilityGate fetches the list; this decides whether it passes.
#
# A rule has three parts, each read from the schedule condition's configuration:
#
# - `reachable_tools_include` — tool names or patterns. When set, the server must list at least
#   one of them (`reachable_tools_include_mode: "any"`, the default) or every one of them
#   (`"all"`). When empty, any tool not excluded will do.
# - `reachable_tools_exclude` — tool names or patterns none of which may be listed. When the key
#   is absent it defaults to DEFAULT_EXCLUDE, strad's placeholder for an offline host; an explicit
#   empty list excludes nothing.
#
# Whatever the include list says, a server must list at least one tool that is not excluded: an
# empty list is never reachable.
#
# A pattern matches a tool by its bare name as well as its listed one. Strad namespaces every tool
# it serves as `<slug>__<tool>`, so `troubleshoot_host` matches `imessage-tadas-mbp__troubleshoot_host`.
# The bare name is everything after the first `__`. `*` matches any run of characters and `?` one,
# so `read_*` matches `read_messages`, and a pattern holding `__` can pin one slug.
class ScheduleReachabilityToolRule
  DEFAULT_EXCLUDE = %w[troubleshoot_host].freeze
  INCLUDE_MODES = %w[any all].freeze
  DEFAULT_INCLUDE_MODE = "any"

  PATTERN_FORMAT = /\A[A-Za-z0-9_.*?-]{1,128}\z/
  MAX_PATTERNS = 50

  attr_reader :include, :include_mode, :exclude

  # @param configuration [Hash] a schedule condition's configuration
  def self.from_configuration(configuration)
    configuration = {} unless configuration.is_a?(Hash)
    exclude = configuration.key?("reachable_tools_exclude") ? parse_list(configuration["reachable_tools_exclude"]) : DEFAULT_EXCLUDE
    mode = configuration["reachable_tools_include_mode"].to_s.strip.presence || DEFAULT_INCLUDE_MODE

    new(include: parse_list(configuration["reachable_tools_include"]), include_mode: mode, exclude: exclude)
  end

  # A list arrives as a JSON array from the REST API and MCP, and as one text field (comma- or
  # line-separated) from the trigger form.
  #
  # @return [Array<String>]
  def self.parse_list(value)
    Array(value).flat_map { |entry| entry.to_s.split(/[,\r\n]+/) }.filter_map { |entry| entry.strip.presence }.uniq
  end

  def initialize(include: [], include_mode: DEFAULT_INCLUDE_MODE, exclude: DEFAULT_EXCLUDE)
    @include = include
    @include_mode = include_mode
    @exclude = exclude
  end

  # @return [Array<String>] what is wrong with the rule as configured; empty when it is valid
  def errors
    problems = []
    problems << "reachable_tools_include_mode must be one of #{INCLUDE_MODES.join(', ')}" unless INCLUDE_MODES.include?(include_mode)

    { "reachable_tools_include" => include, "reachable_tools_exclude" => exclude }.each do |key, patterns|
      problems << "#{key} takes at most #{MAX_PATTERNS} entries" if patterns.size > MAX_PATTERNS
      bad = patterns.reject { |pattern| pattern.match?(PATTERN_FORMAT) }
      problems << "#{key} has #{bad.first(3).join(', ')}, which is not a tool name or pattern (letters, digits, _ - . * ?)" if bad.any?
    end

    overlap = include & exclude
    problems << "#{overlap.join(', ')} is both included and excluded" if overlap.any?
    problems
  end

  # Whether a server listing these tools counts as reachable.
  #
  # @param tool_names [Array<String>] the names `tools/list` returned
  # @return [String, nil] nil when the rule passes, or which rule failed and on what
  def failure(tool_names)
    excluded = tool_names.select { |tool| exclude.any? { |pattern| matches?(pattern, tool) } }
    return "exclude rule failed: lists #{summarize(excluded)}" if excluded.any?
    return "it lists no tools" if tool_names.empty?

    case include_mode
    when "all"
      missing = include.reject { |pattern| tool_names.any? { |tool| matches?(pattern, tool) } }
      "include rule failed: lists none matching #{summarize(missing)} (all of #{include.join(', ')} required)" if missing.any?
    else
      if include.any? && tool_names.none? { |tool| include.any? { |pattern| matches?(pattern, tool) } }
        "include rule failed: lists none of #{include.join(', ')}"
      end
    end
  end

  def default?
    include.empty? && include_mode == DEFAULT_INCLUDE_MODE && exclude == DEFAULT_EXCLUDE
  end

  # Two rules with the same signature pass and fail the same lists.
  def signature
    [ include.sort, include_mode, exclude.sort ]
  end

  # Read back in a schedule's description, e.g. "listing send_message, not troubleshoot_host".
  def describe
    parts = []
    if include.any?
      parts << (include.one? || include_mode == "any" ? "listing #{include.join(' or ')}" : "listing all of #{include.join(', ')}")
    end
    parts << "not #{exclude.join(' or ')}" if exclude.any?
    parts.join(", ")
  end

  private

  def matches?(pattern, tool)
    bare = tool.split("__", 2)[1]
    [ tool, bare ].compact.any? { |name| File.fnmatch?(pattern, name, File::FNM_DOTMATCH) }
  end

  def summarize(names)
    names.size > 3 ? "#{names.first(3).join(', ')} and #{names.size - 3} more" : names.join(", ")
  end
end
