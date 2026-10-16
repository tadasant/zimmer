# frozen_string_literal: true

# One entry in a live conversation's thread: something the human said or typed,
# something the model answered, or a tool call the model made and what came back.
class LiveConversationTurn < ApplicationRecord
  include BroadcastsThroughService

  ROLES = %w[user assistant tool].freeze
  SOURCES = %w[typed spoken].freeze

  # What the model is shown of a tool's output. A tool result goes back into the
  # model's context on every later turn, and Zimmer's own tools can return tens
  # of kilobytes; the full output stays on the row for the human.
  MODEL_OUTPUT_LIMIT = 12_000

  belongs_to :live_conversation

  validates :role, inclusion: { in: ROLES }
  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :content, presence: true, unless: :tool?
  validates :tool_name, :call_id, presence: true, if: :tool?

  scope :chronological, -> { order(:id) }

  after_create_commit :broadcast_append

  def user? = role == "user"
  def assistant? = role == "assistant"
  def tool? = role == "tool"

  def model_output
    tool_output.to_s.truncate(MODEL_OUTPUT_LIMIT, omission: "\n…[truncated]")
  end

  def as_api_json
    {
      id: id,
      role: role,
      source: source,
      content: content,
      tool_name: tool_name,
      call_id: call_id,
      tool_arguments: tool_arguments,
      tool_output: tool_output,
      tool_error: tool_error,
      created_at: created_at
    }
  end

  private

  def broadcast_append
    broadcaster.broadcast_partial(
      action: :append,
      stream: live_conversation.stream_name,
      target: live_conversation.turns_dom_id,
      partial: "live_conversations/turn",
      locals: { turn: self }
    )
  end
end
