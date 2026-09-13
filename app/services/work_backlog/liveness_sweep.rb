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
    #
    # It doubles as the WIDTH of a severity band: a population nobody triages ages
    # into a new band every week, and a new band pages again. See
    # `alert_if_overdue`.
    ALERT_AFTER = 7.days

    # The population sizes that count as a step change. A count climbing through
    # one of these pages again without waiting for the week to roll over; one
    # drifting between two of them does not. Coarse on purpose — the question a
    # second page has to answer is "is this materially worse than when I was last
    # told", and 21 rows against 23 is not.
    ALERT_ROW_BANDS = [ 1, 10, 25, 50, 100, 250, 500, 1000 ].freeze

    # The fingerprint every occurrence of this alert shares, so the obs pipeline
    # groups them into one issue rather than one per pass. The severity band is
    # appended to it, which is what keeps a WORSE population from being folded
    # into the issue a milder one already used up — see `alert_if_overdue`.
    ALERT_FINGERPRINT = "work-backlog-stranded-rows"

    # Where the band the last page was sent for is remembered, so a steady
    # population is silent between bands. Redis everywhere but `test`, which runs
    # a `:null_store`; a store that cannot remember is handled in
    # `cache_can_remember?` rather than assumed away.
    ALERT_BAND_CACHE_KEY = "work_backlog_liveness_sweep:alerted_band"

    # How long a page suppresses the band it was sent for — and so, for a
    # population that is not getting worse, how often the reminder repeats. It is
    # ALERT_AFTER because that is already the width of a week band: a population
    # standing still pages when its oldest row ages into the next week, and this
    # expiry makes a population whose band has DROPPED — the shape triage leaves,
    # taking the oldest rows off first — page again on the same cadence instead of
    # waiting to beat a high-water mark it may never reach.
    ALERT_BAND_TTL = ALERT_AFTER

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

        return WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN if probe.merged_references.any?

        WorkBacklogItem::LIVENESS_NO_PR
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
      # Asked in `repo`, such a row got a PR or a 404 back and stayed `unknown`
      # for good, or took the state of an unrelated issue that shares its number
      # (#1188). `repo` is the fallback only for a row whose `issue_url` names no
      # repository, and such a row has no issue number to ask about anyway.
      def examine(rows, now, logger)
        outcomes = Hash.new(0)
        failed = []

        rows.group_by { |item| item.issue_repo || item.repo }.each do |repo, repo_rows|
          probes = probe(repo, repo_rows, logger) { failed << repo }
          repo_rows.each do |item|
            state = classify(item, probes && probes[item.issue_number], now)
            outcomes[state] += 1
            record(item, state, now, logger)
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
      # Two surfaces now, each doing a different half:
      #
      #   * THE PAGE IS AN ERROR LOG RECORD. A non-staging Zimmer ERROR record
      #     trips the `zimmer_backend_log_errors` Grafana rule, and that rule fires
      #     again every time it goes from normal to alerting, where a GlitchTip
      #     issue notifies once and is then spent for good. It is a NOTIFICATION,
      #     not a standing alert: one record per page means the rule resolves by
      #     itself minutes later, and the standing count lives on the Issues page
      #     and in `get_work_backlog` rather than in Grafana.
      #     SystemHealthMonitorJob pages the same way, for the same reason, and its
      #     comment says so in as many words.
      #   * THE GLITCHTIP EVENT CARRIES THE BAND in its fingerprint, so a worse
      #     population is a genuinely new issue with its own one-time notification
      #     while a steady one keeps the issue it already has.
      #
      # What bounds the noise is that a page costs a real step change — a week of
      # further ageing, or a climb through ALERT_ROW_BANDS — and that the band it
      # was sent for is then remembered for ALERT_BAND_TTL. So the ceiling is one
      # page per step change plus one reminder a week, never the hourly flood that
      # "report every pass" would be, and never the permanent silence this
      # replaces.
      #
      # The remembered band is a HIGH-WATER MARK that expires rather than one that
      # tracks the population down, and that asymmetry is deliberate. A band that
      # followed every improvement would page on every upward re-crossing of a
      # boundary, so a count flickering 49 ↔ 50 would page hourly; a high-water
      # mark that never expired would instead go quiet for weeks after triage took
      # the oldest rows off, because the remainder cannot beat a mark it has
      # already dropped below. Expiry gives the second without the first.
      def alert_if_overdue(result, now)
        # A pass that could not read a repo has an unreliable census: every row it
        # could not probe is recorded `unknown`, which counts as stranded, so rows
        # long since closed re-enter the population with their original age and
        # both halves of the band jump. Defer the reading rather than page on it or
        # let it poison the high-water mark — the unreadable repo is already named
        # at WARN by `report`, and the next pass says something true.
        return if result.repos_failed.any?

        age = result.oldest_stranded_age
        if age.nil? || age < ALERT_AFTER
          # The condition is over. Forgetting the band is what makes the NEXT
          # population page from band one instead of being weighed against a worse
          # one that no longer exists.
          Rails.cache.delete(ALERT_BAND_CACHE_KEY)
          return
        end

        return unless cache_can_remember?

        rows = WorkBacklogItem.stranded(now: now).count
        band = severity_band(age, rows)
        return unless worse_band?(band, Rails.cache.read(ALERT_BAND_CACHE_KEY))

        Rails.cache.write(ALERT_BAND_CACHE_KEY, band, expires_in: ALERT_BAND_TTL)
        page_stranded_rows(band, age, rows)
      end

      # The band a population is in: the week its oldest row's age has reached, and
      # the step of the size ladder its count has reached. Coarse in both
      # dimensions so that only a real change moves it.
      def severity_band(age, rows)
        { weeks: age / ALERT_AFTER.to_i, rows: ALERT_ROW_BANDS.select { |n| rows >= n }.max.to_i }
      end

      # Worse in EITHER dimension — a population can get older without growing, and
      # grow without getting older, and both are news. No memory at all is worse
      # than any band: that is a population's first page.
      def worse_band?(band, previous)
        return true if previous.nil?

        band.any? { |dimension, value| value > previous[dimension].to_i }
      end

      # Can the store this throttle depends on remember anything? Written to a
      # throwaway key and read straight back, so that a store which cannot — the
      # `:null_store` the test env runs, or a Redis that has stopped answering,
      # which `error_handler` turns into a silent nil — is found out without the
      # probe itself being able to strand the real band.
      #
      # A store that cannot remember cannot be throttled against, and that is the
      # one case this stays silent on purpose: an hourly page nothing can throttle
      # would flood `#alerts`, the channel every real page on this deployment
      # travels, and a cache that has stopped answering is loudly alerted on in its
      # own right rather than needing this to notice it.
      def cache_can_remember?
        token = SecureRandom.hex(4)
        Rails.cache.write("#{ALERT_BAND_CACHE_KEY}:probe", token, expires_in: 1.minute)
        Rails.cache.read("#{ALERT_BAND_CACHE_KEY}:probe") == token
      end

      def page_stranded_rows(band, age, rows)
        days = (age / 86_400.0).round(1)

        # `.error`, because THIS LINE is the page. It is what trips the
        # `zimmer_backend_log_errors` Grafana rule — the only surface here that can
        # notify a second time — so demoting it to `.warn` takes this alert back to
        # reaching a human once and never again.
        #
        # Rails.logger rather than the sweep's injected logger: the job hands the
        # sweep a StructuredLogger, whose #error reports to GlitchTip itself, and
        # that would file a second issue keyed on this line's text beside the
        # banded one below.
        Rails.logger.error(
          "[WorkBacklog::LivenessSweep] #{rows} work backlog row(s) stranded, oldest #{days} days " \
          "(band: #{band[:weeks]}w/#{band[:rows]}+ rows) — nothing re-queues these automatically. " \
          "Triage them on the Issues page under Stranded, or with get_work_backlog status: \"stranded\"."
        )

        # Level stays :warning: this is a triage queue, not a fault, and the
        # matching Grafana rule is a warning too. The ERROR above is the paging
        # MECHANISM, not a claim about severity.
        ErrorReporter.report_message(
          "Work backlog rows have been stranded for over #{band[:weeks]} #{"week".pluralize(band[:weeks])}",
          context: {
            oldest_stranded_days: days,
            stranded_rows: rows,
            severity_band: band,
            source: "WorkBacklog::LivenessSweep",
            what_to_do: "Nothing re-queues these automatically — telling a finished issue from one " \
                        "with a deliberate remainder needs a judgement per issue. Triage them on the " \
                        "Issues page under Stranded, or with get_work_backlog status: \"stranded\", " \
                        "and put the ones with work left back with append_work_backlog_item."
          },
          level: :warning,
          fingerprint: [ ALERT_FINGERPRINT, "weeks-#{band[:weeks]}", "rows-#{band[:rows]}" ]
        )
      end
    end
  end
end
