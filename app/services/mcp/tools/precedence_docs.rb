# frozen_string_literal: true

module Mcp
  module Tools
    # The prose every surface that can set `precedence` shows, in one place.
    #
    # Three tools take this argument — start_session, action_session,
    # action_trigger — and an agent that reads a different description on each
    # would get the scale wrong somewhere. The two things it has to land are the
    # two things agents get wrong when they see an integer next to a queue:
    #
    #   1. It is an ABSOLUTE scale, not a 1..N rank. 100000 comes before 50, and
    #      nothing renumbers.
    #   2. A child belongs just above its parent, so a tree of work stays
    #      contiguous instead of the child sinking behind unrelated queued work.
    module PrecedenceDocs
      # The shared core, embedded in every argument description below.
      SCALE = <<~TEXT.strip
        Precedence is an ABSOLUTE scale, not a 1..N rank and not a position: higher is handled sooner, so 100000 comes before 50, and 50 comes before 0. Values are sparse on purpose and nothing renumbers them — leave room to slot work between two existing values later. It orders SPOT sessions only (priority sessions start regardless), but it is carried on every session, so a session demoted to spot keeps the rank it was given.
      TEXT

      LINEAGE = <<~TEXT.strip
        Keep a lineage together: a session you spawn should have a precedence CLOSE TO its parent's and SLIGHTLY HIGHER (a point or two), so the child that finishes its parent's job runs before unrelated work queued beneath it and a tree of work stays contiguous. Omit the argument and Zimmer does exactly that for you — the new session lands one point above the session named in parent_session_id. Name a value only when you genuinely mean to move this work relative to everything else in the queue.
      TEXT

      START_SESSION = "#{SCALE}\n\n#{LINEAGE}".freeze

      ACTION_SESSION = <<~TEXT.strip
        Required for "change_precedence", and optional on "change_scheduling_class" so one call can demote a session and place it at the same time.

        #{SCALE}

        Moving one session does not move its children or its parent — read them with quick_search_sessions (which reports each session's precedence) and move the ones that should travel with it. To put a session at the head of the spot queue, read the current top with quick_search_sessions and pass a few points above it.
      TEXT

      ACTION_TRIGGER = <<~TEXT.strip
        Predefined precedence for sessions this trigger spawns. Send null to clear it, so spawned sessions take the default instead.

        #{SCALE}

        A trigger's value is the rank of the WORK IT REPRESENTS against everything else queued — a noisy feed nobody is waiting on belongs low, a trigger that unblocks a person belongs high — so it is set once here rather than on every session the trigger produces.
      TEXT
    end
  end
end
