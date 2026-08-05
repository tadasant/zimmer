module SettingsHelper
  # The spot gate renders each genesis kind twice — a stacked card below the `sm`
  # breakpoint, a table row above it — because a four-column table does not fit a
  # phone. Both renderings read their state from here so the two cannot disagree
  # about which class a kind carries or which class a click would move it to.
  #
  # Returns [current_class, target_class, overridden?, badge_css].
  def genesis_kind_state(kind, genesis_classes)
    current = genesis_classes[kind.key]
    target = current == SessionGenesis::PRIORITY ? SessionGenesis::SPOT : SessionGenesis::PRIORITY
    badge = if current == SessionGenesis::PRIORITY
      "bg-indigo-100 text-indigo-800"
    else
      "bg-gray-100 text-gray-700"
    end

    [ current, target, current != kind.default_class, badge ]
  end
end
