# frozen_string_literal: true

# Read API over the token-spend ledger.
#
# Two shapes, because the two questions are different:
#
#   GET /api/v1/costs          — rollups. What the Costs page renders, as JSON.
#   GET /api/v1/costs/records  — the rows themselves, paginated. The export path
#                                for analysis that this app should not be doing,
#                                including the cost-vs-performance work these
#                                tables exist to enable.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::CostsController < Api::BaseController
  MAX_DAYS = 365
  DEFAULT_DAYS = 7

  # GET /api/v1/costs
  #
  # Query parameters:
  #   - days: window size (default 7, max 365). Ignored when from/to are given.
  #   - from, to: explicit ISO-8601 bounds
  def index
    analytics = CostAnalytics.new(from: window_start, to: window_end)

    render json: {
      window: { from: analytics.from.iso8601, to: analytics.to.iso8601 },
      pricing: pricing_json,
      totals: analytics.totals,
      cost_breakdown: analytics.cost_breakdown,
      by_day: analytics.by_day,
      by_agent_root: analytics.by_agent_root,
      by_model: analytics.by_model,
      by_thread_kind: analytics.by_thread_kind,
      by_adhoc_source: analytics.by_adhoc_source,
      top_sessions: analytics.top_sessions,
      unpriced_models: analytics.unpriced_models
    }
  end

  # GET /api/v1/costs/records
  #
  # Query parameters:
  #   - kind: "session" (default) or "adhoc"
  #   - session_id, agent_root, model, source: filters
  #   - days / from / to: window
  #   - page, per_page
  def records
    scope = base_scope.in_window(window_start, window_end).recent_first
    scope = apply_filters(scope)

    result = paginate(scope)

    render json: {
      kind: kind,
      window: { from: window_start.iso8601, to: window_end.iso8601 },
      records: result[:records].map { |r| record_json(r) },
      pagination: result[:pagination]
    }
  end

  private

  def kind = params[:kind].presence == "adhoc" ? "adhoc" : "session"

  def base_scope = kind == "adhoc" ? AdhocTokenUsage.all : SessionTokenUsage.all

  def apply_filters(scope)
    scope = scope.where(model: params[:model]) if params[:model].present?
    if kind == "adhoc"
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where(subject_session_id: params[:session_id]) if params[:session_id].present?
    else
      scope = scope.where(session_id: params[:session_id]) if params[:session_id].present?
      scope = scope.where(agent_root: params[:agent_root]) if params[:agent_root].present?
      scope = scope.where(subagent: ActiveModel::Type::Boolean.new.cast(params[:subagent])) unless params[:subagent].nil?
    end
    scope
  end

  def window_end
    parse_time(params[:to]) || Time.current
  end

  def window_start
    parse_time(params[:from]) || (window_end - requested_days.days)
  end

  def requested_days
    value = params[:days].to_i
    return DEFAULT_DAYS unless value.positive?
    value.clamp(1, MAX_DAYS)
  end

  def parse_time(raw)
    return nil if raw.blank?
    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  # The rates used to produce every dollar figure in the response. Returned so a
  # consumer can tell WHICH prices a number was computed at — the volumes are
  # durable but the prices are not, and a figure without its rate table is not
  # reproducible.
  def pricing_json
    {
      note: "List price, applied at read time. Volumes are stored; prices are not.",
      cache_multipliers: {
        read: TokenPricing::CACHE_READ_MULTIPLIER,
        write_5m: TokenPricing::CACHE_WRITE_5M_MULTIPLIER,
        write_1h: TokenPricing::CACHE_WRITE_1H_MULTIPLIER
      },
      web_search_per_1k_requests: TokenPricing::WEB_SEARCH_PER_1K_REQUESTS,
      per_mtok: TokenPricing::RATES.transform_values do |rate|
        {
          input: rate.input, output: rate.output, cache_read: rate.cache_read,
          cache_write_5m: rate.cache_write_5m, cache_write_1h: rate.cache_write_1h
        }
      end
    }
  end

  def record_json(record)
    json = {
      id: record.id,
      request_id: record.request_id,
      model: record.model,
      called_at: record.called_at&.iso8601,
      input_tokens: record.input_tokens,
      output_tokens: record.output_tokens,
      cache_read_tokens: record.cache_read_tokens,
      cache_creation_tokens: record.cache_creation_tokens,
      cache_creation_5m_tokens: record.cache_creation_5m_tokens,
      cache_creation_1h_tokens: record.cache_creation_1h_tokens,
      web_search_requests: record.web_search_requests,
      web_fetch_requests: record.web_fetch_requests,
      total_tokens: record.total_tokens,
      cost_usd: record.cost_usd,
      priced: record.priced?,
      service_tier: record.service_tier
    }

    if record.is_a?(SessionTokenUsage)
      json.merge(session_id: record.session_id, agent_root: record.agent_root, subagent: record.subagent)
    else
      json.merge(source: record.source, subject_session_id: record.subject_session_id, metadata: record.metadata)
    end
  end
end
