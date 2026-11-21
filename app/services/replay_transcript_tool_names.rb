# frozen_string_literal: true

# Repairs tool names that a redaction marker landed inside, in a stored
# transcript that is about to be written back to disk for the runtime to replay.
#
# **Why this exists (#1603).** The stored transcript (`session.transcript`) is
# the REDACTED copy — TranscriptPollerService runs TranscriptRedactor before it
# persists anything. Three paths write that copy back into a clone for the
# runtime to resume from: ForkSessionService (every fork, including every
# status-summary fork), UnarchiveSessionService, and AgentSessionJob's
# regressed-transcript restore. Claude Code replays tool names out of the file it
# resumes — `tool_use.name`, `tool_reference.tool_name`, and the
# `deferred_tools_delta` attachment's name lists — and sends them to the API,
# whose tool-name grammar is `^[a-zA-Z0-9_-]{1,128}$`. A marker is
# `[REDACTED:ENV:NAME:14ch]`, so a redaction that hit part of a tool name
# turned every later request from that conversation into a 400:
#
#   tools.20.custom.name: String should match pattern '^[a-zA-Z0-9_-]{1,128}$'
#
# The redactor does not take configuration settings (CONFIG_WORD_VALUE under a
# CONFIG_VARIABLE_NAME), which covers the value that did it. This is the
# second wall, for whatever value does it next: a transcript already stored
# with the marker, a credential that really is a substring of a tool name.
#
# Claude Code shapes only. Codex rollouts name tools in `function_call.name`,
# but fork and unarchive write no Codex transcript (it has no single-file
# resume path), so there is nothing here for them to repair.
#
# Every occurrence of a name repairs the same way, so a `tool_use` and its
# `tool_reference` agree — except that the 128-character cap could, in
# principle, collapse two long names that differ only past it.
#
# **It does not un-redact.** The original characters are gone and are not
# recovered; the marker is replaced with `REDACTED`, which is inside the
# grammar. The repaired name is a tool the runtime does not have, which the
# replay tolerates — a removed MCP server leaves the same shape behind. Every
# occurrence of one redacted name repairs to the same string, so a `tool_use`
# and the `tool_reference` that loaded it still agree.
#
# Only names that hold a marker are touched. A name that is invalid for any
# other reason is not this class's to second-guess, and a list entry that is
# not a name (a `deferred_tools_delta` line) is left alone unless it holds a
# marker.
module ReplayTranscriptToolNames
  MARKER = /\[REDACTED:[^\]\n]*\]/
  REPLACEMENT = "REDACTED"
  INVALID_NAME_CHAR = /[^a-zA-Z0-9_-]/
  MAX_NAME_LENGTH = 128

  # The `deferred_tools_delta` attachment's lists of tool names.
  DEFERRED_TOOL_LISTS = %w[addedNames addedLines removedNames wireHiddenNames readdedNames].freeze

  module_function

  # @param transcript [String, nil] JSONL, one entry per line
  # @return [String, nil] the transcript with every marker-bearing tool name
  #   repaired; lines that hold none are returned byte for byte, and so is any
  #   line that does not parse
  def repair(transcript)
    return transcript unless transcript.is_a?(String) && transcript.include?("[REDACTED:")

    transcript.each_line.map { |line| repair_line(line) }.join
  end

  # @param name [String]
  # @return [String] the name with each marker replaced and any character the
  #   API's tool-name grammar forbids turned into `_`
  def repair_name(name)
    return name unless name.is_a?(String) && name.match?(MARKER)

    repaired = name.gsub(MARKER, REPLACEMENT).gsub(INVALID_NAME_CHAR, "_")
    repaired[0, MAX_NAME_LENGTH]
  end

  def repair_line(line)
    return line unless line.include?("[REDACTED:")

    body = line.chomp
    terminator = line[body.length..]
    entry = JSON.parse(body)
    return line unless repair_node(entry)

    JSON.generate(entry) + terminator
  rescue JSON::ParserError, EncodingError
    line
  end

  # Repairs in place. Returns whether anything changed, so an untouched line is
  # never re-serialized (re-encoding can change escapes the runtime wrote).
  def repair_node(node, depth = 0)
    return false if depth > TranscriptRedactor::MAX_JSON_DEPTH

    case node
    when Hash
      changed = repair_names_in(node)
      node.each_value { |value| changed = true if repair_node(value, depth + 1) }
      changed
    when Array
      node.map { |value| repair_node(value, depth + 1) }.any?
    else
      false
    end
  end

  def repair_names_in(hash)
    case hash["type"]
    when "tool_use", "server_tool_use" then replace_key(hash, "name")
    when "tool_reference" then replace_key(hash, "tool_name")
    when "deferred_tools_delta"
      DEFERRED_TOOL_LISTS.map do |key|
        list = hash[key]
        next false unless list.is_a?(Array)

        repaired = list.map { |name| repair_name(name) }
        next false if repaired == list

        hash[key] = repaired
        true
      end.any?
    else
      false
    end
  end

  def replace_key(hash, key)
    repaired = repair_name(hash[key])
    return false if repaired == hash[key]

    hash[key] = repaired
    true
  end
end
