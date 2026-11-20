# frozen_string_literal: true

module WorkBacklog
  # Re-checks backlog rows that have left `queued` and asks whether the reason
  # they left is still true. It writes down what it finds and changes nothing
  # else.
  #
  # == The hole this closes
  #
  # A row leaves `queued` by two routes and neither has a way back. A pull marks
  # it `started` and spawns a session; a pull's mechanical removal marks it
  # `removed` with the fact it observed. After that nothing reads the row again —
  # `Ranking` and the pull both look only at `queued` rows — so when the premise
  # expires, the item is neither queued nor being worked, and nothing says so.
  # Measured 2026-09-11 across the fleet's gated repos: of 159 open convergent
  # issues, 41 were `started` and 13 had been for four days or more.
  #
  # The loss is silent in the worst way. The Issues page renders such an issue
  # under "In GitHub, not on the queue", beside everything the gate has never
  # rated, so a pile of work the fleet started and dropped reads as ordinary
  # un-triaged work. That is the confusion this exists to end.
  #
  # == Why it does not put anything back
  #
  # The obvious fix — re-queue a `started` row whose session ended with the issue
  # still open — is wrong, and the evidence is specific. On 2026-09-11 a session
  # examined 12 such rows by hand (Zimmer session 16349). What it found:
  #
  #   * 6 were DELIBERATE PARTIAL COMPLETIONS. The PR fixed part of the issue and
  #     said so — "Addresses #419 … auto-closing on merge would drop a known,
  #     still-live production gap". A real remainder is outstanding, and those
  #     rows do belong back on the queue.
  #   * 4 were FULLY DONE. The work merged; the PR simply carried no closing
  #     keyword, so GitHub never closed the issue. Re-queuing those spends a
  #     session redoing finished work.
  #   * 2 had an open PR in flight.
  #   * 1 had been pulled a month AFTER its fix had already merged, and what
  #     remains of it is a question only a human can answer.
  #
  # **The first two groups are indistinguishable by any mechanical signal.** Both
  # are "issue open, a merged PR references it, no closing keyword". Telling them
  # apart took reading each PR's scope section and checking whether the defect
  # still existed in `main` — judgement, per issue. A sweep keyed on "session
  # archived and issue still open" re-queues the finished four; one keyed on "a
  # merged PR references the issue" closes the six that have a remainder. Both
  # directions destroy something, so this makes the call that a cron job is
  # entitled to make: none of them.
  #
  # The exception is a row whose AUTHOR made that call when appending it: a
  # `continuation` marker (WorkBacklogItem::CONTINUATIONS) says the issue stays
  # open by design. A `multi_slice` row whose slice merged is re-queued for the
  # next slice (`continue_slice`); an `awaiting_recurrence` row with a merged PR
  # reads resolved. A row with no marker is still never acted on (#1489).
  #
  # What it does instead is name the population and put the evidence beside each
  # row, so the triage that must happen can happen — by a human on the Issues
  # page, or by an agent reading `status: "stranded"`. Putting an item back is
  # then an ordinary `append_work_backlog_item`, which is confirmed to work on a
  # key whose only row is `started` (6 of 6 on 2026-09-11): the old row stays as
  # history and a fresh `queued` row is created.
  #
  # == The three ways a row strands, and the one this misses
  #
  #   1. `started` rows whose session ENDED — covered.
  #   2. `removed` rows whose removal was PROVISIONAL — covered. A pull may
  #      remove an item because the issue has an open PR, or because a session is
  #      already working it. Both are facts with a shelf life:
  #      `tadasant/zimmer#522` was removed as `issue_has_open_pr` and its PR has
  #      not been touched since 2026-08-21. Nothing re-checked it.
  #   3. Issues with NO backlog row at all — **not covered, and cannot be from
  #      here.** Before 2026-08-29 the gate started sessions itself, and the
  #      migration into this table imported only `queued` items, so that work
  #      left no row to re-check. `tadasant/zimmer#368` is one: 37 days stranded,
  #      and invisible to anything that reads this table. Those issues appear on
  #      the Issues page under "In GitHub, not on the queue", which is where a
  #      sweep over GitHub rather than over rows would have to start.
  #
  # == Reads that fail are never conclusions
  #
  # A repo whose probe errors, and an issue GitHub could not resolve, both leave
  # the row `unknown` and re-examined next pass. Nothing here infers a state it
  # could not read.
  class LivenessSweep
    # How long after its session ends a `started` row is left alone. A merge
    # closes the issue seconds later and the PR poller records the merge shortly
    # after, so a row examined immediately looks stranded while it is merely
    # settling.
    GRACE = 6.hours

    # How long an OPEN pull request may go untouched before the row it is holding
    # up counts as stalled rather than in flight. Two weeks is well past the
    # fleet's own PR turnaround and short enough to catch the case this was
    # written for — zimmer#522's PR, idle three weeks and still counted as live
    # by anything that only asks whether a PR exists.
    STALE_PR_AFTER = 14.days
    # Rows examined per pass. Each repo costs a request per BATCH_SIZE issues
    # rather than a request per row, so this is generous; it exists so a surprise
    # population cannot turn one tick into an hour.
    MAX_EXAMINED_PER_SWEEP = 200
    # How long a row may sit stranded before a human is told about it. The point
    # of the alert is that this population used to have no upper bound at all —
    # the worst row observed had sat for 37 days. A row is OVERDUE once it has
    # been out of the queue this long, and every overdue row is covered by at
    # least one page. See `alert_if_overdue`.
    ALERT_AFTER = 7.days

    # The population sizes that count as a step change. A count climbing through
    # one of these pages again; one drifting between two of them does not. Coarse
    # on purpose — the question a second page has to answer is "is this
    # materially worse than when I was last told", and 21 rows against 23 is not.
    ALERT_ROW_BANDS = [ 1, 10, 25, 50, 100, 250, 500, 1000 ].freeze

    # The reminder ladder for a population nobody acts on, in multiples of
    # ALERT_AFTER: the oldest row's age pages again at 1, 2, 4, 8, 16, 32… weeks,
    # doubling with no ceiling. Before #1592 the reminder was every week, and one
    # five-row population that needed a human decision paged six times in two
    # weeks with nothing new to say. Doubling keeps a population nobody acts on
    # paging — at 70 days the next reminder is at 112 — without a page a week.
    # The rung is `floor(log2(weeks))`; see `ladder_rung`.
    ALERT_LADDER_BASE = 2

    # The prefix every page's fingerprint starts with. The severity band and the
    # time of the paging pass are appended to it, so each page opens its own
    # GlitchTip issue and notifies once — see `alert_if_overdue`.
    ALERT_FINGERPRINT = "work-backlog-stranded-rows"

    # How many newly stranded rows a page names by key. The rest are counted.
    NAMED_ROWS_MAX = 20

    # WHAT THE PAGE DOES NOT COUNT: rows a triager has held for a human decision
    # (WorkBacklogItem.awaiting_decision). They are out of `stranded` — both the
    # age and the row count — until their hold lapses (WorkBacklogItem::HOLD_DURATION),
    # and the page names how many are held so a reader knows the number is not the
    # whole pile. A hold lapses only when WorkBacklog::DecisionDigest has stopped
    # renewing it, and the digest logs that at ERROR, which pages on its own. So a
    # lapse is not news by itself: it pages only on a row no page has covered. See
    # `alert_if_overdue`.

    # What one pass found. `repos_failed` is separate from the outcome counts
    # because a repo nobody could read is a fault, where an `unknown` row might
    # just be an issue that was deleted.
    Result = Data.define(:examined, :outcomes, :oldest_stranded_age, :repos_failed) do
      def count(state) = outcomes.fetch(state, 0)
    end

    # One stranded row, as much of it as the page needs. `since` is when it left
    # the queue; `paged_at` is the last page that covered it.
    StrandedRow = Data.define(:id, :key, :since, :paged_at, :lapsed) do
      def overdue?(now) = since <= now - ALERT_AFTER

      # Has a page gone out for this row since it became overdue? A page sent
      # while it was still young counted it but did not report it as stranded,
      # so that does not cover it.
      def covered? = paged_at.present? && paged_at >= since + ALERT_AFTER
    end

    class << self
      # @param now [Time]
      # @param logger [StructuredLogger, Logger]
      # @return [Result]
      def sweep!(now: Time.current, logger: Rails.logger)
        rows = candidates(now)
        result = rows.empty? ? empty_result(now) : examine(rows, now, logger)

        # On EVERY pass, the empty one included. A population that has just been
        # triaged away leaves nothing to examine, and that is precisely the pass
        # that has to notice the condition is over — see `alert_if_overdue`.
        alert_if_overdue(result, now)
        report(result, logger)
      end

      # The rows worth a look: every unsettled row before any settled one, then
      # least-recently-checked first so a large population round-robins rather
      # than the sweep re-reading the head of it every pass. Rows nothing has ever
      # said anything about sort first within their tier.
      #
      # The tier comes first because the candidate population only grows. A
      # candidate whose issue closed stays a candidate, so a plain round-robin
      # spends most of MAX_EXAMINED_PER_SWEEP re-confirming closed issues, and a
      # stranded row waits several passes for its turn. On 2026-09-12 zimmer#173
      # was still listed as stranded more than an hour after it closed, while
      # rows beside it had been checked in a later pass. With settled rows last,
      # every stranded row is re-checked on every pass as long as there are fewer
      # than MAX_EXAMINED_PER_SWEEP of them, and the settled rows share what is
      # left. Past that there is nothing left, and a reopened issue is not
      # re-checked until the unsettled population drops back under the cap.
      def candidates(now)
        WorkBacklogItem.liveness_candidates(grace: GRACE, now: now)
                       .order(Arel.sql(settled_last_sql),
                              Arel.sql("liveness_checked_at ASC NULLS FIRST"), id: :asc)
                       .limit(MAX_EXAMINED_PER_SWEEP)
                       .to_a
      end

      # THE CLASSIFICATION, and the line it refuses to cross. Every branch here is
      # a statement about what GitHub currently says; none of them is a decision
      # about what to do with the work. `pr_merged_issue_open` in particular is
      # the ambiguous one — a finished issue whose PR forgot the keyword, or a
      # deliberate partial with a real remainder — and it is left ambiguous on
      # purpose rather than guessed at.
      def classify(item, probe, now)
        # Asked before GitHub, because it is the one verdict that does not depend
        # on GitHub: the triage already happened and left a newer row behind.
        return WorkBacklogItem::LIVENESS_SUPERSEDED if item.superseded?
        return WorkBacklogItem::LIVENESS_UNKNOWN if probe.nil?
        return WorkBacklogItem::LIVENESS_ISSUE_CLOSED unless probe.open?

        open_references = probe.open_references
        if open_references.any?
          moving = open_references.reject { |reference| reference.idle?(STALE_PR_AFTER, now: now) }
          return moving.any? ? WorkBacklogItem::LIVENESS_PR_OPEN : WorkBacklogItem::LIVENESS_PR_STALLED
        end

        if probe.merged_references.any?
          # The one place a row's own declaration changes the verdict, and only
          # in the ambiguous case it was declared for, and only when this row's
          # own work merged. An older merged PR says nothing about whether the
          # session this row started did anything. See
          # WorkBacklogItem::CONTINUATIONS.
          if item.awaiting_recurrence? && merged_since_left(item, probe)
            return WorkBacklogItem::LIVENESS_AWAITING_RECURRENCE
          end

          return WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN
        end

        WorkBacklogItem::LIVENESS_NO_PR
      end

      # The latest merged reference that merged after the row left the queue, or
      # nil: the slice a `multi_slice` row landed, or the work an
      # `awaiting_recurrence` row's session merged. A merged PR from before the
      # row left belongs to an earlier row, so a session that ended with nothing
      # finds nil here and the row strands and pages like any other. A reference
      # with no `merged_at` is not counted: a time that could not be read is not
      # evidence.
      def merged_since_left(item, probe)
        left = item.left_queue_at
        return nil if left.nil? || probe.nil?

        probe.merged_references.select { |reference| reference.merged_at && reference.merged_at >= left }
             .max_by(&:merged_at)
      end

      private

      def settled_last_sql
        WorkBacklogItem.sanitize_sql_array(
          [ "CASE WHEN liveness_state IN (?) THEN 1 ELSE 0 END ASC", WorkBacklogItem::SETTLED_LIVENESS_STATES ]
        )
      end

      # One pass over the rows worth a look: probe each repo once, classify every
      # row it came back with, and write each verdict down.
      #
      # Grouped by the repository the ISSUE lives in, not by `repo`. A row's issue
      # number is only meaningful in its issue's repository, and the gate points
      # `repo` elsewhere on purpose when the fix does not live beside the issue.
      # Asked in `repo`, that number names a PR, a 404, or an unrelated issue
      # whose state the row would take (#1188). `repo` is the fallback for a row
      # whose `issue_url` is not a github.com issue URL.
      def examine(rows, now, logger)
        outcomes = Hash.new(0)
        failed = []

        rows.group_by { |item| item.issue_repo || item.repo }.each do |repo, repo_rows|
          probes = probe(repo, repo_rows, logger) { failed << repo }
          repo_rows.each do |item|
            row_probe = probes && probes[item.issue_number]
            state = classify(item, row_probe, now)
            record(item, state, now, logger)
            state = WorkBacklogItem::LIVENESS_SUPERSEDED if continue_slice(item, state, row_probe, now, logger)
            outcomes[state] += 1
          end
        end

        Result.new(examined: rows.size, outcomes: outcomes,
                   oldest_stranded_age: oldest_stranded_age(now), repos_failed: failed)
      end

      # One row's verdict, written so that one bad row cannot cost every other.
      # `update!` validates, and a legacy row that fails validation for an
      # unrelated reason would abort the whole pass — permanently, because a row
      # that raises keeps `liveness_checked_at` NULL and so sorts first on the
      # next pass too, and the one after that. The sweep would go quiet while
      # reporting nothing, which is the failure it exists to end.
      def record(item, state, now, logger)
        item.record_liveness!(state, now: now)
      rescue ActiveRecord::ActiveRecordError => e
        logger.warn("[WorkBacklog::LivenessSweep] could not record #{state} on item #{item.id} " \
                    "(#{item.key}): #{e.class}: #{e.message}")
      end

      # THE ONE THING THIS PUTS BACK, and only because the row asked for it on
      # append (#1489). A `multi_slice` row whose slice merged while it was out
      # is the next slice, waiting: each session lands one and closes nothing, so
      # without this every slice stranded for a week, paged `#alerts`, and was
      # re-queued by hand (zimmer#321, fifteen times). That is not the judgement
      # the class comment refuses to make — the row's author made it — and it is
      # gated on the evidence that a slice actually landed (`merged_since_left`).
      #
      # The fresh row is an ordinary append, carrying the old row's fields, its
      # marker, and the merged PR, and the old row is recorded superseded. True
      # when a fresh row now carries the key. An append the ranking refuses (a
      # full band) leaves the row stranded, which pages: honest, and not silent.
      def continue_slice(item, state, probe, now, logger)
        return false unless item.multi_slice? && state == WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN

        slice = merged_since_left(item, probe)
        return false unless slice

        result = Append.call(next_slice_attributes(item, slice), added_via: WorkBacklogItem::SWEEP)
        record(item, WorkBacklogItem::LIVENESS_SUPERSEDED, now, logger)
        logger.info("[WorkBacklog::LivenessSweep] #{item.key}: slice #{slice.url || "##{slice.number}"} merged; " \
                    "#{result.created? ? "queued the next slice as item #{result.item.id}" : "the next slice was already queued"}")
        true
      rescue Append::InvalidItem => e
        logger.warn("[WorkBacklog::LivenessSweep] could not queue the next slice of #{item.key} " \
                    "(item #{item.id}): #{e.message}")
        false
      end

      # The old row's item, as its gate appended it, plus where the last slice
      # landed. The pointer goes in `prompt`, which a session spawned for an
      # issue receives after the issue URL; the row's original prompt, if a
      # human gave it one, is kept as `slice_base_prompt` so it does not grow a
      # line per slice.
      def next_slice_attributes(item, slice)
        payload = item.payload.is_a?(Hash) ? item.payload : {}
        base = payload.key?("slice_base_prompt") ? payload["slice_base_prompt"] : payload["prompt"]
        pr = slice.url || "##{slice.number}"
        pointer = "This issue is multi-slice: each session lands one slice and leaves the issue open. " \
                  "The previous slice merged in #{pr}. Pick the next slice from the issue and that PR's " \
                  "\"Noticed, not filed\" section, land it, and keep this row's continuation."

        payload.except("prompt").merge(
          item.attributes.slice(*Append::ATTRIBUTE_KEYS),
          "decided_at" => item.decided_at&.iso8601,
          "added_by" => "liveness-sweep",
          "slice_base_prompt" => base,
          "prompt" => [ base.presence, pointer ].compact.join("\n\n"),
          "previous_slice_pr" => pr,
          "continued_from_item" => item.id
        )
      end

      # `nil` when the repo could not be read at all — which the caller turns into
      # `unknown` for every row, never into a conclusion about any of them.
      def probe(repo, rows, logger)
        numbers = rows.filter_map(&:issue_number)
        return {} if numbers.empty?

        Github::IssueLinkProbe.call(repo: repo, numbers: numbers)
      rescue Github::IssueLinkProbe::ProbeError, Errno::ENOENT => e
        logger.warn("[WorkBacklog::LivenessSweep] could not probe #{repo}: #{e.class}: #{e.message}")
        yield
        nil
      end

      # How long the oldest unresolved row has been out of the queue, in seconds.
      # The one number that answers "is this getting better or worse", reported
      # every pass whether or not the pass changed anything.
      def oldest_stranded_age(now)
        oldest = WorkBacklogItem.stranded(now: now).minimum(Arel.sql("COALESCE(started_at, removed_at)"))
        oldest && (now - oldest).to_i
      end

      def empty_result(now)
        Result.new(examined: 0, outcomes: {}, oldest_stranded_age: oldest_stranded_age(now), repos_failed: [])
      end

      # WARN only when a repo could not be read — that is a fault, and production
      # exports WARN and above (#584). The standing count is not a log line: it
      # lives on the Issues page and in `get_work_backlog`, and the alert below is
      # what reaches a human without either.
      def report(result, logger)
        line = "[WorkBacklog::LivenessSweep] examined #{result.examined}; " \
               "outcomes #{result.outcomes.sort.to_h.inspect}; " \
               "oldest stranded #{result.oldest_stranded_age ? "#{result.oldest_stranded_age}s" : "none"}"
        if result.repos_failed.any?
          logger.warn("#{line}; could not read #{result.repos_failed.join(', ')}")
        else
          logger.info(line)
        end
        result
      end

      # The population cannot fix itself — nothing here puts an item back — so this
      # is the thing that stops it growing unwatched. It fires on AGE rather than
      # on count: a handful of rows awaiting triage is ordinary, and one nobody has
      # looked at for a week is the failure this sweep was written for.
      #
      # Through ErrorReporter rather than a Slack call of its own: operational
      # alerts go to the obs pipeline since AlertService was retired (#189).
      #
      # == It pages on NEW INFORMATION (#1592)
      #
      # A page costs a person's attention and starts a triage session, so it has to
      # say something the last one did not. A pass whose oldest stranded row is
      # overdue pages when at least one of these holds:
      #
      #   1. NEW ROWS. A stranded row has been out for ALERT_AFTER and no page has
      #      gone out since then. This is the rule that must not go quiet. Every row
      #      that strands gets a page within an hour of becoming overdue, whatever the
      #      population around it is doing.
      #   2. MORE ROWS. The count's step on ALERT_ROW_BANDS is above the step of the
      #      rows a page already covers, so a pile of young rows arriving at once does
      #      not wait a week to be mentioned. A row that left resolved takes its mark
      #      with it, so a band re-crossed after triage pages again — but only when a
      #      row arrives, so it is bounded by arrivals, never by passes.
      #   3. OLDER. The oldest row's age has climbed a rung of the doubling ladder
      #      (ALERT_LADDER_BASE) since the last page. This is the reminder for a
      #      population nobody acts on, and it slows as the population ages.
      #
      # Anything else is silent. Before #1592, a five-row population that only a
      # human decision could move re-paged every time its oldest row aged into
      # another week, and every triage could only restate the same remedy.
      #
      # The memory is on the rows: `stranded_paged_at`, stamped on every stranded
      # row a page goes out for. Every pass clears it from any row that has left
      # the unresolved set — closed, PR in flight, superseded, re-queued — so a row
      # that strands AGAIN is new again. A void clears it too
      # (WorkBacklogItem#record_liveness!): the evidence a held decision stood on
      # changed, and the row needs looking at afresh. A hold does NOT clear it. A
      # held row is parked on a person, not resolved, and its lapse is not news
      # about the work (below).
      #
      # Nothing here depends on a cache. A throttle kept in a store that can stop
      # remembering would have to stay silent when it does, because an hourly page
      # that nothing throttles would flood `#alerts`. The mark lives in the same
      # database the pass has just read and written every row in, so a pass that
      # cannot write it has already failed, at ERROR, in the job.
      #
      # A LAPSED HOLD does not page by itself. A hold lapses only when
      # WorkBacklog::DecisionDigest has stopped renewing it, and a digest that
      # reaches no device is already an ERROR that pages through
      # `zimmer_backend_log_errors`. So a lapse pages only through rule 1, on a row
      # no page has covered, such as one held before it was ever overdue. Either
      # way the spent hold is cleared on the pass that sees it, so WorkBacklog::Hold
      # can accept a fresh one.
      #
      # == Reaching a human MORE THAN ONCE (#1175)
      #
      # The first version of this reported one constant fingerprint through
      # ErrorReporter and did nothing else, so it could page exactly once in its
      # life. GlitchTip's "new issue → Slack" alert notifies an issue AT MOST ONCE,
      # EVER — `process_event_alerts` excludes issues that already produced a
      # Notification for that alert — which is the property that keeps a crash loop
      # from flooding `#alerts`, and which turned this hourly detector into a
      # one-shot. GlitchTip issue 95 read `count = 1`, `first_seen == last_seen`
      # while the population it bounds sat at 21 rows. That is the invisible growth
      # #1127 was written to end, so it must not be how the detector itself fails.
      #
      # So EVERY PAGE IS ITS OWN GLITCHTIP ISSUE. The fingerprint carries the
      # severity band, so a GlitchTip reader sees how bad it is, and then the time
      # of the pass that paged, so a second page at the same band — a new row in an
      # unchanged population, or the next rung of the ladder — is a new issue with
      # its own one-time notification rather than an occurrence of an issue whose
      # notification is spent. GlitchTip's at-most-once rule is then exactly the
      # right number: the sweep decides when to page, and each page notifies once.
      #
      # The page is NOT also an ERROR log record. A non-staging ERROR trips the
      # `zimmer_backend_log_errors` Grafana rule, so one report would page `#alerts`
      # twice — the second time as a generic "ERROR log record" naming neither the
      # band nor the problem — and start a second triage router for it. A sweep
      # that crashes still reaches that rule, through the job's own ERROR record.
      #
      # == What a pass that could not read a repo may say
      #
      # Its census is unreliable: every row it could not probe is recorded
      # `unknown`, which counts as stranded, so rows long since closed come back at
      # their original age with no mark (it was cleared when they closed), and
      # all three rules would fire on them. So such a pass pages only a LAPSED hold
      # on a row no page has covered. The lapse is a fact about the row's own
      # clock rather than the census, and for a repo that stays unreadable it is
      # the only thing that can page. It marks only the rows it paged for. The
      # unreadable repo is already named at WARN by `report`.
      def alert_if_overdue(result, now)
        forget_resolved_marks(now)

        rows = stranded_rows(now)
        lapsed = rows.select(&:lapsed).map(&:id)
        paging = result.repos_failed.any? ? lapse_news(rows, now) : news(rows, now)

        if paging
          # One transaction, so a pass that raises while composing the page leaves
          # no row marked as paged for a page that never went out.
          WorkBacklogItem.transaction do
            WorkBacklogItem.where(id: paging[:mark]).update_all(stranded_paged_at: now)
            page_stranded_rows(rows, paging, lapsed.size, now)
          end
        end

        announce_lapsed_holds(lapsed, now)
      end

      def stranded_rows(now)
        WorkBacklogItem.stranded(now: now)
                       .pluck(:id, :key, Arel.sql("COALESCE(started_at, removed_at)"), :stranded_paged_at, :held_at)
                       .filter_map do |id, key, since, paged_at, held_at|
          next if since.nil? # a hand-edited row with neither time has no age to page on

          StrandedRow.new(id: id, key: key, since: since, paged_at: paged_at, lapsed: held_at.present?)
        end
      end

      # A row that has left the unresolved set is no longer covered by anything,
      # so if it strands again it is new again. Every pass, the empty one and an
      # unreadable one included: a row can only leave on a verdict this pass or an
      # earlier one actually read, or by its status changing.
      #
      # With no GRACE. The grace keeps a row out until its session has been over
      # for six hours, and it is measured from the session's last write, so
      # archiving a long-dead session would otherwise take a paged row out for six
      # hours, clear its mark, and re-page it as new. Only a session that is live
      # again takes the row out here.
      def forget_resolved_marks(now)
        WorkBacklogItem.where.not(stranded_paged_at: nil)
                       .where.not(id: WorkBacklogItem.unresolved(grace: 0.seconds, now: now).select(:id))
                       .update_all(stranded_paged_at: nil)
      end

      # What a readable pass has to say, or nil. See `alert_if_overdue`.
      def news(rows, now)
        oldest = rows.min_by(&:since)
        return nil if oldest.nil? || !oldest.overdue?(now)

        age = (now - oldest.since).to_i
        fresh = rows.select { |row| row.overdue?(now) && !row.covered? }
        last_paged = rows.filter_map(&:paged_at).max
        reasons = []
        reasons << "new_rows" if fresh.any?
        reasons << "more_rows" if last_paged && row_band(rows.size) > row_band(rows.count(&:paged_at))
        reasons << "older" if last_paged && ladder_rung(age) > ladder_rung(last_paged - oldest.since)
        return nil if reasons.empty?

        { reasons: reasons, age: age, fresh: fresh, mark: rows.map(&:id) }
      end

      # What a pass that could not read a repo may say: a lapsed hold on a row no
      # page has covered, and nothing else.
      def lapse_news(rows, now)
        fresh = rows.select { |row| row.lapsed && row.overdue?(now) && !row.covered? }
        return nil if fresh.empty?

        { reasons: [ "new_rows" ], age: (now - rows.min_by(&:since).since).to_i, fresh: fresh, mark: fresh.map(&:id) }
      end

      # The page has been decided, so the spent holds are cleared — which is what
      # lets WorkBacklog::Hold accept a fresh one. Every pass, not only one that
      # pages: a lapse on a row already paged for pages nothing, and still has to
      # be cleared. Conditional on the hold still being the lapsed one, so a hold
      # recorded since the read above is left alone.
      def announce_lapsed_holds(ids, now)
        return if ids.empty?

        WorkBacklogItem.where(id: ids).where(held_until: ..now)
                       .update_all(WorkBacklogItem::CLEARED_HOLD.merge(updated_at: now))
      end

      # The band a page names: the week its oldest row's age has reached, and the
      # step of the size ladder its count has reached. It is what the fingerprint
      # and the title say; whether to page is `news`.
      def severity_band(age, rows)
        { weeks: age / ALERT_AFTER.to_i, rows: row_band(rows) }
      end

      def row_band(rows) = ALERT_ROW_BANDS.select { |n| rows >= n }.max.to_i

      # The ladder rung an age is on: -1 under ALERT_AFTER, then 0 for 1 week, 1
      # for 2–3, 2 for 4–7, 3 for 8–15, and so on, one rung per doubling.
      def ladder_rung(age)
        weeks = (age / ALERT_AFTER).floor
        return -1 if weeks < 1

        rung = 0
        while weeks >= ALERT_LADDER_BASE
          weeks /= ALERT_LADDER_BASE
          rung += 1
        end
        rung
      end

      def page_stranded_rows(rows, paging, lapsed, now)
        age = paging[:age]
        band = severity_band(age, rows.size)
        awaiting_decision = WorkBacklogItem.awaiting_decision(now: now).count
        days = (age / 86_400.0).round(1)
        named = paging[:fresh].first(NAMED_ROWS_MAX).map(&:key)
        unnamed = paging[:fresh].size - named.size
        news = "paged for: #{paging[:reasons].join(', ')}"
        news += "; newly stranded: #{named.join(', ')}" if named.any?
        news += " and #{unnamed} more" if unnamed.positive?
        held = awaiting_decision.positive? ? " (#{awaiting_decision} more held for a human decision, not counted)" : ""
        if lapsed.positive?
          held += "; #{lapsed} hold(s) for a human decision lapsed with the decision still owed, so the " \
                  "decision digest did not renew them"
        end

        # WARN, not ERROR: the GlitchTip event below is the page, and an ERROR here
        # would trip the `zimmer_backend_log_errors` Grafana rule and page `#alerts`
        # a second time for the same report. WARN still exports, so the line stays
        # queryable beside the sweep's other records.
        #
        # Rails.logger rather than the sweep's injected logger, so that this line is
        # only ever a log record: the job hands the sweep a StructuredLogger, whose
        # #error reports to GlitchTip itself, and nothing here should reach GlitchTip
        # except the banded event below.
        Rails.logger.warn(
          "[WorkBacklog::LivenessSweep] #{rows.size} work backlog row(s) stranded, oldest #{days} days " \
          "(band: #{band[:weeks]}w/#{band[:rows]}+ rows)#{held}; #{news} — nothing re-queues these automatically. " \
          "Triage them on the Issues page under Stranded, or with get_work_backlog status: \"stranded\"; " \
          "one whose remainder is a human's call is held with hold_work_backlog_item_for_decision."
        )

        # Level :warning: this is a triage queue, not a fault. The new issue its
        # fingerprint opens is what notifies `#alerts`, not the level.
        ErrorReporter.report_message(
          "Work backlog rows have been stranded for over #{band[:weeks]} #{"week".pluralize(band[:weeks])}",
          context: {
            oldest_stranded_days: days,
            stranded_rows: rows.size,
            paged_for: paging[:reasons],
            newly_stranded_rows: paging[:fresh].size,
            newly_stranded: named,
            awaiting_decision_rows: awaiting_decision,
            lapsed_holds: lapsed,
            severity_band: band,
            source: "WorkBacklog::LivenessSweep",
            what_to_do: "Nothing re-queues these automatically — telling a finished issue from one " \
                        "with a deliberate remainder needs a judgement per issue. Triage them on the " \
                        "Issues page under Stranded, or with get_work_backlog status: \"stranded\", " \
                        "put the ones with work left back with append_work_backlog_item (with continuation: " \
                        "multi_slice when each session lands one slice of an issue that stays open), and hold the " \
                        "ones whose remainder is a human's call with hold_work_backlog_item_for_decision. " \
                        "A lapsed hold means WorkBacklogDecisionDigestJob did not reach the owner or could " \
                        "not re-read the row's evidence: find out why before holding it again. This pages " \
                        "only on news — a row no page has covered, a count through a band, or the oldest " \
                        "row doubling in age — so a population left as it is pages next at the next doubling."
          },
          level: :warning,
          fingerprint: [ ALERT_FINGERPRINT, "weeks-#{band[:weeks]}", "rows-#{band[:rows]}",
                         "paged-#{now.utc.iso8601}" ]
        )
      end
    end
  end
end
