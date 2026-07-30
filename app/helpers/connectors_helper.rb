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
end
