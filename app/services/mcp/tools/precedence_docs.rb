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
    #   3. "Put this first" is a PLACEMENT, not a number to work out — the
    #      symbolic `place` argument, which the server resolves against the live
    #      queue, rather than a read of the current top followed by a write a few
    #      points above it, which another session can overtake in between.
    module PrecedenceDocs
      # The shared core, embedded in every argument description below.
      SCALE = <<~TEXT.strip
        Precedence is an ABSOLUTE scale, not a 1..N rank and not a position: higher is handled sooner, so 100000 comes before 50, and 50 comes before 0. Values are sparse on purpose and nothing renumbers them — leave room to slot work between two existing values later. It orders SPOT sessions only (priority sessions start regardless), but it is carried on every session, so a session demoted to spot keeps the rank it was given.
      TEXT

      # The `place` argument's own description, on start_session and
      # action_session. Every agent with this server reads it before ranking
      # work, so it has to say unambiguously which of the two forms to reach for.
      PLACE = <<~TEXT.strip
        Symbolic placement in the spot queue: the server works the number out for you, against the queue as it stands at the moment of the write. The only value is "top_of_spot", which puts the session at the HEAD of the spot queue — a few points above the highest-ranked spot session there is right now.

        USE "top_of_spot" whenever what you mean is "this goes before the rest of the spot queue" and you do not care what number that works out to. It is one call, and it cannot be beaten by a session that lands above you mid-flight. Do NOT read the current top with quick_search_sessions and pass a number above it instead: that is two calls, and another session can land above your value between the read and the write, leaving your session second in the queue it was meant to head.

        USE an absolute `precedence` integer instead whenever you mean a particular rank rather than the top: anything below the head of the queue, a value you want several sessions to share, a rank you will compare against later, or work that should stay with its lineage (for that, on start_session, name nothing at all — the default already puts a spawn one point above its parent). "top_of_spot" is a placement and not a number you can reason about afterwards; what it resolves to depends on what is queued at that instant.

        Mutually exclusive with `precedence`: passing both is an error, since they are two different answers to the same question. Passing neither leaves the ordinary behaviour alone.
      TEXT

      LINEAGE = <<~TEXT.strip
        Keep a lineage together: a session you spawn should have a precedence CLOSE TO its parent's and SLIGHTLY HIGHER (a point or two), so the child that finishes its parent's job runs before unrelated work queued beneath it and a tree of work stays contiguous. Omit the argument and Zimmer does exactly that for you — the new session lands one point above the session named in parent_session_id. Name a value only when you genuinely mean to move this work relative to everything else in the queue.

        To spawn a session at the HEAD of the spot queue, do not work the number out: leave this argument off and pass `place: "top_of_spot"` instead, which the server resolves against the live queue in the same call.
      TEXT

      START_SESSION = "#{SCALE}\n\n#{LINEAGE}".freeze

      ACTION_SESSION = <<~TEXT.strip
        Required for "change_precedence", and optional on "change_scheduling_class" so one call can demote a session and place it at the same time.

        #{SCALE}

        Moving one session does not move its children or its parent — read them with quick_search_sessions (which reports each session's precedence) and move the ones that should travel with it.

        To put a session at the HEAD of the spot queue, do not work the number out: leave this argument off and pass `place: "top_of_spot"` instead. The server resolves it against the live queue in the same write, and against the queue MINUS this session, so re-placing a session that is already on top does not walk it upwards.
      TEXT

      ACTION_TRIGGER = <<~TEXT.strip
        Predefined precedence for sessions this trigger spawns. Send null to clear it, so spawned sessions take the default instead.

        #{SCALE}

        A trigger's value is the rank of the WORK IT REPRESENTS against everything else queued — a noisy feed nobody is waiting on belongs low, a trigger that unblocks a person belongs high — so it is set once here rather than on every session the trigger produces. An absolute integer is the only form a trigger takes: there is no "top_of_spot" here, because this value is stamped on every session the trigger ever spawns, and a standing instruction to jump the whole queue is not a rank.
      TEXT
    end
  end
end
