# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The liveness re-check: what it concludes about a row that left the queue, and —
# the load-bearing half — that it concludes it without moving anything.
class WorkBacklog::LivenessSweepTest < ActiveSupport::TestCase
  include WorkBacklogHelpers
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @dead_session = sessions(:archived)
    @dead_session.update_columns(archived_at: 3.days.ago)
  end

  # --- the classification ----------------------------------------------------

  test "a closed issue resolves the row, and it stops being a candidate" do
    item = started_row

    result = sweep(probes: { 1 => probe(state: "CLOSED") })

    assert_equal WorkBacklogItem::LIVENESS_ISSUE_CLOSED, item.reload.liveness_state
    assert_equal 1, result.count(WorkBacklogItem::LIVENESS_ISSUE_CLOSED)
    assert_empty WorkBacklogItem.stranded
  end

  test "an open PR that has moved recently means someone is on it" do
    item = started_row

    sweep(probes: { 1 => probe(references: [ reference(state: "OPEN", updated_at: 1.day.ago) ]) })

    assert_equal WorkBacklogItem::LIVENESS_PR_OPEN, item.reload.liveness_state
    assert_empty WorkBacklogItem.stranded, "a moving PR is not stranded"
  end

  # zimmer#522's shape: removed because the issue had an open PR, and that PR has
  # not been touched since. Anything that only asks "is a PR open" calls this fine.
  test "an open PR nobody has touched for the stale window is stalled, not in flight" do
    item = removed_row(reason: "issue_has_open_pr")

    sweep(probes: { 1 => probe(references: [ reference(state: "OPEN", updated_at: 21.days.ago) ]) })

    assert_equal WorkBacklogItem::LIVENESS_PR_STALLED, item.reload.liveness_state
    assert_includes WorkBacklogItem.stranded.pluck(:id), item.id
  end

  # The ambiguous one, and the reason nothing here re-queues: this is what both a
  # finished issue whose PR forgot the closing keyword and a deliberate partial
  # with a real remainder look like.
  test "a merged PR against a still-open issue is recorded as ambiguous, not acted on" do
    item = started_row(precedence: 6990)

    sweep(probes: { 1 => probe(references: [ reference(state: "MERGED", updated_at: 5.days.ago) ]) })

    item.reload
    assert_equal WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN, item.liveness_state
    assert item.started?, "the sweep must not re-queue an ambiguous row"
    assert_equal 6990, item.precedence
    assert_includes WorkBacklogItem.stranded.pluck(:id), item.id
  end

  test "no pull request has ever referenced the issue" do
    item = started_row

    sweep(probes: { 1 => probe(references: []) })

    assert_equal WorkBacklogItem::LIVENESS_NO_PR, item.reload.liveness_state
  end

  test "a closed-unmerged PR is not evidence of anything, so the row reads as no_pr" do
    item = started_row

    sweep(probes: { 1 => probe(references: [ reference(state: "CLOSED", updated_at: 2.days.ago) ]) })

    assert_equal WorkBacklogItem::LIVENESS_NO_PR, item.reload.liveness_state
  end

  # --- it moves nothing, ever ------------------------------------------------

  test "a whole pass changes no row's status, precedence or session" do
    started = started_row(precedence: 6990)
    removed = removed_row(reason: "session_already_working", key: "zimmer#2", number: 2)
    before = WorkBacklogItem.order(:id).pluck(:id, :status, :precedence, :started_session_id, :removal_reason)

    sweep(probes: { 1 => probe(references: []), 2 => probe(references: []) })

    after = WorkBacklogItem.order(:id).pluck(:id, :status, :precedence, :started_session_id, :removal_reason)
    assert_equal before, after
    assert_equal WorkBacklogItem::LIVENESS_NO_PR, started.reload.liveness_state
    assert_equal WorkBacklogItem::LIVENESS_NO_PR, removed.reload.liveness_state
  end

  # --- what it will not look at ---------------------------------------------

  test "a row whose session is still alive is not a candidate" do
    item = started_row
    item.update_columns(started_session_id: sessions(:running).id)

    assert_equal 0, sweep(probes: {}).examined
    assert_nil item.reload.liveness_state
  end

  test "a queued row is not a candidate however old it is" do
    item = backlog_item(key: "zimmer#1", issue_url: issue_url(1))

    assert_equal 0, sweep(probes: {}).examined
    assert_nil item.reload.liveness_state
  end

  test "a judgement removal is not a candidate — it has no expiry to re-check" do
    item = removed_row(reason: "trust_failed")

    assert_equal 0, sweep(probes: {}).examined
    assert_nil item.reload.liveness_state
  end

  test "a row removed inside the grace is not yet a candidate" do
    item = removed_row(reason: "session_already_working", removed_at: 1.minute.ago)

    assert_equal 0, sweep(probes: {}).examined
    assert_nil item.reload.liveness_state,
               "a session that was already working it a minute ago has not had time to produce a PR"
  end

  # The triage route leaves a newer row behind rather than moving this one, so
  # without this the re-queued item would age in the stranded count forever and
  # the alert could never be cleared by the action it recommends.
  test "a row a newer row has taken over resolves without asking GitHub" do
    item = started_row
    backlog_item(key: item.key, issue_url: issue_url(1))

    result = sweep(probes: {})

    assert_equal WorkBacklogItem::LIVENESS_SUPERSEDED, item.reload.liveness_state
    assert_empty WorkBacklogItem.stranded.where(id: item.id)
    assert_equal 1, result.count(WorkBacklogItem::LIVENESS_SUPERSEDED)
  end

  # One unwritable row must not cost every other. It would otherwise cost them
  # permanently: a row that raises keeps `liveness_checked_at` NULL, so it sorts
  # first on the next pass too, and the sweep never gets past it.
  test "a row that cannot be written does not stop the pass" do
    broken = started_row(key: "zimmer#1", number: 1)
    broken.update_columns(estimated_cost: "enormous")
    healthy = started_row(key: "zimmer#2", number: 2)
    log = StringIO.new

    result = sweep(probes: { 1 => probe(references: []), 2 => probe(references: []) },
                   logger: Logger.new(log))

    assert_equal 2, result.examined
    assert_equal WorkBacklogItem::LIVENESS_NO_PR, healthy.reload.liveness_state
    assert_nil broken.reload.liveness_state
    assert_match(/could not record/, log.string)
  end

  # --- a read that failed is not a conclusion -------------------------------

  test "a repo that could not be probed leaves its rows unknown and is named" do
    item = started_row

    result = sweep(probe_error: "gh api graphql failed")

    assert_equal WorkBacklogItem::LIVENESS_UNKNOWN, item.reload.liveness_state
    assert_equal [ "tadasant/zimmer" ], result.repos_failed
    assert_includes WorkBacklogItem.stranded.pluck(:id), item.id
  end

  test "an issue the probe did not come back with is unknown, not closed" do
    item = started_row

    sweep(probes: {})

    assert_equal WorkBacklogItem::LIVENESS_UNKNOWN, item.reload.liveness_state
  end

  # --- ordering and bounds ---------------------------------------------------

  test "examines the least-recently-checked rows first" do
    recent = started_row(key: "zimmer#1", number: 1, liveness_checked_at: 1.hour.ago,
                         liveness_state: WorkBacklogItem::LIVENESS_UNKNOWN)
    stale = started_row(key: "zimmer#2", number: 2, liveness_checked_at: 10.days.ago,
                        liveness_state: WorkBacklogItem::LIVENESS_UNKNOWN)
    never = started_row(key: "zimmer#3", number: 3)

    assert_equal [ never.id, stale.id, recent.id ],
                 WorkBacklog::LivenessSweep.candidates(Time.current).map(&:id)
  end

  test "examines at most MAX_EXAMINED_PER_SWEEP rows in one pass" do
    (WorkBacklog::LivenessSweep::MAX_EXAMINED_PER_SWEEP + 2).times do |n|
      started_row(key: "zimmer##{n}", number: n)
    end

    assert_equal WorkBacklog::LivenessSweep::MAX_EXAMINED_PER_SWEEP,
                 WorkBacklog::LivenessSweep.candidates(Time.current).size
  end

  # --- what it says ----------------------------------------------------------

  test "alerts when the oldest stranded row is past the threshold, on both surfaces" do
    started_row(started_at: (WorkBacklog::LivenessSweep::ALERT_AFTER + 2.days).ago)

    with_alerts do |alerts|
      sweep(probes: { 1 => probe(references: []) })

      # The ERROR log record is the page: it is what trips the
      # `zimmer_backend_log_errors` Grafana rule, the surface that re-fires and
      # then resolves. Without it this alert reaches a human once and never again.
      assert_equal 1, alerts.pages.size
      assert_match(/9\.0 days/, alerts.pages.first)

      assert_equal 1, alerts.events.size
      assert_match(/stranded for over 1 week\z/, alerts.events.first[:message])
      assert_equal [ WorkBacklog::LivenessSweep::ALERT_FINGERPRINT, "weeks-1", "rows-1" ],
                   alerts.events.first[:fingerprint]
    end
  end

  test "does not alert while the oldest stranded row is young" do
    started_row(started_at: 1.day.ago)

    with_alerts do |alerts|
      sweep(probes: { 1 => probe(references: []) })

      assert_empty alerts.pages
      assert_empty alerts.events
    end
  end

  # The flood-protection half, and the property not to regress: the sweep runs
  # HOURLY, and a population that has not changed must not page on every pass.
  test "a population that has not changed does not page again on later passes" do
    started_row(started_at: 9.days.ago)

    with_alerts do |alerts|
      3.times { sweep(probes: { 1 => probe(references: []) }) }

      assert_equal 1, alerts.pages.size, "a steady population pages once, not once an hour"
      assert_equal 1, alerts.events.size
    end
  end

  # The defect (#1175): past the first notification the old alert was silent for
  # ever, because one constant fingerprint plus GlitchTip's at-most-once
  # ProjectAlert can reach a human exactly once.
  test "a population that ages into the next week pages again" do
    started_row(started_at: 9.days.ago)

    with_alerts do |alerts|
      sweep(probes: { 1 => probe(references: []) })
      travel 7.days do
        sweep(probes: { 1 => probe(references: []) })
      end

      assert_equal 2, alerts.pages.size
      assert_equal [ "weeks-1", "weeks-2" ], alerts.events.map { |event| event[:fingerprint][1] }
      assert_match(/stranded for over 2 weeks\z/, alerts.events.last[:message])
    end
  end

  test "a population that grows through a size band pages again without waiting for the week" do
    started_row(key: "zimmer#1", number: 1, started_at: 9.days.ago)

    with_alerts do |alerts|
      sweep(probes: { 1 => probe(references: []) })

      (2..10).each { |n| started_row(key: "zimmer##{n}", number: n, started_at: 8.days.ago) }
      sweep(probes: { 1 => probe(references: []) })

      assert_equal 2, alerts.pages.size
      assert_equal [ "rows-1", "rows-10" ], alerts.events.map { |event| event[:fingerprint][2] }
      assert_equal 10, alerts.events.last[:context][:stranded_rows]
    end
  end

  # The band is a high-water mark, so an improvement is silent — otherwise a count
  # flickering across a boundary would page on every upward re-crossing.
  test "a band that drops and climbs back does not page twice" do
    rows = (1..10).map { |n| started_row(key: "zimmer##{n}", number: n, started_at: 9.days.ago) }

    with_alerts do |alerts|
      sweep
      assert_equal [ "rows-10" ], alerts.events.map { |event| event[:fingerprint][2] }

      rows.last.destroy!
      sweep
      assert_equal 1, alerts.pages.size, "an improvement is not a page"

      started_row(key: "zimmer#11", number: 11, started_at: 9.days.ago)
      sweep
      assert_equal 1, alerts.pages.size, "and re-crossing the same boundary is not a second page"
    end
  end

  # ...but a high-water mark that never expired would go quiet for weeks after
  # triage took the oldest rows off, because the remainder cannot beat a mark it
  # has already dropped below. The mark expires after ALERT_BAND_TTL, so a
  # population that is still overdue is told about again on that cadence.
  test "the remembered band expires, so a population below it is reported again" do
    oldest = started_row(key: "zimmer#1", number: 1, started_at: 22.days.ago)
    started_row(key: "zimmer#2", number: 2, started_at: 8.days.ago)

    with_alerts do |alerts|
      sweep
      assert_equal [ "weeks-3" ], alerts.events.map { |event| event[:fingerprint][1] }

      oldest.destroy!
      sweep
      assert_equal 1, alerts.pages.size, "the remainder is in a lower band, so it says nothing"

      travel(WorkBacklog::LivenessSweep::ALERT_BAND_TTL - 1.day) { sweep }
      assert_equal 1, alerts.pages.size, "still inside the window the last page bought"

      travel(WorkBacklog::LivenessSweep::ALERT_BAND_TTL + 1.hour) { sweep }
      assert_equal 2, alerts.pages.size
      assert_equal "weeks-2", alerts.events.last[:fingerprint][1],
                   "and it is reported at the band it is actually in"
    end
  end

  # Every row a failed probe touched is recorded `unknown`, which counts as
  # stranded — so a repo nobody could read puts long-closed rows back into the
  # population at their original age. Paging on that census would be a false page,
  # and remembering it would suppress the true one for a week.
  test "a pass that could not read a repo says nothing" do
    started_row(started_at: 9.days.ago)

    with_alerts do |alerts|
      sweep(probe_error: "gh api graphql failed")

      assert_empty alerts.pages
      assert_empty alerts.events
    end
  end

  # The resolve half. Nothing closes a GlitchTip issue, but the Grafana rule
  # resolves once the ERROR records stop — and the band has to be forgotten with
  # it, or the NEXT population is weighed against one that no longer exists.
  test "a cleared population forgets its band, so the next one pages from its first week" do
    item = started_row(started_at: 9.days.ago)

    with_alerts do |alerts|
      sweep
      assert_equal 1, alerts.pages.size

      item.destroy!
      sweep
      assert_equal 1, alerts.pages.size, "an empty population says nothing"

      started_row(key: "zimmer#2", number: 2, started_at: 9.days.ago)
      sweep

      assert_equal 2, alerts.pages.size
      assert_equal "weeks-1", alerts.events.last[:fingerprint][1]
    end
  end

  # A store that cannot remember cannot be throttled against, and an hourly page
  # nothing throttles would flood `#alerts` — the channel every real page travels.
  # The test env's :null_store is that store, so this needs no stubbing.
  test "a cache that cannot remember stays silent rather than paging every pass" do
    started_row(started_at: 9.days.ago)

    # Everything `with_alerts` captures, but against the test env's real
    # :null_store rather than a memory store.
    with_alerts(cache: ActiveSupport::Cache::NullStore.new) do |alerts|
      2.times { sweep(probes: { 1 => probe(references: []) }) }

      assert_empty alerts.pages, "the ERROR record IS the page, so it is the one that must not repeat"
      assert_empty alerts.events
    end
  end

  test "reports the age of the oldest stranded row, and a resolved row does not count" do
    started_row(key: "zimmer#1", number: 1, started_at: 9.days.ago)

    result = sweep(probes: { 1 => probe(references: [ reference(state: "MERGED", updated_at: 5.days.ago) ]) })
    assert_in_delta 9.days.to_i, result.oldest_stranded_age, 60

    result = sweep(probes: { 1 => probe(state: "CLOSED") })
    assert_nil result.oldest_stranded_age
  end

  test "a repo that could not be read is logged at WARN so production sees it" do
    started_row
    log = StringIO.new

    sweep(probe_error: "boom", logger: Logger.new(log))

    assert_match(/WARN .*could not read tadasant\/zimmer/, log.string)
  end

  private

  def issue_url(number) = "https://github.com/tadasant/zimmer/issues/#{number}"

  def started_row(key: "zimmer#1", number: 1, started_at: 4.days.ago, **overrides)
    backlog_item(**{ key: key, issue_url: issue_url(number), status: WorkBacklogItem::STARTED,
                     started_session_id: @dead_session.id, started_at: started_at }.merge(overrides))
  end

  def removed_row(reason:, key: "zimmer#1", number: 1, **overrides)
    backlog_item(**{ key: key, issue_url: issue_url(number), status: WorkBacklogItem::REMOVED,
                     removal_reason: reason, removed_by: "session:1",
                     removed_at: 4.days.ago }.merge(overrides))
  end

  def probe(state: "OPEN", references: [], number: 1)
    Github::IssueLinkProbe::Probe.new(repo: "tadasant/zimmer", number: number, state: state,
                                      references: references)
  end

  def reference(state:, updated_at:, number: 500)
    Github::IssueLinkProbe::Reference.new(number: number, state: state, updated_at: updated_at)
  end

  # What one or more passes said, on both surfaces. `pages` are the ERROR log
  # records — the Grafana rule fires on those, and they are the half that can
  # reach a human more than once; `events` are the GlitchTip reports.
  Alerts = Struct.new(:log, :events) do
    def pages = log.string.lines.grep(/ERROR/).grep(/stranded, oldest/)
  end

  # Runs a block against a cache that can actually remember. The test env's
  # :null_store cannot, and the sweep deliberately stays silent against a store
  # that cannot — see `remember_alert_band`.
  def with_alerts(cache: ActiveSupport::Cache::MemoryStore.new)
    log = StringIO.new
    events = []

    Rails.stub(:cache, cache) do
      Rails.stub(:logger, Logger.new(log)) do
        ErrorReporter.stub(:report_message, ->(message, **kwargs) { events << kwargs.merge(message: message) }) do
          yield Alerts.new(log, events)
        end
      end
    end
  end

  # One pass with the GitHub probe stubbed. `probes` is keyed by issue number, as
  # Github::IssueLinkProbe returns; `probe_error` makes the probe raise instead.
  def sweep(probes: {}, probe_error: nil, logger: Rails.logger)
    stub = lambda do |repo:, numbers:|
      raise Github::IssueLinkProbe::ProbeError, probe_error if probe_error

      probes.slice(*numbers)
    end

    Github::IssueLinkProbe.stub(:call, stub) do
      WorkBacklog::LivenessSweep.sweep!(logger: logger)
    end
  end
end
