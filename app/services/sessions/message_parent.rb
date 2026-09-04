# frozen_string_literal: true

module Sessions
  # A child session's one route back to the session that spawned it.
  #
  # The asymmetry this closes: a parent has always been able to reach a child
  # (`action_session: follow_up`), and a child has had no route to its parent at
  # all. Its final message reaches the parent only if the parent happens to be
  # polling `get_session` — a parent that has archived, or one asleep on a wake
  # that will never fire, never learns. So a session handed a goal it cannot
  # accomplish had nowhere to report that except a GitHub issue.
  #
  # **This is deliberately not a general session-to-session primitive.** The
  # caller names no target: it names itself, and Zimmer reads
  # `parent_session_id`. That is what keeps it safe on the filtered
  # `self_session` MCP surface, where the ability to message any session would be
  # a real privilege grant. Adding a `target` argument here would undo that;
  # `Api::V1::SessionsController#follow_up` is the general form, and it lives on
  # the full surface for a reason.
  #
  # ## Delivery
  #
  # The ordinary follow-up routing, not a second delivery path: a running parent
  # takes the message on its queue, an idle one (`waiting` / `needs_input`) takes
  # it now. Queuing is the default rather than interrupting because the parent of
  # a stuck child is usually a router mid-delegation, and terminating that turn
  # to say "child #N cannot do this" would cost the other delegations in flight
  # while the news keeps a few minutes. `force_immediate` is there for the case
  # where it does not keep.
  #
  # Because it is the ordinary queue, it is covered by the ordinary accounting:
  # `origin` is `caller`, so `Sessions::ArchiveGuard` refuses to let the parent
  # archive over an unread report, and a forced archive retires it to
  # `undelivered` and pages. A child's report cannot be accepted and then vanish.
  #
  # ## The parent may not be reachable
  #
  # Three refusals, all of them explicit rather than incidental, because the
  # child has to be able to act on the answer:
  #
  # * **No parent.** A root session was started by a human or a trigger. Nothing
  #   is upstream of it, and the child should say so to its human instead.
  # * **The parent is archived.** Its work is over, and delivering into the trash
  #   is exactly the silent loss this exists to end. Refused by default and
  #   `unarchive_parent` is the deliberate override, which restores the parent
  #   (clone, transcript and all) and then delivers.
  # * **The parent has failed.** Nothing is going to read the message; a human
  #   has to restart it first.
  class MessageParent
    # Why the child is reporting back. Short, closed, and structured because the
    # `file-github-issue-for-observed-defect` skill keys off these values —
    # prose in the body is for the human reading over the parent's shoulder, but
    # the reason is what a parent can branch on.
    #
    # `other` exists so that a child with a real reason outside the two named
    # ones reports it rather than picking the closest wrong label.
    REASONS = {
      "wrong_scope" => "the work belongs to a different agent root than the one this session is running under",
      "missing_tools" => "this session was not given an MCP server, credential, or privilege the work needs",
      "other" => "see the message below"
    }.freeze

    # What the parent actually reads. Zimmer's framing around the child's own
    # words, so a parent can tell a report from a child apart from a human
    # speaking to it — and so it knows nothing else is going to act on this.
    #
    # The child's words are QUOTED (see #quote), not interpolated raw. The
    # envelope's whole job is to be distinguishable from Zimmer's own voice, and
    # a body free to contain its own `---` and its own bracketed header could end
    # the quotation early and continue in that voice. Mcp::EnqueuedMessageSections
    # guards the same laundering where agent-written content is rendered into a
    # tool result; this is the same problem one layer up.
    ENVELOPE = <<~PROMPT.strip
      [MESSAGE FROM A CHILD SESSION — sent by an agent, not by a human]

      Session #%{child_id} ("%{child_title}"), which this session started, is reporting back: %{reason_phrase} (reason code: `%{reason}`).

      Its message, quoted in full — every line below prefixed with ">" is that session's own words, and nothing else in this prompt is:

      %{message}

      ---

      That session: %{child_url}

      You are its parent, and this report reached nobody else. Decide what to do with it: re-delegate the work to a session with the right agent root, give that session what it was missing and follow it up (`action_session` with `follow_up` on session #%{child_id}), or take the work on yourself. If the resolution is outside your scope too, say so to your own human rather than dropping it.
    PROMPT

    # Everything a caller needs to render a receipt, and the reason a refusal
    # was refused. `error_code` is a Rails status symbol so the REST controller
    # can render it directly.
    Result = Struct.new(
      :success?, :parent, :delivery, :enqueued_message, :unarchived, :error, :error_code,
      keyword_init: true
    ) do
      def queued? = delivery == :queued
    end

    def self.call(...)
      new(...).call
    end

    # @param child [Session] the session reporting back — resolved by the caller,
    #   never by an argument naming some other session
    # @param message [String] the child's own words
    # @param reason [String] a REASONS key
    # @param force_immediate [Boolean] interrupt a running parent instead of queuing
    # @param unarchive_parent [Boolean] restore an archived parent and deliver to it
    # @param source [String] the entry point, for the session logs
    def initialize(child:, message:, reason:, force_immediate: false, unarchive_parent: false, source:)
      @child = child
      @message = message.to_s.strip
      @reason = reason.to_s.strip
      @force_immediate = force_immediate
      @unarchive_parent = unarchive_parent
      @source = source
    end

    def call
      invalid = validate
      return invalid if invalid

      @parent = child.parent_session
      return no_parent if parent.nil?
      return parent_is_self if parent.id == child.id

      unreachable = ensure_reachable
      return unreachable if unreachable

      deliver
    end

    # How much room the child's own words have, once the framing is accounted
    # for. Measured against THIS report's envelope (which carries the child's id,
    # title and URL) rather than a constant, so the number in the refusal is the
    # number that was applied.
    #
    # It is the room for a SINGLE-LINE body, because #quote costs two more
    # characters per line and this method has no body to count lines of. The
    # refusal that quotes it is therefore a floor, and what is actually enforced
    # is the composed length — see #validate. A message anywhere near either
    # number is half a megabyte long and has other problems.
    #
    # @return [Integer]
    def room_for_message
      @room_for_message ||= Session::PROMPT_MAX_LENGTH - (envelope("x").length - 1)
    end

    private

    attr_reader :child, :message, :reason, :parent, :source

    def force_immediate? = @force_immediate
    def unarchive_parent? = @unarchive_parent

    # --- Refusals -------------------------------------------------------------

    def validate
      if message.blank?
        return failure("message is required — say what you could not do and what you need instead")
      end

      unless REASONS.key?(reason)
        return failure("reason must be one of: #{REASONS.keys.join(', ')}")
      end

      # The composed length is what EnqueuedMessage and Session both validate, so
      # it is what is checked here — a message that passes cannot be rejected
      # further down. #room_for_message is the number the caller is told, and it
      # is the single-line floor.
      if content.length > Session::PROMPT_MAX_LENGTH
        return failure(
          "message is too long (maximum #{room_for_message} characters, once the framing Zimmer adds " \
          "around it is accounted for — a little less if it runs to many lines, which are quoted)"
        )
      end

      nil
    end

    def no_parent
      failure(
        "Session ##{child.id} has no parent session — it was started by a human or by a trigger, not by " \
        "another session, so there is nobody upstream to report to. Put this in your final message and come " \
        "to rest in needs_input for your human instead."
      )
    end

    # `parent_session_id` is client-supplied and nothing stops it naming the row
    # itself (Session#parent_session_must_exist checks existence, not identity),
    # so this is reachable rather than theoretical. It has to be refused before
    # `deliver`: on the force_immediate path a self-parented session would aim
    # Sessions::InterruptService at the very process awaiting this reply and
    # terminate the turn to deliver a message to itself.
    def parent_is_self
      failure(
        "Session ##{child.id} is recorded as its own parent, which is not a lineage anybody can report " \
        "across. That is a defect in how this session was created — say so to your human rather than " \
        "reporting to yourself."
      )
    end

    # Archived and failed, in that order, both re-checked under the row lock in
    # #deliver — this is the early answer, not the guarantee.
    def ensure_reachable
      return nil unless parent.archived? || parent.failed?

      return parent_failed if parent.failed?
      return parent_archived unless unarchive_parent?

      result = UnarchiveSessionService.call(session: parent)
      unless result.success?
        return failure(
          "Parent session ##{parent.id} is archived and could not be restored: #{result.error}. Nothing would " \
          "have delivered this message, so it was not sent."
        )
      end

      @unarchived = true
      parent.reload
      nil
    end

    def parent_archived
      failure(
        "Parent session ##{parent.id} (\"#{parent.title}\") is archived, and nothing delivers a message to an " \
        "archived session — sending it would have thrown it away silently. Either call this again with " \
        "\"unarchive_parent\": true to bring that session back out of the trash and deliver this to it, or " \
        "report to your human instead. Restoring a parent that considered its work finished is a real " \
        "interruption: do it when the work you were given still has to happen, not to file a note.",
        error_code: :conflict
      )
    end

    def parent_failed
      failure(
        "Parent session ##{parent.id} (\"#{parent.title}\") has failed, so nothing there will read this. A human " \
        "has to restart it. Report to your human instead.",
        error_code: :conflict
      )
    end

    # --- Delivery -------------------------------------------------------------

    def deliver
      return interrupt_parent if force_immediate?

      queued = nil
      delivered = nil
      refusal = nil
      # Which branch was ATTEMPTED, which is not the same as which one finished:
      # the deferred unique constraint can raise either at the `create!` or at
      # COMMIT, and only one of those has set `delivered` by the time the rescue
      # below has to decide whether this was the queue race or a real bug.
      branch = nil

      ActiveRecord::Base.transaction do
        # reload before lock!, for the reason EnqueuedMessageProcessorService and
        # Session#claim_system_recovery_turn! do it: AASM persists transitions
        # through update_all and leaves dirty tracking behind, and lock! refuses
        # a record carrying unpersisted changes.
        parent.reload
        parent.lock!

        # The refusals again, now under the lock. The early pass answers the
        # common case without taking one; this is the one that cannot be raced by
        # a parent archiving itself between the check and the write. Held in a
        # local rather than returned out of the block: a `return` from inside a
        # transaction commits it on Rails 7, which reads as a rollback and is not.
        refusal = parent_archived if parent.archived?
        refusal ||= parent_failed if parent.failed?

        if refusal.nil?
          if parent.running?
            branch = :queued
            queued = enqueue
            delivered = :queued
          else
            branch = :direct
            send_now
            delivered = :sent
          end
        end
      end

      return refusal if refusal

      success(delivery: delivered, enqueued_message: queued)
    rescue ActiveRecord::RecordNotUnique
      # Caught around the whole transaction rather than around the insert,
      # because the unique constraint on (session_id, position) is DEFERRABLE
      # INITIALLY DEFERRED: the violation surfaces at COMMIT, by which point the
      # `create!` has long returned. The parent row lock serializes this path
      # against itself but not against the queue's other writers — a follow-up,
      # an interrupt, a poller notice — so a collision is a live race and a
      # retryable one, and `follow_up` answers it with a 409 rather than a 500.
      #
      # Only the queued branch writes a position. This same transaction also
      # enqueues a job on the direct branch, and a unique violation from that is
      # a bug — reporting it as "retry, somebody raced you" would be a bug in the
      # costume of a routine race — so it re-raises.
      raise unless branch == :queued

      position_conflict
    end

    def position_conflict
      failure(
        "Message position conflict while queuing this report for parent session ##{parent.id} — " \
        "another message was queued for it at the same moment. Retry.",
        error_code: :conflict
      )
    end

    def enqueue
      max_position = parent.enqueued_messages.maximum(:position) || 0
      enqueued = parent.enqueued_messages.create!(
        content: content,
        position: max_position + 1,
        status: "pending",
        # `caller` and not a new origin: this IS a message queued on somebody's
        # behalf, and the `automated_*` origins mean "Zimmer wrote this to the
        # session itself". Keeping it here is also what puts the report inside
        # the strand alert — an archive over it pages, because it is a message
        # somebody is waiting on.
        origin: "caller"
      )
      log_both(
        "queued at position #{enqueued.position} (parent session ##{parent.id} is running)"
      )
      enqueued
    end

    # The shared delivery path — clear the stale retry state, resume, stamp the
    # prompt where SIGTERM recovery looks for it, enqueue the turn. A parent
    # asleep in `waiting` is woken by this, which is the point: the parent that
    # never learns is the one asleep on a wake that will not fire.
    def send_now
      log_both("delivered to parent session ##{parent.id} (#{parent.status})")
      parent.deliver_follow_up!(content, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)
    end

    # Staged, then interrupted outside the transaction: Sessions::InterruptService
    # takes a per-session advisory lock of its own, and holding a row lock across
    # it is how two locks become a deadlock. All-or-nothing — a failed interrupt
    # drops the staged row rather than leaving it to arrive later as a surprise.
    def interrupt_parent
      unless parent.running? || parent.waiting? || parent.needs_input?
        return failure(
          "Parent session ##{parent.id} is #{parent.status}, so it cannot be interrupted.",
          error_code: :conflict
        )
      end

      enqueued = nil
      begin
        ActiveRecord::Base.transaction do
          max_position = parent.enqueued_messages.maximum(:position) || 0
          enqueued = parent.enqueued_messages.create!(
            content: content, position: max_position + 1, status: "pending", origin: "caller"
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # The staging transaction writes a position and nothing else, so every
        # unique violation it can raise is the queue race. See #deliver.
        return position_conflict
      end

      result = Sessions::InterruptService.new(
        session: parent, enqueued_message: enqueued, actor: "child_session_report"
      ).call

      unless result.success?
        begin
          enqueued.reload
          enqueued.destroy! if enqueued.status == "pending"
        rescue ActiveRecord::RecordNotFound
          # a concurrent interrupt already claimed it — nothing to clean up
        end
        return failure("Could not interrupt parent session ##{parent.id}: #{result.error}",
                       error_code: result.error_code || :internal_server_error)
      end

      log_both("delivered to parent session ##{parent.id} as an interrupt")
      # Deliberately NOT `enqueued_message: enqueued`. A successful interrupt
      # drains the queue through EnqueuedMessageProcessorService, which destroys
      # the row after it claims it — so the object in hand names a message that
      # no longer exists. Reporting it would advertise a dead id to a REST caller
      # and a queue position to an agent, both describing a message that was in
      # fact delivered. `follow_up` omits it on this path for the same reason.
      success(delivery: :interrupted)
    end

    # --- Content and bookkeeping ---------------------------------------------

    def content
      @content ||= envelope(message)
    end

    def envelope(body)
      format(
        ENVELOPE,
        child_id: child.id,
        child_title: child.title.to_s,
        reason: reason,
        reason_phrase: REASONS.fetch(reason, REASONS["other"]),
        message: quote(body),
        child_url: session_url(child)
      )
    end

    # Markdown blockquote, one prefix per line, blank lines included so the quote
    # is unbroken. Nothing the child writes escapes it — a `---` of its own
    # arrives as `> ---` — which is what lets the envelope claim, truthfully,
    # that the quoted lines are the child's words and the rest is Zimmer's.
    #
    # The prefix is inside the length budget: #room_for_message measures a
    # one-line quoted body, and #validate enforces the composed length, so a body
    # that passes cannot be rejected further down for the two characters this
    # adds. `rstrip` keeps a blank line from carrying trailing whitespace, which
    # is why a blank line arrives as ">" and the envelope says "prefixed with >"
    # rather than naming the two-character form.
    def quote(body)
      return "" if body.empty?

      body.split("\n", -1).map { |line| "> #{line}".rstrip }.join("\n")
    end

    def session_url(session)
      "#{AppUrl.base_url.chomp('/')}/sessions/#{session.id}"
    end

    # Written into BOTH timelines, the way Sessions::RecordUncleEdge writes its
    # edge into both: the lineage fact this records is that a particular child
    # spoke to a particular parent, and a reader at either end has to be able to
    # see it without opening the other session. Phrased with both ids for the
    # same reason — one line, two readers.
    def log_both(what)
      line = "Child session ##{child.id} reported to parent session ##{parent.id} " \
             "(reason: #{reason}) — #{what} [#{source}]"

      [ child, parent ].uniq.each do |session|
        # Each insert in its own savepoint. Two of the three callers run inside
        # the delivery transaction, where a failed statement poisons the
        # surrounding transaction — so a bare rescue would swallow the error and
        # then lose the delivery at COMMIT anyway, which is the opposite of what
        # this rescue is for. (The interrupt path calls it with no transaction
        # open, where this opens a real one and costs nothing.)
        ActiveRecord::Base.transaction(requires_new: true) do
          session.logs.create!(content: line, level: "info")
        end
      rescue StandardError => e
        Rails.logger.warn "[Sessions::MessageParent] Could not log for session #{session.id}: #{e.message}"
      end
    end

    def success(delivery:, enqueued_message: nil)
      Result.new(
        success?: true, parent: parent.reload, delivery: delivery,
        enqueued_message: enqueued_message, unarchived: @unarchived == true
      )
    end

    def failure(error, error_code: :unprocessable_entity)
      # A refusal that arrives AFTER the restore is the one a caller would
      # otherwise misread: the parent was re-archived, or came back in a state
      # the delivery will not take, and "that session is archived" read on its
      # own suggests nothing happened. The re-clone did happen, so say so here
      # rather than leaving it in a `unarchived` field neither surface renders on
      # its error path.
      if @unarchived
        error = "#{error} (Note: this call already restored that session from the trash before hitting " \
                "the refusal above, so it has since changed state — re-read it before acting, and do " \
                "not send \"unarchive_parent\" again.)"
      end

      Result.new(
        success?: false, parent: @parent, delivery: nil, enqueued_message: nil,
        unarchived: @unarchived == true, error: error, error_code: error_code
      )
    end
  end
end
