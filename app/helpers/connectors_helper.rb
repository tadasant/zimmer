# frozen_string_literal: true

module ConnectorsHelper
  # Badge colour per probe state. Green only for states that need nothing from
  # the user; red for states that block the server outright; amber for states
  # that resolve themselves or need one click.
  BADGE_CLASSES = {
    ready: "bg-green-100 text-green-800",
    no_credential_required: "bg-gray-100 text-gray-700",
    needs_authorization: "bg-amber-100 text-amber-800",
    token_expired: "bg-amber-100 text-amber-800",
    needs_reauth: "bg-red-100 text-red-800",
    missing_configuration: "bg-red-100 text-red-800",
    store_unavailable: "bg-orange-100 text-orange-800",
    probe_failed: "bg-orange-100 text-orange-800"
  }.freeze

  DEFAULT_BADGE_CLASSES = "bg-gray-100 text-gray-700"

  # How far up the list a state sorts. Lower is more urgent, and the ordering is
  # by *what the user has to do*, not by badge colour:
  #
  #   0-1  nothing works and only a human can fix it
  #   2    one click, right here on the row
  #   3-4  Zimmer could not find out; it may be fine, it may not
  #   5    resolves itself — the refresh job has it
  #   6-7  nothing to do
  #
  # The rank is computed server-side even though the sort happens in the browser,
  # so "which states are problems" has exactly one definition. The view emits it
  # as `data-connector-rank`; connector_list_controller reads it and never
  # decides severity for itself.
  SEVERITY_RANKS = {
    missing_configuration: 0,
    needs_reauth: 1,
    needs_authorization: 2,
    store_unavailable: 3,
    probe_failed: 4,
    token_expired: 5,
    ready: 6,
    no_credential_required: 7
  }.freeze

  # Anything ranked above `ready` is something the page should lead with.
  ATTENTION_RANK_CEILING = SEVERITY_RANKS.fetch(:ready)

  # @param state [Symbol, String]
  # @return [Integer]
  def connector_severity_rank(state)
    SEVERITY_RANKS.fetch(state.to_sym, ATTENTION_RANK_CEILING)
  end


  # Secret-source badges. The label strings themselves are fixed by the
  # providers (SecretProviders::*::BADGE) because strad's Secrets Console ships
  # the same set; only the colouring lives here.
  SOURCE_BADGE_CLASSES = {
    "GSM" => "bg-blue-100 text-blue-800",
    "Rails Credentials" => "bg-violet-100 text-violet-800",
    "ENV" => "bg-slate-200 text-slate-700",
    "X OAuth" => "bg-sky-100 text-sky-800",
    "Unresolved" => "bg-red-100 text-red-800",
    "Unknown" => "bg-orange-100 text-orange-800"
  }.freeze

  # @param badge [String]
  # @return [String] Tailwind classes for a secret-source badge
  def connector_source_badge_classes(badge)
    SOURCE_BADGE_CLASSES.fetch(badge, DEFAULT_BADGE_CLASSES)
  end

  # @param state [Symbol]
  # @return [String] Tailwind classes for the state badge
  def connector_badge_classes(state)
    BADGE_CLASSES.fetch(state.to_sym, DEFAULT_BADGE_CLASSES)
  end

  # The DOM/frame id for a connector row. Both the lazy frame on the index and
  # the frame in the rendered partial must agree on this, so it has one home.
  #
  # @param server_name [String]
  # @return [String]
  def connector_frame_id(server_name)
    "connector_#{server_name.parameterize(separator: '_')}"
  end

  # The other half of the Secrets Console story, and the reason the answer is not
  # one sentence for every row.
  #
  # A server Zimmer reaches *through the gateway* has two credentials, in two
  # places: the `${VAR}` on this row, which is Zimmer's own bearer token for the
  # gateway and lives in Zimmer's store; and the upstream credential the gateway
  # itself presents, which lives in the console's project under the server's own
  # slug. The console is the right destination for the second and never for the
  # first, and someone debugging a broken connector wants to know which one they
  # are looking at.
  #
  # Deliberately keyed on the GATEWAY's host rather than on the console's: those
  # are the same host today, but the console URL is overridable precisely so a
  # Zimmer-scoped console can replace it — and deriving this from that would make
  # the note silently vanish from every row that still has a second credential.
  #
  # @param server [ServersConfig::Server]
  # @return [Hash, nil] nil when this server is not reached through the gateway,
  #   which is when there is no second credential to talk about.
  def connector_gateway_console(server)
    return nil if server.url.blank?

    uri = begin
      URI.parse(server.url)
    rescue URI::InvalidURIError
      nil
    end
    return nil unless uri&.host == SecretsLocation.gateway_host

    slug = CGI.parse(uri.query.to_s)["servers"].first.presence
    {
      url: SecretsLocation.console_url,
      slug: slug,
      host: SecretsLocation.gateway_host,
      namespace: SecretsLocation.gateway_namespace(slug || "<slug>")
    }
  end
end
