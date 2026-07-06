# Model for storing transcripts from nested Claude agents spawned via the Task tool.
# Each Session may have multiple subagent transcripts, one for each nested agent that ran.
#
# Subagents are linked to their parent Task tool call via:
# - tool_use_id: matches the tool_use block's "id" field
# - agent_id: matches the toolUseResult.agentId in the tool_result
#
# Status values: running, completed, failed
class SubagentTranscript < ApplicationRecord
  belongs_to :session

  validates :agent_id, presence: true, uniqueness: { scope: :session_id }
  validates :status, inclusion: { in: %w[running completed failed] }, allow_nil: true

  # Parse the JSONL transcript into an array of message objects
  def parsed_transcript
    return [] unless transcript.present?

    transcript.lines.filter_map do |line|
      stripped = line.strip
      next if stripped.empty?

      JSON.parse(stripped)
    rescue JSON::ParserError
      nil
    end
  end

  # Normalize the stored JSONL into OpenTranscripts events (see OpenTranscript).
  # Subagents are spawned via the Claude Code Task tool, so their transcripts are
  # always Claude JSONL. Rendered through the same unified timeline_items/_item
  # partial as the parent timeline.
  def open_transcript_events
    normalizer = ClaudeTranscriptNormalizer.new
    events = []
    parsed_transcript.each_with_index do |raw_event, index|
      events.concat(normalizer.normalize(raw_event, session: session, transcript_index: index))
    end
    OpenTranscript.sort_events(events)
  end

  # Check if the subagent is currently running
  def running?
    status == "running"
  end

  # Check if the subagent has completed
  def completed?
    status == "completed"
  end

  # Check if the subagent has failed
  def failed?
    status == "failed"
  end

  # Format duration for display
  def formatted_duration
    return nil unless duration_ms.present?

    total_seconds = duration_ms / 1000
    minutes = total_seconds / 60
    seconds = total_seconds % 60

    if minutes > 0
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end

  # Format token count for display
  def formatted_tokens
    return nil unless total_tokens.present?

    if total_tokens >= 1000
      "#{(total_tokens / 1000.0).round(1)}k"
    else
      total_tokens.to_s
    end
  end

  # Display label for the accordion header
  def display_label
    description.presence || subagent_type.presence || "Subagent"
  end
end
