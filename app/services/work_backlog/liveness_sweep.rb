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

    # How old the oldest unresolved row may get before a human is told. The point
    # of the alert is that this population used to have no upper bound at all —
    # the worst row observed had sat for 37 days.
    ALERT_AFTER = 7.days

    # The fingerprint every occurrence of this alert shares, so the obs pipeline
    # groups them into one issue rather than one per pass.
    ALERT_FINGERPRINT = "work-backlog-stranded-rows"

    # What one pass found. `repos_failed` is separate from the outcome counts
    # because a repo nobody could read is a fault, where an `unknown` row might
    # just be an issue that was deleted.
    Result = Data.define(:examined, :outcomes, :oldest_stranded_age, :repos_failed) do
      def count(state) = outcomes.fetch(state, 0)
    end

    class << self
      # @param now [Time]
      # @param logger [StructuredLogger, Logger]
      # @return [Result]
      def sweep!(now: Time.current, logger: Rails.logger)
        candidates = candidates(now)
        return report(empty_result(now), logger) if candidates.empty?

        outcomes = Hash.new(0)
        failed = []

        candidates.group_by(&:repo).each do |repo, rows|
          probes = probe(repo, rows, logger) { failed << repo }
          rows.each do |item|
            state = classify(item, probes && probes[item.issue_number], now)
            outcomes[state] += 1
            record(item, state, now, logger)
          end
        end

        result = Result.new(examined: candidates.size, outcomes: outcomes,
                            oldest_stranded_age: oldest_stranded_age(now), repos_failed: failed)
        alert_if_overdue(result)
        report(result, logger)
      end

      # The rows worth a look, least-recently-checked first so a large population
      # round-robins rather than the sweep re-reading the head of it every pass.
      # Rows nothing has ever said anything about sort first.
      def candidates(now)
        WorkBacklogItem.liveness_candidates(grace: GRACE, now: now)
                       .order(Arel.sql("liveness_checked_at ASC NULLS FIRST"), id: :asc)
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

        return WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN if probe.merged_references.any?

        WorkBacklogItem::LIVENESS_NO_PR
      end

      private

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
      def alert_if_overdue(result)
        age = result.oldest_stranded_age
        return if age.nil? || age < ALERT_AFTER

        ErrorReporter.report_message(
          "Work backlog rows have been stranded for over #{ALERT_AFTER.inspect}",
          context: {
            oldest_stranded_days: (age / 86_400.0).round(1),
            stranded_rows: WorkBacklogItem.stranded.count,
            source: "WorkBacklog::LivenessSweep",
            what_to_do: "Nothing re-queues these automatically — telling a finished issue from one " \
                        "with a deliberate remainder needs a judgement per issue. Triage them on the " \
                        "Issues page under Stranded, or with get_work_backlog status: \"stranded\", " \
                        "and put the ones with work left back with append_work_backlog_item.",
            fingerprint: ALERT_FINGERPRINT
          },
          level: :warning
        )
      end
    end
  end
end
