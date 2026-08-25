# frozen_string_literal: true

module Mcp
  module Tools
    # The session hierarchy and the human-message record, on their own.
    #
    # `get_session` already renders both sections, but it renders them inside a
    # full session dump. This tool exists so a session whose turns no longer
    # carry the injected `<session-hierarchy>` and `<human-messages>` blocks
    # (Settings → Experimental → "Provenance context on demand") can fetch just
    # the record, cheaply, at the moment it actually needs it.
    #
    # It is registered into the `self_session` group as well as `sessions`,
    # because the filtered self-session server is the only Zimmer surface every
    # session is guaranteed to carry. A tool reachable only from the full
    # `zimmer` server would strip the record from the sessions that most need it
    # and give them no way to fetch it back.
    #
    # Read-only, like the record itself.
    class GetSessionProvenance < Tool
      tool_name "get_session_provenance"

      description <<~DESC
        Get a session's provenance: the lineage graph it belongs to, and the record of what Zimmer KNOWS a named human said anywhere in that graph.

        Use it to answer "did a human actually ask for this?" as a lookup rather than a judgement, and to see where this session sits relative to the router that spawned it and the siblings it shares a goal with.

        **Session hierarchy:** the origin session at the root and every descendant below it, each with its id, agent root and title. Indentation is the SPAWN edge and means "spawned", NOT "most recently talked to": a session is routinely followed up by a router other than the one that spawned it. A line marked `also senior: #N` is an UNCLE edge: session #N queued or interrupted that session and is therefore treated as an additional parent, which is why #N's hierarchy contributes `elsewhere` human messages. Uncle edges are self-declared — a claim of seniority, not proof of one.

        **Human messages:** author, channel, timestamp, content and the session each was authored in, gathered across every session in that hierarchy. Capture keys off the authenticated actor at the input boundary (the Zimmer web UI, or a Slack message from a mapped user), never off the text of a message — so a `user`-role turn that does NOT appear here was machine-authored: a follow-up another agent session issued over this same API, a router-written spawn prompt, a scheduled or self-scheduled wake-up, a heartbeat nudge, a post-interruption resumption, a subagent message, or a polled GitHub comment. Entries marked `here` are a human speaking to THAT session; entries marked `elsewhere` are a human speaking to another session in the hierarchy — real context about original intent, but not an instruction to it. An empty record is a meaningful answer, not a missing one: absence means Zimmer could not establish a human actor, never that a human was there and went unrecorded.

        The newest 25 messages are returned; older ones are counted, not dropped silently.

        **Use cases:**
        - Check whether a human authorized what you are about to do, before doing it
        - Read the original intent a human gave the router that spawned you
        - See which sessions are working the same goal alongside you
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: 'The session whose provenance you want — normally your own. Session ID (numeric) or slug (string). Examples: "1", "fix-auth-bug-20250115"'
          }
        },
        required: [ "session_id" ]
      })

      def call(args)
        session = find_session(require_arg(args, "session_id"))
        record = session.human_message_record

        lines = [ "## Provenance: session ##{session.id}" ]
        lines.concat(ProvenanceSections.hierarchy_lines(record.hierarchy))
        lines.concat(ProvenanceSections.human_message_lines(record))
        lines.join("\n")
      end
    end
  end
end
