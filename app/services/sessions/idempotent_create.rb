# frozen_string_literal: true

module Sessions
  # Makes "create a session" a safe thing to retry.
  #
  # The problem this exists for is not a bug in the create — it is that the
  # caller cannot see whether the create happened. `start_session` on the MCP
  # surface has repeatedly returned the reverse proxy's HTML 504 page *after* the
  # row committed (#577): the session exists, is healthy, and runs to completion,
  # while its caller holds an error carrying no session id and nothing to
  # distinguish "never landed" from "landed, response lost". The obvious response
  # to an error is to call again, and calling again produces a second session for
  # the same unit of work — a second clone, a second agent holding a Claude quota
  # slot, two branches and two PRs for one task. That has already happened once
  # (#9424 spawned as a retry of #9423; both live, one wasted).
  #
  # A client-supplied key names the *attempt* rather than the result, so the
  # second call carries the same name as the first and the server can recognise
  # it. The caller no longer has to know whether its first call landed.
  #
  # == Why the database index is the constraint
  #
  # The two calls are two HTTP requests, possibly on two Puma workers on two
  # machines, and the second can arrive while the first is still inside its
  # INSERT. No Ruby-side `exists?` can see an uncommitted row, so a check-then-
  # write is exactly the race this is supposed to close. The unique partial index
  # on `sessions.idempotency_key` is what actually holds; everything here is its
  # interpreter, turning a refusal into "here is the session you already made".
  #
  # Both shapes of that refusal occur and both are handled:
  #
  #   * the competing INSERT committed before we validated — the uniqueness
  #     validation sees it, and `save` returns false with a `:taken` error;
  #   * it committed while our INSERT waited on the index — Postgres raises,
  #     surfacing as `ActiveRecord::RecordNotUnique`.
  #
  # == What it deliberately does not do
  #
  # It does not fingerprint the request. A repeated key returns the session that
  # key created, whatever arguments came with the repeat — it does not check that
  # the second call asked for the same thing, and it does not reject the second
  # call for asking for something different. The failure being closed is a lost
  # response to an identical retry; a caller that reuses one key for two genuinely
  # different sessions has made a different mistake, and silently returning the
  # first is the same answer a fingerprint check would produce minus an error
  # nobody could act on.
  module IdempotentCreate
    # The unique index the whole mechanism rests on. Named here because the only
    # discriminator Postgres offers, once ActiveRecord has wrapped the error, is
    # the constraint name inside the message text.
    KEY_INDEX = "index_sessions_on_idempotency_key"

    # One create's outcome. `reused` is the whole point: a caller that wants to
    # say "no new session was made" needs to be told, and a caller that must not
    # enqueue a second agent job needs to be told before it does.
    Result = Struct.new(:session, :reused, keyword_init: true) do
      def reused? = reused == true

      def created? = !reused?
    end

    module_function

    # The session already created under this key, or nil.
    #
    # The ordinary retry is sequential — the first create committed, its response
    # was lost at the proxy, the caller called again seconds later — so a plain
    # lookup answers it without going near the write path.
    #
    # @param key [String, nil]
    # @return [Session, nil]
    def existing(key)
      return nil if key.blank?

      Session.find_by(idempotency_key: key)
    end

    # Save `session`, treating "another request already used this key" as success
    # and returning the session that won rather than an error.
    #
    # @param session [Session] a new record carrying `idempotency_key`
    # @param key [String, nil] the same key; nil or blank makes this a plain save
    # @return [Result, nil] nil when the save failed for any other reason, which
    #   leaves the caller's own error handling in charge of the model errors
    # @raise [ActiveRecord::RecordNotUnique] when the violated constraint was not
    #   the idempotency key (a duplicate `slug`, say) — that is still an error
    def save(session, key)
      if session.save
        Result.new(session: session, reused: false)
      elsif session.errors.of_kind?(:idempotency_key, :taken)
        conflict(key)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise if other_index?(e)

      conflict(key) || raise
    end

    # True when the violation names a unique index that is NOT the idempotency
    # key's — a duplicate `slug`, say, which must stay an error rather than
    # becoming a silent, wrong "here is your session".
    #
    # A message that names no index at all falls through to the key check instead
    # of raising. That direction is deliberate: matching on Postgres's wording is
    # a string copy rather than a contract, and an unrecognised phrasing must not
    # turn the retry this class exists for back into the 500 it was built to
    # remove.
    def other_index?(error)
      named = error.message[/unique constraint "([^"]+)"/, 1]
      named.present? && named != KEY_INDEX
    end

    # @return [Result, nil] nil when nothing holds the key, so the caller can
    #   re-raise rather than swallow a violation that was never about this key.
    def conflict(key)
      winner = existing(key)
      return nil unless winner

      Result.new(session: winner, reused: true)
    end
  end
end
