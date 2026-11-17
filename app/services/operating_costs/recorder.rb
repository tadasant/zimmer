# frozen_string_literal: true

module OperatingCosts
  # The one write contract for operating costs. The Costs page's forms, `POST
  # /api/v1/operating_costs/actions` and `action_operating_costs` all land here,
  # so a human typing in a receipt and the daily collection session writing a
  # month of invoices go through the same validation and the same upserts.
  #
  # A batch is all or nothing: one invalid item rolls the whole batch back and
  # the error names it (`observations[3]: …`). Everything is upserted by its
  # natural key, so writing the same batch twice changes nothing and reports
  # every item `unchanged`:
  #
  #   functionalities   key
  #   vendors           key
  #   accounts          key
  #   subscriptions     account + plan_name + started_on
  #   observations      account + metric + as_of_date + period_start + source
  #   credit_snapshots  account + as_of_date + source
  #
  # Accounts, vendors and functionalities are referred to by key, so a batch can
  # create a vendor and its accounts and their figures in one call.
  #
  # After the write, every touched account's daily series is rebuilt over the
  # dates the batch spoke for, and their months re-allocated.
  class Recorder
    class Error < StandardError; end

    KINDS = %w[functionalities vendors accounts subscriptions observations credit_snapshots].freeze
    MAX_ITEMS = 2_000
    RAW_PAYLOAD_LIMIT = 20_000
    REBUILD_HORIZON = 400

    Result = Data.define(:counts, :accounts_rebuilt, :run) do
      def as_json(*) = { counts: counts, accounts_rebuilt: accounts_rebuilt, collection_run_id: run&.id }
    end

    # @param payload [Hash] string- or symbol-keyed, one array per KINDS entry
    # @param collector [String, nil] when given, the batch is recorded as a run
    #   of this collector (OperatingCostCollectionRun), the "has it run" answer
    # @param session_id [Integer, nil] the session writing, stamped on every fact
    # @param derived [Boolean] the `derived` source is Zimmer's own estimate, and
    #   only OperatingCostsCollectionJob may write it; anyone else is refused, so
    #   an outside figure cannot collide with the job's natural key.
    def self.record!(payload, collector: nil, session_id: nil, today: Date.current, derived: false)
      new(collector: collector, session_id: session_id, today: today, derived: derived).record!(payload)
    end

    def initialize(collector: nil, session_id: nil, today: Date.current, derived: false)
      @collector = collector.presence
      @session_id = session_id
      @today = today
      @derived = derived
      @counts = KINDS.index_with { { "created" => 0, "updated" => 0, "unchanged" => 0 } }
      @touched = {}
    end

    def record!(payload)
      payload = normalize_payload(payload)
      run = start_run
      # The rebuild is inside the transaction: a batch whose figures were stored
      # but whose series failed to rebuild would read `unchanged` on a retry and
      # never be rebuilt.
      rebuilt = ActiveRecord::Base.transaction do
        KINDS.each do |kind|
          Array(payload[kind]).each_with_index do |item, index|
            send("upsert_#{kind.singularize}", item.to_h.stringify_keys)
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Error, ArgumentError, Date::Error => e
            raise Error, "#{kind}[#{index}]: #{e.message}"
          end
        end
        rebuild_touched!
      end
      finish_run(run, "succeeded")
      Result.new(counts: @counts, accounts_rebuilt: rebuilt, run: run)
    rescue StandardError => e
      @counts = KINDS.index_with { { "created" => 0, "updated" => 0, "unchanged" => 0 } }
      finish_run(run, "failed", e.message)
      raise
    end

    # Close a subscription on a date. Idempotent.
    def end_subscription!(account:, plan_name:, ended_on:, started_on: nil)
      account = find_account!(account)
      scope = account.subscriptions.where(plan_name: plan_name)
      scope = scope.where(started_on: parse_date(started_on)) if started_on.present?
      subscription = scope.order(started_on: :desc).first || raise(Error, "No subscription #{plan_name.inspect} on #{account.key}")
      subscription.update!(ended_on: parse_date(ended_on))
      touch(account, subscription.started_on)
      rebuild_touched!
      subscription
    end

    def delete_observation!(id)
      observation = OperatingCostObservation.find(id)
      observation.destroy!
      touch(observation.account, observation.period_start)
      rebuild_touched!
      observation
    end

    def delete_credit_snapshot!(id)
      snapshot = OperatingCostCreditSnapshot.find(id)
      snapshot.destroy!
      snapshot
    end

    private

    def normalize_payload(payload)
      payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
      raise Error, "The payload must be an object with any of: #{KINDS.join(', ')}" unless payload.is_a?(Hash)

      payload = payload.deep_stringify_keys
      unknown = payload.keys - KINDS
      raise Error, "Unknown payload key(s): #{unknown.join(', ')}. Expected any of: #{KINDS.join(', ')}" if unknown.any?

      payload.each do |kind, items|
        raise Error, "#{kind} must be an array" unless items.is_a?(Array)
      end
      size = payload.values.sum(&:size)
      raise Error, "The payload is empty" if size.zero?
      raise Error, "At most #{MAX_ITEMS} items per batch (got #{size})" if size > MAX_ITEMS

      payload
    end

    # --- Upserts ---------------------------------------------------------------

    def upsert_functionality(item)
      record = OperatingCostFunctionality.find_or_initialize_by(key: require!(item, "key"))
      assign(record, item, %w[name description agent_roots mcp_servers position active])
      # Which functionality claims which root moves money between functionalities
      # in every month already allocated, so those months are re-split.
      @reallocate_all = true if record.persisted? && (record.agent_roots_changed? || record.active_changed?)
      save("functionalities", record)
    end

    def upsert_vendor(item)
      record = OperatingCostVendor.find_or_initialize_by(key: require!(item, "key"))
      assign(record, item, %w[name category pricing_model ingest_method billing_url notes active])
      save("vendors", record)
    end

    def upsert_account(item)
      record = OperatingCostAccount.find_or_initialize_by(key: require!(item, "key"))
      if item.key?("vendor")
        record.vendor = OperatingCostVendor.find_by(key: item["vendor"]) || raise(Error, "Unknown vendor: #{item['vendor']}")
      end
      if item.key?("functionality")
        record.functionality = item["functionality"].presence &&
          (OperatingCostFunctionality.find_by(key: item["functionality"]) || raise(Error, "Unknown functionality: #{item['functionality']}"))
      end
      assign(record, item, %w[label paid_by zimmer_share allocation_rule allocation_config derived_source environment external_ref notes active])
      changed = record.changed?
      save("accounts", record)
      # A new share or allocation rule changes every figure the account has.
      touch(record, record.daily_entries.minimum(:date) || @today - 1) if changed && record.daily_entries.exists?
    end

    def upsert_subscription(item)
      account = find_account!(require!(item, "account"))
      started_on = parse_date(require!(item, "started_on"))
      record = account.subscriptions.find_or_initialize_by(plan_name: require!(item, "plan_name"), started_on: started_on)
      assign(record, item, %w[amount currency amount_usd interval quantity included_usage_usd ended_on renews_on auto_renew notes])
      changed = record.changed?
      save("subscriptions", record)
      touch(account, started_on) if changed
    end

    def upsert_observation(item)
      account = find_account!(require!(item, "account"))
      metric = require!(item, "metric")
      if item["source"].to_s == "derived" && !@derived
        raise Error, "source \"derived\" is Zimmer's own estimate and only the daily job writes it; use agent, manual, billing_api or card_statement"
      end
      as_of = parse_date(item["as_of_date"]) if item["as_of_date"].present?
      period_start = parse_date(item["period_start"]) if item["period_start"].present?
      period_end = parse_date(item["period_end"]) if item["period_end"].present?
      period_start ||= as_of if metric == "daily_cost"
      as_of ||= period_end if metric == "invoice"
      raise Error, "as_of_date is required" if as_of.nil?
      raise Error, "period_start is required for #{metric}" if period_start.nil?

      record = account.observations.find_or_initialize_by(
        metric: metric, as_of_date: as_of, period_start: period_start, source: require!(item, "source")
      )
      record.period_end = period_end if period_end
      assign(record, item, %w[amount currency amount_usd confidence evidence])
      record.collector ||= @collector
      record.raw_payload = scrub(item["raw_payload"]) if item.key?("raw_payload")
      record.recorded_by_session_id = @session_id if record.new_record? || record.changed?
      changed = record.changed?
      save("observations", record)
      touch(account, record.period_start) if changed
    end

    def upsert_credit_snapshot(item)
      account = find_account!(require!(item, "account"))
      record = account.credit_snapshots.find_or_initialize_by(
        as_of_date: parse_date(require!(item, "as_of_date")), source: require!(item, "source")
      )
      assign(record, item, %w[balance currency balance_usd kind granted_total expires_on evidence])
      record.recorded_by_session_id = @session_id if record.new_record? || record.changed?
      save("credit_snapshots", record)
    end

    # --- Helpers ---------------------------------------------------------------

    def assign(record, item, attributes)
      attributes.each do |attribute|
        next unless item.key?(attribute)

        value = item[attribute]
        value = parse_date(value) if value.present? && attribute.end_with?("_on")
        value = nil if value == "" && !%w[agent_roots mcp_servers allocation_config].include?(attribute)
        record.public_send("#{attribute}=", value)
      end
    end

    def save(kind, record)
      outcome = if record.new_record? then "created" elsif record.changed? then "updated" else "unchanged" end
      record.save! unless outcome == "unchanged"
      @counts[kind][outcome] += 1
    end

    def require!(item, key)
      value = item[key]
      raise Error, "#{key} is required" if value.blank?

      value.to_s
    end

    def find_account!(key)
      OperatingCostAccount.find_by(key: key.to_s) || raise(Error, "Unknown account: #{key}")
    end

    def parse_date(value)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise Error, "#{value.inspect} is not a YYYY-MM-DD date"
    end

    # Billing exports carry account identifiers and, now and then, something
    # worse. The payload is redacted like a transcript and capped.
    def scrub(payload)
      return {} if payload.blank?

      text = TranscriptRedactor.redact(payload.is_a?(String) ? payload : payload.to_json).to_s
      return { "truncated" => text.first(RAW_PAYLOAD_LIMIT) } if text.size > RAW_PAYLOAD_LIMIT

      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : { "value" => parsed }
    rescue JSON::ParserError
      { "text" => text.to_s.first(RAW_PAYLOAD_LIMIT) }
    end

    def touch(account, from)
      from = [ from, @today - REBUILD_HORIZON ].max
      @touched[account.id] = [ @touched[account.id], from ].compact.min
    end

    def rebuild_touched!
      reallocate_everything! if @reallocate_all
      return 0 if @touched.empty?

      accounts = OperatingCostAccount.where(id: @touched.keys).to_a
      yesterday = @today - 1
      months = Set.new
      accounts.each do |account|
        from = @touched[account.id]
        next if from > yesterday

        Ledger.rebuild!(account: account, from: from, to: yesterday)
        month = from.beginning_of_month
        while month <= yesterday
          months << month
          month = month.next_month
        end
      end
      months.each { |month| Allocator.allocate!(month: month, accounts: accounts) }
      @touched = {}
      accounts.size
    end

    def reallocate_everything!
      @reallocate_all = false
      first = OperatingCostDailyEntry.minimum(:date)
      return unless first

      accounts = OperatingCostAccount.all.to_a
      month = [ first, @today - REBUILD_HORIZON ].max.beginning_of_month
      while month <= @today - 1
        Allocator.allocate!(month: month, accounts: accounts)
        month = month.next_month
      end
    end

    def start_run
      return nil unless @collector

      OperatingCostCollectionRun.create!(collector: @collector, status: "running", started_at: Time.current, session_id: @session_id)
    end

    def finish_run(run, status, error = nil)
      return unless run

      run.update!(status: status, finished_at: Time.current, error: error,
                  rows_written: @counts.values.sum { |c| c["created"] + c["updated"] }, details: { counts: @counts })
    end
  end
end
