# frozen_string_literal: true

# View-side half of the `catalog-multiselect` Stimulus controller (zimmer#456).
#
# Two jobs, both of which exist so the controller does not have to branch:
#
#   * `catalog_multiselect_items` normalises the four catalogs' differently
#     shaped option hashes to a single `{ key:, title:, ... }`. Skills and hooks
#     identify by `name`, plugins by `id`, MCP servers by `name` — that split
#     lives here and nowhere else.
#
#   * `catalog_multiselect_accent` resolves an accent token to complete Tailwind
#     class strings. Same rule as the JS table it mirrors: every class name is
#     written out in full so Tailwind's scanner can see it (`@source
#     "../../helpers/**/*.rb"` in app/assets/tailwind/application.css). Never
#     interpolate a colour into a class name.
module CatalogMultiselectHelper
  ACCENT_CLASSES = {
    "green" => {
      edit_link: "text-green-600 hover:text-green-800",
      input: "focus:ring-green-500 focus:border-green-500",
      save_button: "bg-green-600 text-white hover:bg-green-700 focus:ring-green-500",
      cancel_button: "focus:ring-green-500",
      display_chip_inline: "px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800",
      display_chip_stacked: "gap-1 px-2 py-1 rounded-md text-xs font-medium border bg-green-50 text-green-800 border-green-200"
    },
    "indigo" => {
      edit_link: "text-indigo-600 hover:text-indigo-800",
      input: "focus:ring-indigo-500 focus:border-indigo-500",
      save_button: "bg-indigo-600 text-white hover:bg-indigo-700 focus:ring-indigo-500",
      cancel_button: "focus:ring-indigo-500",
      display_chip_inline: "px-1.5 py-0.5 rounded text-xs font-medium bg-indigo-100 text-indigo-800",
      display_chip_stacked: "gap-1 px-2 py-1 rounded-md text-xs font-medium border bg-indigo-50 text-indigo-800 border-indigo-200"
    },
    "purple" => {
      edit_link: "text-purple-600 hover:text-purple-800",
      input: "focus:ring-purple-500 focus:border-purple-500",
      save_button: "bg-purple-600 text-white hover:bg-purple-700 focus:ring-purple-500",
      cancel_button: "focus:ring-purple-500",
      display_chip_inline: "px-1.5 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800",
      display_chip_stacked: "gap-1 px-2 py-1 rounded-md text-xs font-medium border bg-purple-50 text-purple-800 border-purple-200"
    },
    "amber" => {
      edit_link: "text-amber-600 hover:text-amber-800",
      input: "focus:ring-amber-500 focus:border-amber-500",
      save_button: "bg-amber-600 text-white hover:bg-amber-700 focus:ring-amber-500",
      cancel_button: "focus:ring-amber-500",
      display_chip_inline: "px-1.5 py-0.5 rounded text-xs font-medium bg-amber-100 text-amber-800",
      display_chip_stacked: "gap-1 px-2 py-1 rounded-md text-xs font-medium border bg-amber-50 text-amber-800 border-amber-200"
    }
  }.freeze

  # Fall back to green rather than raising: an unknown accent should render a
  # usable widget, not a 500.
  def catalog_multiselect_accent(accent)
    ACCENT_CLASSES.fetch(accent.to_s, ACCENT_CLASSES.fetch("green"))
  end

  # The `data-*` attributes that wire one widget to the controller. Spread with
  # `tag.attributes` so a caller's existing `class` and `id` stay in place.
  #
  # @param items [Array<Hash>] from `catalog_multiselect_items`
  # @param selected [Array<String>] currently persisted keys
  # @param accent [String] accent token
  # @param payload_key [String] the key the endpoint expects the array under —
  #   and, in form mode, the name the widget announces itself under
  # @param variant [Symbol] `:inline` (desktop meta row), `:stacked` (mobile
  #   card) or `:field` (a form field — no display region, so no display chips)
  # @param persist_url [String] blank for a widget that submits with a form;
  #   its presence is what puts the controller in inline-edit mode
  # @param input_name [String] form mode: the `name` on every hidden input
  # @param agent_root_defaults [Hash] form mode: `{ root_name => [key, ...] }`
  #
  # `display_chip_class` goes unread when `turbo_stream:` is true: MCP servers
  # re-render their display region server-side, so the controller never rewrites
  # a chip there. Emitted anyway rather than special-cased, so every widget
  # carries the same attributes.
  def catalog_multiselect_attributes(items:, selected:, accent:, payload_key:, variant:,
                                     persist_url: "", injected: [], group_by_category: false,
                                     show_description: false, turbo_stream: false,
                                     input_name: "", preserve_unknown: false,
                                     emit_empty_input: false, agent_root_defaults: {})
    {
      controller: "catalog-multiselect",
      catalog_multiselect_items_value: items.to_json,
      catalog_multiselect_selected_value: Array(selected).to_json,
      catalog_multiselect_injected_value: Array(injected).to_json,
      catalog_multiselect_accent_value: accent,
      catalog_multiselect_group_by_category_value: group_by_category,
      catalog_multiselect_show_description_value: show_description,
      catalog_multiselect_display_chip_class_value: catalog_multiselect_display_chip_class(accent, variant),
      catalog_multiselect_persist_url_value: persist_url,
      catalog_multiselect_payload_key_value: payload_key,
      catalog_multiselect_turbo_stream_value: turbo_stream,
      catalog_multiselect_input_name_value: input_name,
      catalog_multiselect_preserve_unknown_value: preserve_unknown,
      catalog_multiselect_emit_empty_input_value: emit_empty_input,
      catalog_multiselect_agent_root_defaults_value: agent_root_defaults.to_json
    }
  end

  # The `:field` variant has no display region at all, so there is no chip class
  # to resolve — empty rather than an arbitrary one, so a future reader does not
  # read it as meaningful.
  def catalog_multiselect_display_chip_class(accent, variant)
    case variant.to_sym
    when :stacked then catalog_multiselect_accent(accent).fetch(:display_chip_stacked)
    when :field then ""
    else catalog_multiselect_accent(accent).fetch(:display_chip_inline)
    end
  end

  # @param options [Array<Hash>, nil] whatever the catalog's `*_for_select`
  #   builder produced
  # @param key [Symbol] the field that identifies an artifact of this type
  # @return [Array<Hash>] `{ key:, title:, description:, category:, scope:,
  #   unavailable:, unavailable_reason: }`, with blanks dropped
  def catalog_multiselect_items(options, key:)
    Array(options).filter_map do |option|
      option = option.symbolize_keys
      identity = option[key]
      next if identity.blank?

      {
        key: identity,
        # A catalog entry with no title still has to be pickable; its own key is
        # the least surprising label.
        title: option[:title].presence || identity,
        description: option[:description],
        category: option[:category],
        # Only MCP servers set this, and only when two composed catalogs
        # contribute the same short id — the case where two chips would
        # otherwise both read "Slack".
        scope: option[:scope],
        unavailable: option[:unavailable],
        unavailable_reason: option[:unavailable_reason]
      }.compact
    end
  end
end
