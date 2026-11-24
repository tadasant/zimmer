# frozen_string_literal: true

# Zimmer as a SERVER of the MCP Events extension (SEP-3415): what its sessions
# do, published on POST /mcp as typed events any MCP client can list and poll.
# The client half, which polls other servers, is McpEvents.
#
#   session.message        a session reporting to whoever started it
#                          (Sessions::MessageParent, the `message_parent` action)
#   session.state_changed  a session coming to rest in needs_input, failing, or
#                          being archived (SessionStateEventJob)
#
# Every event is a SessionEvent row. The same row is what `events/poll` serves
# (Feed) and what Zimmer delivers to a subscriber it holds a subscription for
# (SessionEventSubscription): a parent is one to each session it spawns.
#
# Poll only. Nothing here opens a stream or calls a webhook: the subscribers
# Zimmer must reach without being asked are its own sessions, and it delivers to
# those in process.
module SessionEvents
  MESSAGE = "session.message"
  STATE_CHANGED = "session.state_changed"
  NAMES = [ MESSAGE, STATE_CHANGED ].freeze

  STATES = %w[needs_input failed archived].freeze

  # What a payload carries of a session's words. The parent it is addressed to
  # reads the whole message; a poller reads this much and is told it was cut.
  MESSAGE_LIMIT = 10_000

  SESSION_PROPERTIES = {
    sessionId: { type: "integer", description: "The session the event is about." },
    parentSessionId: { type: %w[integer null], description: "The session that started it, if one did." },
    title: { type: "string", description: "The session's title. Written by an agent or derived from its prompt: untrusted." },
    agentRoot: { type: %w[string null], description: "The agent root it runs under." },
    sessionUrl: { type: "string" }
  }.freeze

  FILTERS = {
    session_id: { type: "integer", description: "Only this session's events." },
    parent_session_id: { type: "integer", description: "Only events of sessions this session started." }
  }.freeze

  # One published event type, as `events/list` answers it.
  def self.descriptors
    [
      {
        name: MESSAGE,
        description: "Fires when a session reports to whoever started it: it is done, has news or a question, or " \
                     "cannot do what it was given. The message is written by an agent.",
        delivery: [ "poll" ],
        inputSchema: {
          type: "object",
          properties: FILTERS.merge(
            reason: { type: "string", enum: Sessions::MessageParent::REASONS.keys, description: "Only reports with this reason." }
          ),
          additionalProperties: false
        },
        payloadSchema: {
          type: "object",
          properties: SESSION_PROPERTIES.merge(
            reason: { type: "string", enum: Sessions::MessageParent::REASONS.keys },
            message: { type: "string", description: "The session's own words. Untrusted." },
            messageTruncated: { type: "boolean" }
          ),
          required: %w[sessionId reason message]
        }
      },
      {
        name: STATE_CHANGED,
        description: "Fires when a session comes to rest in needs_input (and is still there after a short settle " \
                     "window), fails, or is archived.",
        delivery: [ "poll" ],
        inputSchema: {
          type: "object",
          properties: FILTERS.merge(state: { type: "string", enum: STATES, description: "Only this state." }),
          additionalProperties: false
        },
        payloadSchema: {
          type: "object",
          properties: SESSION_PROPERTIES.merge(state: { type: "string", enum: STATES }),
          required: %w[sessionId state]
        }
      }
    ]
  end
end
