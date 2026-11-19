# frozen_string_literal: true

module OperatingCosts
  # The read model behind the Costs page, `GET /api/v1/operating_costs` and
  # `get_operating_costs`: historical months, the month in progress, and
  # projections, broken down by functionality, vendor, account or agent root.
  #
  # Everything is computed from the rebuilt tables (daily entries, monthly
  # allocations, subscriptions, credit snapshots), never from raw observations,
  # so all three surfaces agree to the cent.
  #
  # Figures run through yesterday: the daily collection lands a day's numbers the
  # morning after, so "today" is never partially counted.
  #
  # Externally paid accounts (`paid_by` other than self) are reported in their
  # own section and excluded from every total unless `include_external` is set.
  class Report
    DAYS_PER_MONTH = OperatingCostSubscription::DAYS_PER_MONTH
    TRAILING_DAYS = 28
    TREND_DAYS = 7
    INVOICE_LOOKBACK_DAYS = 120
    HISTORY_MONTHS = 6
    FORWARD_MONTHS = 3
    RENEWAL_HORIZON = 60
    # An account billed by invoice is fresh until its newest invoice's period
    # ends, and for this long after; anything else should have a figure every
    # day or two.
    INVOICE_STALE_AFTER_DAYS = 40
    GROUP_BYS = %w[functionality vendor account agent_root].freeze
    VIEWS = %w[summary timeseries projections sources].freeze
    GRANULARITIES = %w[day month].freeze
    UNATTRIBUTED = "Unattributed / shared"
    UNALLOCATED_ROOT = "Shared / unallocated"

    attr_reader :month, :as_of, :include_external, :functionality, :vendor, :agent_root

    # @param month [String, Date, nil] "YYYY-MM"; defaults to the current month
    # @raise [ArgumentError] on an unparseable month or an unknown filter key
    def initialize(month: nil, functionality: nil, vendor: nil, agent_root: nil, include_external: false, today: Date.current)
      @today = today
      @as_of = today - 1
      @month = parse_month(month) || today.beginning_of_month
      @include_external = ActiveModel::Type::Boolean.new.cast(include_external) || false
      @functionality = functionality.presence
      @vendor = vendor.presence
      @agent_root = agent_root.presence
      validate_filters!
    end

    def current_month? = @month == @today.beginning_of_month
    def filtered? = [ @functionality, @vendor, @agent_root ].any?

    def to_params
      { month: @month.strftime("%Y-%m"), functionality: @functionality, vendor: @vendor, agent_root: @agent_root,
        include_external: (@include_external ? "1" : nil) }.compact
    end

    # --- Totals ----------------------------------------------------------------

    def totals
      @totals ||= begin
        rows = breakdown("functionality")
        {
          month_to_date_usd: rows.sum { |r| r[:month_to_date_usd] },
          month_to_date_estimated_usd: rows.sum { |r| r[:month_to_date_estimated_usd] },
          month_projected_usd: rows.sum { |r| r[:month_projected_usd] },
          previous_month_usd: rows.sum { |r| r[:previous_month_usd] },
          forward_monthly_usd: rows.sum { |r| r[:forward_monthly_usd] },
          forward_monthly_trend_usd: rows.sum { |r| r[:forward_monthly_trend_usd] },
          billed_share: billed_share
        }
      end
    end

    # Closed months, the month in progress (actual and projected) and the months
    # ahead, oldest first.
    def monthly_strip
      @monthly_strip ||= begin
        closed = (1..HISTORY_MONTHS).to_a.reverse.map { |n| @month << n }
        history = closed.map do |m|
          { month: m.strftime("%Y-%m"), kind: "closed", actual_usd: sum_facts(allocation_facts(m)), estimated_usd: 0.to_d,
            projected_usd: nil }
        end
        current = { month: @month.strftime("%Y-%m"), kind: current_month? ? "current" : "closed",
                    actual_usd: totals[:month_to_date_usd], estimated_usd: totals[:month_to_date_estimated_usd],
                    projected_usd: current_month? ? totals[:month_projected_usd] : nil }
        forward = current_month? ? forward_months : []
        history + [ current ] + forward
      end
    end

    # --- Breakdowns -------------------------------------------------------------

    # One row per group: previous month, month to date, the month projected, and
    # the forward monthly run rate, each with the accounts behind it.
    #
    # Month to date is what the daily entries hold, plus, for an account billed
    # by invoice after the period closes, its forward rate over the days of this
    # month no invoice covers yet (`month_to_date_estimated_usd`, also counted in
    # `month_to_date_usd`). So the month projected is always month to date plus
    # the forward rate over the days after yesterday, for every account.
    def breakdown(group_by = "functionality", external: false)
      raise ArgumentError, "group_by must be one of #{GROUP_BYS.join(', ')}" unless GROUP_BYS.include?(group_by)

      @breakdowns ||= {}
      @breakdowns[[ group_by, external ]] ||= begin
        forward = forward_facts(:forward, external: external)
        accrued = accrued_estimate(forward)
        month_to_date = allocation_facts(@month, external: external) + accrued
        buckets = {
          previous_month_usd: allocation_facts(@month << 1, external: external),
          month_to_date_usd: month_to_date,
          month_to_date_estimated_usd: accrued,
          month_projected_usd: month_to_date + projected_remainder(forward),
          forward_monthly_usd: forward,
          forward_monthly_trend_usd: forward_facts(:trend, external: external)
        }
        groups = {}
        buckets.each do |bucket, facts|
          facts.each do |fact|
            key = group_key(fact, group_by)
            group = groups[key] ||= blank_group(key, group_by)
            group[bucket] += fact[:amount]
            account = group[:accounts][fact[:account].id] ||= blank_account(fact[:account])
            account[bucket] += fact[:amount]
          end
        end

        groups.values.map { |g| finish_group(g) }
          .reject { |g| g[:previous_month_usd].zero? && g[:month_to_date_usd].zero? && g[:forward_monthly_usd].zero? }
          .sort_by { |g| [ -g[:month_projected_usd], -g[:previous_month_usd], g[:label].to_s ] }
      end
    end

    # Externally paid accounts, grouped by who pays.
    def paid_by_others
      @paid_by_others ||= begin
        rows = breakdown("account", external: true)
        rows.group_by { |r| r[:paid_by] }.map do |payer, accounts|
          { paid_by: payer, previous_month_usd: accounts.sum { |a| a[:previous_month_usd] },
            month_to_date_usd: accounts.sum { |a| a[:month_to_date_usd] },
            month_to_date_estimated_usd: accounts.sum { |a| a[:month_to_date_estimated_usd] },
            forward_monthly_usd: accounts.sum { |a| a[:forward_monthly_usd] }, accounts: accounts }
        end
      end
    end

    # --- Projections -----------------------------------------------------------

    # Every account with credit snapshots: balance, burn, run-out.
    def credits
      @credits ||= scoped_accounts(external: :any).filter_map do |account|
        snapshots = snapshots_by_account[account.id]
        next if snapshots.blank?

        latest = snapshots.last
        burn = burn_per_day(snapshots)
        run_out = (latest.as_of_date + (latest.balance_usd.to_d / burn).floor.to_i if burn.positive? && latest.balance_usd.positive?)
        run_out = latest.as_of_date if burn.positive? && !latest.balance_usd.positive?
        run_out = [ run_out, latest.expires_on ].compact.min if latest.expires_on
        utilization = (1 - latest.balance_usd.to_d / latest.granted_total.to_d if latest.granted_total.to_d.positive?)
        { account: account.key, label: account.label, vendor: account.vendor.name, kind: latest.kind,
          as_of_date: latest.as_of_date, balance_usd: latest.balance_usd.to_f.round(2),
          granted_total: latest.granted_total&.to_f, burn_per_day_usd: burn.to_f.round(2),
          burn_per_month_usd: (burn * DAYS_PER_MONTH).to_f.round(2), run_out_on: run_out, expires_on: latest.expires_on,
          utilization: utilization&.to_f&.round(4), source: latest.source }
      end
    end

    def subscriptions
      @subscriptions ||= OperatingCostSubscription.includes(account: [ :vendor, :functionality ])
        .where(account_id: scoped_accounts(external: :any).map(&:id))
        .select { |s| s.active_on?(@today) }
        .sort_by { |s| [ -s.monthly_usd, s.plan_name ] }
    end

    def upcoming_renewals
      subscriptions.select { |s| s.renews_on && s.renews_on.between?(@today, @today + RENEWAL_HORIZON) }.sort_by(&:renews_on)
    end

    # --- Sources and freshness -------------------------------------------------

    def sources
      @sources ||= begin
        last_observed = last_observed_on
        last_confidence = OperatingCostDailyEntry.where(date: (@as_of - TRAILING_DAYS)..@as_of)
          .group(:account_id, :confidence).count
        scoped_accounts(external: :any).map do |account|
          confidences = last_confidence.select { |(id, _), _| id == account.id }.transform_keys(&:last)
          { account: account.key, label: account.label, vendor: account.vendor.name, ingest_method: account.vendor.ingest_method,
            derived_source: account.derived_source, last_observation_on: last_observed[account.id],
            confidence: confidences.max_by { |_, n| n }&.first, paid_by: account.paid_by,
            stale: stale_account?(account, last_observed[account.id]) }
        end
      end
    end

    def collection_runs
      @collection_runs ||= OperatingCostCollectionRun.latest_by_collector.to_a
    end

    # Stale when the derived pass has not succeeded within STALE_AFTER, any
    # collector's latest run failed, or a derived account's source had usage
    # that did not become a figure: usage on a model with no rate (money owed,
    # amount unknown), or a day with usage newer than the account's latest
    # observation.
    def stale_reasons
      @stale_reasons ||= begin
        reasons = []
        derived = OperatingCostCollectionRun.succeeded.where(collector: OperatingCostCollectionRun::DERIVED_COLLECTOR)
          .maximum(:finished_at)
        if derived.nil?
          reasons << "The daily derived collection has never run." if OperatingCostAccount.exists?
        elsif derived < OperatingCostCollectionRun::STALE_AFTER.ago
          reasons << "The daily derived collection last succeeded #{derived.to_date}."
        end
        # A failure ages out like a success does: a one-off collector that failed
        # once and was never run again must not hold the warning up forever.
        collection_runs.select { |r| r.status == "failed" && r.started_at > OperatingCostCollectionRun::STALE_AFTER.ago }.each do |run|
          reasons << "The latest #{run.collector} collection failed: #{run.error.to_s.truncate(160)}"
        end
        reasons.concat(derived_gap_reasons)
        reasons
      end
    end

    # --- Time series (MCP / REST) ---------------------------------------------

    def timeseries(group_by: "functionality", granularity: "month", from: nil, to: nil)
      raise ArgumentError, "granularity must be one of #{GRANULARITIES.join(', ')}" unless GRANULARITIES.include?(granularity)
      raise ArgumentError, "group_by must be one of #{GROUP_BYS.join(', ')}" unless GROUP_BYS.include?(group_by)

      to = to ? to.to_date : @as_of
      from = from ? from.to_date : (granularity == "day" ? to - 30 : (@month << HISTORY_MONTHS))
      raise ArgumentError, "from must be on or before to" if from > to
      raise ArgumentError, "a daily series spans at most 400 days" if granularity == "day" && (to - from) > 400

      series = Hash.new { |h, k| h[k] = Hash.new(0.to_d) }
      if granularity == "month"
        month = from.beginning_of_month
        while month <= to
          allocation_facts(month).each { |f| series[month.strftime("%Y-%m")][group_key(f, group_by)[1]] += f[:amount] }
          month = month.next_month
        end
      else
        accounts = scoped_accounts.index_by(&:id)
        OperatingCostDailyEntry.where(account_id: accounts.keys, date: from..to).find_each do |entry|
          account = accounts[entry.account_id]
          shares_for(account, entry.date.beginning_of_month).each do |share|
            fact = { account: account, root: share[:root], functionality_id: share[:functionality_id], amount: entry.amount_usd * share[:share] }
            next unless fact_matches?(fact)

            series[entry.date.iso8601][group_key(fact, group_by)[1]] += fact[:amount]
          end
        end
      end

      series.sort.map do |period, groups|
        { period: period, total_usd: groups.values.sum.to_f.round(2),
          groups: groups.sort_by { |_, v| -v }.map { |label, v| { label: label, amount_usd: v.to_f.round(2) } } }
      end
    end

    # --- Serialization ---------------------------------------------------------

    def as_api_json(view: "summary", group_by: "functionality", granularity: "month", from: nil, to: nil)
      raise ArgumentError, "view must be one of #{VIEWS.join(', ')}" unless VIEWS.include?(view)

      base = { as_of: @as_of, month: @month.strftime("%Y-%m"), filters: to_params.except(:month), currency: "USD",
               stale: stale_reasons.any?, stale_reasons: stale_reasons }
      case view
      when "summary"
        base.merge(totals: money(totals), group_by: group_by, rows: breakdown(group_by).map { |r| row_json(r) },
                   paid_by_others: paid_by_others.map { |p| money(p.except(:accounts)).merge(accounts: p[:accounts].map { |a| row_json(a) }) },
                   excluded_from_totals: "Accounts paid by someone else (paid_by other than self) are listed under paid_by_others and are not in totals.")
      when "timeseries"
        base.merge(group_by: group_by, granularity: granularity,
                   series: timeseries(group_by: group_by, granularity: granularity, from: from, to: to))
      when "projections"
        base.merge(totals: money(totals), monthly_strip: monthly_strip.map { |m| money(m) }, credits: credits,
                   subscriptions: subscriptions.map(&:as_api_json), upcoming_renewals: upcoming_renewals.map(&:as_api_json),
                   method: "Forward monthly = active subscriptions at monthly equivalent for accounts with no metered usage, " \
                           "and for accounts whose latest invoice only restates their subscriptions; for other accounts billed by " \
                           "invoice, the newest invoices' daily rate × #{DAYS_PER_MONTH.round(2)}; otherwise the trailing " \
                           "#{TRAILING_DAYS}-day average daily cost × #{DAYS_PER_MONTH.round(2)}. " \
                           "Month to date includes, as an estimate, the forward rate over the days an invoice billed in arrears " \
                           "has not covered yet; month projected adds the forward rate over the days after yesterday. " \
                           "Trend uses the trailing #{TREND_DAYS} days. Promotional credits cost nothing until their run-out date.")
      when "sources"
        base.merge(sources: sources, collection_runs: collection_runs.map(&:as_api_json))
      end
    end

    private

    def parse_month(value)
      return nil if value.blank?
      return value.to_date.beginning_of_month if value.respond_to?(:to_date) && !value.is_a?(String)
      raise ArgumentError, "month must be YYYY-MM" unless value.to_s.match?(/\A\d{4}-\d{2}\z/)

      Date.strptime(value.to_s, "%Y-%m")
    rescue Date::Error
      raise ArgumentError, "month must be YYYY-MM"
    end

    def validate_filters!
      if @functionality && @functionality != "unattributed" && !OperatingCostFunctionality.exists?(key: @functionality)
        raise ArgumentError, "Unknown functionality: #{@functionality}"
      end
      raise ArgumentError, "Unknown vendor: #{@vendor}" if @vendor && !OperatingCostVendor.exists?(key: @vendor)
    end

    def functionalities
      @functionalities_by_id ||= OperatingCostFunctionality.all.index_by(&:id)
    end

    def functionality_id_filter
      return @functionality_id_filter if defined?(@functionality_id_filter)

      @functionality_id_filter =
        if @functionality.nil? then :any
        elsif @functionality == "unattributed" then nil
        else OperatingCostFunctionality.find_by(key: @functionality)&.id
        end
    end

    def all_accounts
      @all_accounts ||= OperatingCostAccount.includes(:vendor, :functionality).to_a
    end

    # external: false → self-paid only (or everything with include_external);
    # true → externally paid only; :any → both.
    def scoped_accounts(external: false)
      all_accounts.select do |a|
        next false if @vendor && a.vendor.key != @vendor

        case external
        when :any then true
        when true then a.externally_paid?
        else @include_external || !a.externally_paid?
        end
      end
    end

    def allocations_for(month)
      @allocations ||= {}
      @allocations[month] ||= OperatingCostMonthlyAllocation.where(month: month).to_a.group_by(&:account_id)
    end

    def allocation_facts(month, external: false)
      accounts = scoped_accounts(external: external)
      accounts.flat_map do |account|
        Array(allocations_for(month)[account.id]).filter_map do |row|
          fact = { account: account, root: row.agent_root, functionality_id: row.functionality_id, amount: row.amount_usd.to_d }
          fact if fact_matches?(fact)
        end
      end
    end

    def fact_matches?(fact)
      return false if @agent_root && fact[:root] != @agent_root
      return false if functionality_id_filter != :any && fact[:functionality_id] != functionality_id_filter

      true
    end

    def sum_facts(facts) = facts.sum { |f| f[:amount] }

    # The latest allocation split for an account, used to spread a forward figure
    # (or a day) the way its month was spread.
    def shares_for(account, month = @month)
      rows = allocations_for(month)[account.id] || allocations_for(month << 1)[account.id]
      if rows.present?
        total = rows.sum { |r| r.share.to_d }
        return rows.map { |r| { root: r.agent_root, functionality_id: r.functionality_id, share: total.zero? ? 0 : r.share.to_d / total } }
      end

      [ { root: nil, functionality_id: account.functionality_id, share: 1.to_d } ]
    end

    def forward_facts(kind, external: false)
      scoped_accounts(external: external).flat_map do |account|
        # A run of credits can average below zero; a run rate never is.
        monthly = [ kind == :trend ? trend_monthly(account) : forward_monthly(account), 0.to_d ].max
        next [] if monthly.zero?

        shares_for(account).filter_map do |share|
          fact = { account: account, root: share[:root], functionality_id: share[:functionality_id], amount: monthly * share[:share] }
          fact if fact_matches?(fact)
        end
      end
    end

    def trailing_entries
      @trailing_entries ||= OperatingCostDailyEntry.where(date: (@as_of - TRAILING_DAYS + 1)..@as_of).to_a.group_by(&:account_id)
    end

    def first_entry_dates
      @first_entry_dates ||= OperatingCostDailyEntry.group(:account_id).minimum(:date)
    end

    def active_subscriptions(account)
      @subs_by_account ||= OperatingCostSubscription.all.to_a.group_by(&:account_id)
      Array(@subs_by_account[account.id]).select { |s| s.active_on?(@today) }
    end

    # What one account will cost per month from here.
    def forward_monthly(account)
      @forward_monthly ||= {}
      @forward_monthly[account.id] ||= begin
        if !account.active
          0.to_d
        else
          subs = active_subscriptions(account)
          metered = Array(trailing_entries[account.id]).any? { |e| e.basis != "prorated_subscription" } ||
            subs.any? { |s| s.included_usage_usd.to_d.positive? }
          if invoice_billed?(account) && invoice_restates_subscriptions?(account, subs)
            subs.sum(&:monthly_usd) * account.zimmer_share.to_d
          elsif invoice_billed?(account)
            invoice_daily_rate(account) * DAYS_PER_MONTH
          elsif metered
            average_daily(account, TRAILING_DAYS) * DAYS_PER_MONTH
          else
            subs.sum(&:monthly_usd) * account.zimmer_share.to_d
          end
        end
      end
    end

    def trend_monthly(account)
      return forward_monthly(account) if invoice_billed?(account)
      return forward_monthly(account) unless Array(trailing_entries[account.id]).any? { |e| e.basis != "prorated_subscription" }

      average_daily(account, TREND_DAYS) * DAYS_PER_MONTH
    end

    # Average over the window, or over the days since the account's first entry
    # when it is younger than the window.
    def average_daily(account, days)
      window_start = @as_of - days + 1
      first = first_entry_dates[account.id]
      return 0.to_d if first.nil? || first > @as_of

      start = [ window_start, first ].max
      entries = Array(trailing_entries[account.id]).select { |e| e.date >= start }
      entries.sum { |e| e.amount_usd.to_d } / ((@as_of - start).to_i + 1)
    end

    def remaining_days
      return 0 unless current_month?

      (@month.end_of_month - @as_of).to_i
    end

    def billed_share
      facts = allocation_facts(@month << 1)
      total = sum_facts(facts)
      return nil if total.zero?

      ids = facts.map { |f| f[:account].id }.uniq
      range = (@month << 1)..(@month << 1).end_of_month
      billed = OperatingCostDailyEntry.where(account_id: ids, date: range, confidence: "billed").sum(:amount_usd)
      all = OperatingCostDailyEntry.where(account_id: ids, date: range).sum(:amount_usd)
      all.zero? ? nil : (billed / all).to_f.round(4)
    end

    def forward_months
      base = totals[:forward_monthly_usd]
      (1..FORWARD_MONTHS).map do |n|
        month = @month >> n
        cliff = promotional_cliff(month)
        { month: month.strftime("%Y-%m"), kind: "forward", actual_usd: nil, estimated_usd: nil, projected_usd: base + cliff,
          credit_cliff_usd: cliff }
      end
    end

    # Promotional credit pays for usage until it runs out; from then on the burn
    # is real money. The extra cost a forward month carries for that.
    def promotional_cliff(month)
      range = month..month.end_of_month
      accounts = scoped_accounts.select(&:active).index_by(&:key)
      credits.select { |c| c[:kind] == "promotional" && c[:run_out_on] && c[:run_out_on] <= range.last }.sum do |c|
        account = accounts[c[:account]]
        next 0 unless account

        days = (range.last - [ c[:run_out_on], range.first ].max).to_i + 1
        burn = c[:burn_per_day_usd].to_d * days * account.zimmer_share.to_d
        # Spread the way the account's month is, so a filter keeps only its part.
        shares_for(account).sum do |share|
          fact = { account: account, root: share[:root], functionality_id: share[:functionality_id], amount: 0 }
          fact_matches?(fact) ? burn * share[:share] : 0
        end
      end
    end

    def snapshots_by_account
      @snapshots_by_account ||= OperatingCostCreditSnapshot
        .where(as_of_date: (@as_of - TRAILING_DAYS - 31)..@as_of).order(:as_of_date, :updated_at).to_a
        .group_by(&:account_id)
        .transform_values { |rows| rows.group_by(&:as_of_date).values.map(&:last) }
    end

    # Consumption per day from balance drops over the trailing window; a rise is
    # a top-up and adds nothing.
    def burn_per_day(snapshots)
      recent = snapshots.select { |s| s.as_of_date >= @as_of - TRAILING_DAYS }
      recent = snapshots.last(2) if recent.size < 2
      return 0.to_d if recent.size < 2

      drops = recent.each_cons(2).sum { |a, b| [ a.balance_usd.to_d - b.balance_usd.to_d, 0 ].max }
      days = (recent.last.as_of_date - recent.first.as_of_date).to_i
      days.positive? ? drops / days : 0.to_d
    end

    # The newest date each account's figures speak for, never later than the day
    # the figure was written: an invoice for a cycle that runs into next month is
    # as_of its period end, but it was recorded today, and freshness is about
    # when a figure arrived.
    def last_observation_dates
      zone = ActiveRecord::Base.connection.quote(Time.zone.tzinfo.name)
      recorded_on = "(operating_cost_observations.created_at AT TIME ZONE 'UTC' AT TIME ZONE #{zone})::date"
      OperatingCostObservation.group(:account_id)
        .maximum(Arel.sql("LEAST(operating_cost_observations.as_of_date, #{recorded_on})"))
        .transform_values { |date| [ date, @today ].min }
    end

    def stale_account?(account, last_observed)
      return false unless account.active
      return true if derived_gap?(account, last_observed)
      return false if %w[manual].include?(account.vendor.ingest_method)
      return false if account.vendor.ingest_method == "derived"
      return true if last_observed.nil?
      return last_observed < @as_of - 2 unless invoice_billed?(account)

      # A bill is fresh until its period is over, then for a cycle's grace.
      [ last_observed, latest_invoice_period_ends[account.id] ].compact.max < @as_of - INVOICE_STALE_AFTER_DAYS
    end

    def latest_invoice_period_ends
      @latest_invoice_period_ends ||= OperatingCostObservation.where(metric: "invoice").where.not(source: "derived")
        .group(:account_id).maximum(:period_end)
    end

    # What the derived collector's window shows for each derived account, read
    # live so a rate added in a deploy clears its reason without waiting a day.
    def derived_gaps
      @derived_gaps ||= DerivedCollector.new(today: @today).gaps.select { |account, _| account.active }
    end

    # Memoized: `sources` and the stale reasons read the same dates, so a source
    # row and its reason cannot disagree.
    def last_observed_on
      @last_observed_on ||= last_observation_dates
    end

    # The account's source had usage that is in no figure. A day's figure lands
    # the morning after, so only usage before yesterday counts as overdue.
    def derived_gap?(account, last_observed)
      gap = derived_gaps[account] or return false
      gap[:unpriced_models].any? || derived_overdue?(gap, last_observed)
    end

    def derived_overdue?(gap, last_observed)
      due = gap[:last_due_on]
      due.present? && due < @as_of && (last_observed.nil? || last_observed < due)
    end

    def derived_gap_reasons
      derived_gaps.flat_map do |account, gap|
        source = account.derived_source.tr("_", " ")
        reasons = []
        if gap[:unpriced_models].any?
          reasons << "#{account.label}: metered #{source} on #{gap[:unpriced_models].join(', ')} in the last " \
                     "#{DerivedCollector::WINDOW_DAYS} days (first on #{gap[:unpriced_since]}) has no rate in TokenPricing, " \
                     "so it is in no figure here. That is money owed at an unknown amount, not $0."
        end
        last = last_observed_on[account.id]
        if derived_overdue?(gap, last)
          reasons << "#{account.label}: #{source} had priced usage on #{gap[:last_due_on]}, " \
                     "but its latest figure is #{last ? "for #{last}" : 'missing'}."
        end
        reasons
      end
    end

    def group_key(fact, group_by)
      account = fact[:account]
      case group_by
      when "functionality"
        id = fact[:functionality_id]
        [ id, id ? functionalities[id]&.name.to_s : UNATTRIBUTED ]
      when "vendor" then [ account.vendor.key, account.vendor.name ]
      when "account" then [ account.key, account.label ]
      when "agent_root" then [ fact[:root], fact[:root] || UNALLOCATED_ROOT ]
      end
    end

    def blank_group(key, group_by)
      id, label = key
      extra =
        case group_by
        when "functionality" then { key: id ? functionalities[id]&.key : "unattributed" }
        when "account"
          account = all_accounts.find { |a| a.key == id }
          { key: id, vendor: account&.vendor&.name, paid_by: account&.paid_by }
        else { key: id }
        end
      { label: label, previous_month_usd: 0.to_d, month_to_date_usd: 0.to_d, month_to_date_estimated_usd: 0.to_d,
        month_projected_usd: 0.to_d,
        forward_monthly_usd: 0.to_d, forward_monthly_trend_usd: 0.to_d, accounts: {} }.merge(extra)
    end

    def blank_account(account)
      { key: account.key, label: account.label, vendor: account.vendor.name, paid_by: account.paid_by,
        allocation_rule: account.allocation_rule, previous_month_usd: 0.to_d, month_to_date_usd: 0.to_d,
        month_to_date_estimated_usd: 0.to_d, month_projected_usd: 0.to_d, forward_monthly_usd: 0.to_d, forward_monthly_trend_usd: 0.to_d }
    end

    def finish_group(group)
      group[:accounts] = group[:accounts].values.sort_by { |a| -a[:month_projected_usd] }
      group
    end

    # The rest of the month at the forward rate: the days after yesterday.
    def projected_remainder(forward)
      return [] unless current_month? && remaining_days.positive?

      forward.map { |fact| fact.merge(amount: fact[:amount] / DAYS_PER_MONTH * remaining_days) }
    end

    # An account billed by invoice after the period closes has nothing in its
    # current month until the bill arrives, which is not the same as costing
    # nothing: the forward rate over this month's days through yesterday that no
    # invoice covers yet, as an estimate. It is never a daily entry, so it never
    # counts toward `billed_share` and never reaches the daily series.
    def accrued_estimate(forward)
      return [] unless current_month?

      forward.filter_map do |fact|
        next unless invoice_billed?(fact[:account])

        days = elapsed_uncovered_days(fact[:account])
        fact.merge(amount: fact[:amount] / DAYS_PER_MONTH * days) if days.positive?
      end
    end

    def elapsed_uncovered_days(account)
      elapsed = (@as_of - @month).to_i + 1
      [ elapsed - month_entry_counts[account.id].to_i, 0 ].max
    end

    def month_entry_counts
      @month_entry_counts ||= OperatingCostDailyEntry.where(date: @month..@as_of).group(:account_id).count
    end

    # An account whose figures arrive as invoices after the period closes: its
    # current month is empty until then, which is not the same as free.
    def invoice_billed?(account)
      @last_metric ||= OperatingCostObservation.where.not(source: "derived")
        .select("DISTINCT ON (account_id) account_id, metric").order(:account_id, as_of_date: :desc).to_a.to_h { |o| [ o.account_id, o.metric ] }
      @last_metric[account.id] == "invoice"
    end

    # A fixed charge billed by invoice: the newest invoice is, to the cent or
    # half a percent, what the active subscriptions charge for its period. Such
    # an invoice is not metered usage, and spreading it over a 31-day cycle
    # would project the seat below its own price.
    def invoice_restates_subscriptions?(account, subs)
      return false if subs.empty? || subs.any? { |s| s.included_usage_usd.to_d.positive? }

      invoice = OperatingCostObservation.where(account_id: account.id, metric: "invoice").where.not(source: "derived")
        .order(period_end: :desc, updated_at: :desc).first
      return false unless invoice

      months = [ ((invoice.period_end - invoice.period_start + 1) / DAYS_PER_MONTH).round, 1 ].max
      charge = subs.sum(&:monthly_usd) * months
      (invoice.amount_usd.to_d - charge).abs <= [ 0.01.to_d, charge * 0.005.to_d ].max
    end

    # The newest LOOKBACK_DAYS of an invoice-billed account's entries, averaged
    # over the days they cover.
    def invoice_daily_rate(account)
      entries = OperatingCostDailyEntry.where(account_id: account.id, date: (@as_of - INVOICE_LOOKBACK_DAYS)..@as_of)
        .order(date: :desc).limit(TRAILING_DAYS).pluck(:amount_usd)
      entries.empty? ? 0.to_d : entries.sum.to_d / entries.size
    end

    def row_json(row)
      json = money(row.except(:accounts))
      json[:accounts] = row[:accounts].map { |a| money(a) } if row[:accounts]
      json
    end

    def money(hash)
      hash.transform_values { |v| v.is_a?(BigDecimal) ? v.to_f.round(2) : v }
    end
  end
end
