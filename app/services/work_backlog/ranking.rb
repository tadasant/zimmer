# frozen_string_literal: true

module WorkBacklog
  # The ranking rules from `WORK_BACKLOG.md`, in one place, so the gate and the
  # groomer stop re-implementing them.
  #
  # SHORTEST WORK NEAR THE TOP. That is the whole rule: keeping WIP small means
  # finishing things, and the cheapest item is the one most likely to finish.
  # `precedence` is an absolute scale — higher is pulled sooner, values are
  # deliberately sparse, and an ordinary append renumbers nothing.
  #
  # BANDS. An unpinned item's `precedence` sits inside a band chosen by its
  # `estimated_cost`, which the gate already rated — nothing here re-estimates:
  #
  #   small   5000–6999, base 6000
  #   medium  2000–3999, base 3000
  #   large    500–1999, base 1000
  #
  # An append lands GAP below the lowest unpinned peer in its band (FIFO within a
  # band: new work does not jump work of its own size already waiting), clamped
  # at the floor. When the band reaches its floor it is re-spaced — its unpinned
  # peers spread evenly across [floor, base], order preserved — and the append
  # retried. A band that cannot be re-spaced past its floor raises BandFull rather
  # than crossing into the band below, because crossing would silently rank cheap
  # work below expensive work, which is the one property this exists to guarantee.
  #
  # PINNED ITEMS ARE NEVER TOUCHED. `pinned` is how a human hand-moves an item and
  # has it stay moved: it may sit anywhere, including below a floor, and it is
  # excluded from every peer set so one hand-placement cannot drag future appends
  # down with it.
  #
  # EVERY WRITER RE-RANKS. `rerank!` moves any unpinned queued item whose
  # precedence has drifted outside its band back to GAP below its band's lowest
  # peer, oldest `added_at` first so several drifted items land in a stable order.
  #
  # ONE WRITER AT A TIME. Every mutation of the queue runs inside `with_lock`,
  # which takes a transaction-scoped Postgres advisory lock: two gates appending at
  # once, or a pull racing an append, serialise instead of both computing "10
  # below the lowest peer" from the same snapshot.
  module Ranking
    Band = Data.define(:cost, :floor, :base, :ceiling) do
      def include?(precedence) = (floor..ceiling).cover?(precedence)
      def to_h = { cost: cost, floor: floor, base: base, ceiling: ceiling }
    end

    BANDS = {
      "small" => Band.new(cost: "small", floor: 5000, base: 6000, ceiling: 6999),
      "medium" => Band.new(cost: "medium", floor: 2000, base: 3000, ceiling: 3999),
      "large" => Band.new(cost: "large", floor: 500, base: 1000, ceiling: 1999)
    }.freeze

    # The spacing between consecutive appends in a band.
    GAP = 10

    # An arbitrary, stable key for the advisory lock. Only this module takes it.
    ADVISORY_LOCK_KEY = 0x574B424C # "WKBL"

    class BandFull < StandardError; end

    Placement = Data.define(:precedence, :respaced)

    module_function

    def band_for(cost)
      BANDS.fetch(cost.to_s) { raise ArgumentError, "unknown estimated_cost #{cost.inspect}; expected one of #{BANDS.keys.join(', ')}" }
    end

    # Serialise every queue mutation. Re-entrant: an advisory xact lock taken twice
    # by the same transaction succeeds immediately, and a nested `transaction`
    # joins the outer one, so WorkBacklog::Pull can call WorkBacklog::Start under
    # a lock it already holds.
    def with_lock(&block)
      WorkBacklogItem.transaction do
        WorkBacklogItem.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
        block.call
      end
    end

    # Where a new (or drifted) unpinned item of `cost` goes. Re-spaces the band
    # first when the next slot would be at or below the floor.
    #
    # @param cost [String] small / medium / large
    # @param except [WorkBacklogItem, nil] the item being placed, when it is
    #   already a row — excluded from its own peer set
    # @return [Placement]
    def place(cost, except: nil)
      band = band_for(cost)
      peers = peers(band, except: except)
      value = next_below(band, peers)
      return Placement.new(precedence: value, respaced: false) if value > band.floor

      # Decided BEFORE any row moves: a re-space that would itself push the
      # lowest peer to the floor cannot make room, and must not half-apply.
      unless respace_makes_room?(band, peers)
        raise BandFull, "the #{band.cost} band (#{band.floor}–#{band.ceiling}) is full: #{peers.size} unpinned " \
                        "items cannot be spaced past its floor. Refusing to cross into the band below — " \
                        "escalate rather than let cheap work rank below expensive work."
      end

      respace!(band, peers)
      Placement.new(precedence: next_below(band, peers(band, except: except)), respaced: true)
    end

    # Move every unpinned queued item that sits outside its band back into it.
    # Oldest `added_at` first, one at a time, so they land in a stable order.
    #
    # @return [Integer] how many items moved
    def rerank!(now: Time.current)
      drifted = WorkBacklogItem.queued.unpinned.reject(&:in_band?)
      drifted.sort_by { |item| [ item.added_at, item.id ] }.each do |item|
        placement = place(item.estimated_cost, except: item)
        item.update_columns(precedence: placement.precedence, updated_at: now)
      end
      drifted.size
    end

    # The unpinned queued items of this cost that sit INSIDE the band, highest
    # first. An item of the same cost that has drifted outside the numeric band
    # is not a peer: counting it would make "10 below the lowest peer" land
    # outside the band too, and force a re-space that nothing needed. `rerank!`
    # is what brings a drifted item home, one at a time, relative to these.
    def peers(band, except: nil)
      scope = WorkBacklogItem.queued.unpinned
        .where(estimated_cost: band.cost, precedence: band.floor..band.ceiling)
      scope = scope.where.not(id: except.id) if except&.persisted?
      scope.order(precedence: :desc, added_at: :asc, id: :asc).to_a
    end

    # `new = max(band_floor, lowest − GAP)`, with an empty band starting at base.
    def next_below(band, peers)
      lowest = peers.empty? ? band.base + GAP : peers.map(&:precedence).min
      [ band.floor, lowest - GAP ].max
    end

    # The re-space step: `max(1, (base − floor) // (n + 2))`.
    def respace_step(band, peers)
      [ 1, (band.base - band.floor) / (peers.size + 2) ].max
    end

    # Would re-spacing leave a slot strictly above the floor for the next item?
    # The lowest peer lands at `base − (n − 1) × step`, and the next append goes
    # GAP below that.
    def respace_makes_room?(band, peers)
      return true if peers.empty?

      lowest_after = band.base - ((peers.size - 1) * respace_step(band, peers))
      lowest_after - GAP > band.floor
    end

    # Spread the band's unpinned peers evenly across [floor, base]: highest
    # existing peer at the base, order preserved.
    def respace!(band, peers, now: Time.current)
      return if peers.empty?

      step = respace_step(band, peers)
      peers.each_with_index do |item, index|
        item.update_columns(precedence: band.base - (index * step), updated_at: now)
      end
    end

    # The bands, for a tool description or an API response that wants to say
    # where a value came from.
    def describe_bands
      BANDS.values.map(&:to_h)
    end

    # "5000–6999 (base 6000)", for prose.
    def describe_band(cost)
      band = band_for(cost)
      "#{band.floor}–#{band.ceiling} (base #{band.base})"
    end
  end
end
