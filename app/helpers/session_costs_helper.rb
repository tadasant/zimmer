# frozen_string_literal: true

# The muted per-session cost indicator on the dashboard cards and the session
# detail page.
#
# The dashboard renders up to a few hundred cards in one response, so the figure
# has to come from ONE grouped query rather than one per card. `preload_session_costs`
# is that query; every partial that renders a collection of cards calls it before
# the loop. `session_cost_usd` reads the preloaded index and falls back to a single
# scoped query when there isn't one — which is the right answer for the other
# render path, the single-card turbo-stream broadcast, where a batch would be a
# batch of one.
module SessionCostsHelper
  # Warm the per-request index for a collection. Idempotent and additive, so a page
  # with several sections can call it once per section without re-querying ids it
  # already has.
  def preload_session_costs(sessions)
    ids = Array(sessions).filter_map { |s| s.respond_to?(:id) ? s.id : s }
    @session_cost_index ||= {}
    missing = ids - @session_cost_index.keys
    @session_cost_index.merge!(SessionTokenUsage.cost_by_session(missing)) if missing.any?
    nil
  end

  def session_cost_usd(session)
    @session_cost_index ||= {}
    preload_session_costs([ session ]) unless @session_cost_index.key?(session.id)
    @session_cost_index[session.id].to_f
  end

  # A secondary signal, and styled like one. Tadas asked for it "fairly muted":
  # this is a spend figure on a page about work, so it reads as gray small text
  # beside the session id rather than as a number the card is about.
  #
  # Zero is rendered as nothing at all. A session with no stored usage is usually
  # one whose transcript has not been swept yet, and "$0.00" would assert it was
  # free.
  def session_cost_badge(session, classes: "text-xs text-gray-400 tabular-nums")
    cost = session_cost_usd(session)
    return nil unless cost.positive?

    tag.span(
      number_to_currency(cost, precision: cost < 1 ? 3 : 2),
      class: classes,
      title: "Estimated inference cost for this session at current list prices. " \
             "Volumes are Zimmer's own ledger; see the Costs page."
    )
  end
end
