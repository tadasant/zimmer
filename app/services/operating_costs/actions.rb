# frozen_string_literal: true

module OperatingCosts
  # Every write on operating costs, by name. The Costs page's forms,
  # `POST /api/v1/operating_costs/actions` and `action_operating_costs` all call
  # #perform, so the three surfaces cannot drift: an action exists on one
  # exactly when it exists on all of them.
  #
  # Every write leaves one `[OperatingCosts]` log line naming the action, where
  # it came from and the session that made it.
  class Actions
    class Error < StandardError; end

    # action => the payload kind it upserts one item of
    UPSERTS = {
      "upsert_functionality" => "functionalities",
      "upsert_vendor" => "vendors",
      "upsert_account" => "accounts",
      "upsert_subscription" => "subscriptions",
      "upsert_observation" => "observations",
      "upsert_credit_snapshot" => "credit_snapshots"
    }.freeze
    NAMES = ([ "record" ] + UPSERTS.keys + %w[end_subscription delete_observation delete_credit_snapshot collect_now]).freeze

    # @param action [String] one of NAMES
    # @param args [Hash] string-keyed: `payload` for record, `item` for an
    #   upsert, the named fields for the rest
    # @param source [String] where the call came from, for the audit line
    # @param session_id [Integer, nil] the calling session, stamped on facts
    # @return [Hash] a JSON-ready receipt
    def self.perform(action, args, source:, session_id: nil)
      new(source: source, session_id: session_id).perform(action.to_s, (args || {}).to_h.deep_stringify_keys)
    end

    def initialize(source:, session_id:)
      @source = source
      @session_id = session_id
    end

    def perform(action, args)
      raise Error, "Unknown action #{action.inspect}. Expected one of: #{NAMES.join(', ')}" unless NAMES.include?(action)

      receipt = dispatch(action, args)
      Rails.logger.info("[OperatingCosts] #{action} via #{@source}#{" by session ##{@session_id}" if @session_id}: #{receipt.to_json.truncate(500)}")
      receipt
    rescue Recorder::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    rescue ActiveRecord::RecordNotFound => e
      raise Error, "Not found: #{e.message}"
    rescue ActiveRecord::RecordNotUnique
      raise Error, "Another write to the same record landed at the same moment; retry the call — it is idempotent."
    end

    private

    def dispatch(action, args)
      case action
      when "record"
        payload = args["payload"]
        raise Error, "record needs a `payload` object" unless payload.is_a?(Hash)

        result = Recorder.record!(payload, collector: args["collector"], session_id: @session_id)
        { action: action }.merge(result.as_json)
      when *UPSERTS.keys
        item = args["item"]
        raise Error, "#{action} needs an `item` object" unless item.is_a?(Hash)

        result = Recorder.record!({ UPSERTS.fetch(action) => [ item ] }, session_id: @session_id)
        { action: action }.merge(result.as_json)
      when "end_subscription"
        subscription = Recorder.new(session_id: @session_id).end_subscription!(
          account: required(args, "account"), plan_name: required(args, "plan_name"),
          ended_on: required(args, "ended_on"), started_on: args["started_on"]
        )
        { action: action, subscription: subscription.as_api_json }
      when "delete_observation"
        observation = Recorder.new(session_id: @session_id).delete_observation!(required(args, "id"))
        { action: action, deleted: observation.as_api_json }
      when "delete_credit_snapshot"
        snapshot = Recorder.new(session_id: @session_id).delete_credit_snapshot!(required(args, "id"))
        { action: action, deleted: snapshot.as_api_json }
      when "collect_now"
        OperatingCostsCollectionJob.perform_later
        { action: action, enqueued: true,
          note: "The derived collection runs within a minute; read its result with get_operating_costs view=sources." }
      end
    end

    def required(args, key)
      value = args[key]
      raise Error, "#{key} is required" if value.blank?

      value
    end
  end
end
