# frozen_string_literal: true

module Sessions
  # The shape an attachment descriptor has to keep when a turn is written down
  # and picked up again.
  #
  # An attachment reaches a turn as a plain Hash — `{ path:, media_type: }` for
  # an image, `{ path:, original_filename:, size: }` for a file — and
  # AgentSessionJob reads those out of its own job arguments and nowhere else.
  # Two durable stores hold them for a turn that has not run yet: the
  # `enqueued_messages` row a queued follow-up sits in, and the spot-hold record
  # on `sessions.metadata`. Both are jsonb, and jsonb hands a Hash back with
  # STRING keys — while the CLI adapters index it with SYMBOLS
  # (`image[:path]` in ClaudeCliAdapter#build_message_json).
  #
  # A descriptor that goes through one of those columns unconverted therefore
  # comes back looking present and reading empty: the turn is enqueued
  # `images: [{ "path" => ... }]`, the adapter asks for `image[:path]`, and the
  # agent answers a prompt about a screenshot it cannot see. That is the same
  # silent failure the stores exist to prevent, wearing the other face — so the
  # round trip is named once here, in both directions, rather than re-derived at
  # each store.
  #
  # == A descriptor without a path is not a descriptor
  #
  # `path` is the only field either consumer can do anything with: it is what
  # the adapter base64-encodes and what the file note tells the agent to read.
  # An entry without one is dropped rather than passed on, because handing the
  # adapter a `nil` path is how a turn arrives carrying an attachment that is
  # not there.
  class AttachmentDescriptors
    IMAGE_KEYS = %i[path media_type].freeze
    FILE_KEYS = %i[path original_filename size].freeze

    # Ready to hand to AgentSessionJob and the adapters below it: symbol keys,
    # anything the consumers do not read dropped.
    #
    # @param raw [Object] whatever the store gave back
    # @param keys [Array<Symbol>] IMAGE_KEYS or FILE_KEYS
    # @return [Array<Hash>, nil] nil when nothing usable is left, so a caller can
    #   pass it straight to an `images:` keyword that means "none" by absence
    def self.for_a_job(raw, keys:)
      normalize(raw, keys) { |key| key }
    end

    # Ready to write into a jsonb column: string keys, so what comes back out is
    # what went in rather than whatever indifference the column happened to
    # apply, and unknown keys dropped so a store never grows a field no reader
    # asks for.
    #
    # @return [Array<Hash>, nil]
    def self.for_the_record(raw, keys:)
      normalize(raw, keys, &:to_s)
    end

    # @yieldparam key [Symbol] returns the key to write, symbol or string
    def self.normalize(raw, keys)
      return nil if raw.blank?

      Array(raw).filter_map do |entry|
        next unless entry.is_a?(Hash) || entry.is_a?(ActionController::Parameters)
        next if value_for(entry, :path).blank?

        keys.each_with_object({}) do |key, acc|
          value = value_for(entry, key)
          acc[yield(key)] = value unless value.nil?
        end
      end.presence
    end
    private_class_method :normalize

    # Read a key however the entry happens to be spelling it. A descriptor comes
    # from a job argument (symbols), a jsonb column (strings) or a request
    # (ActionController::Parameters), and this class exists precisely because
    # those three do not agree.
    def self.value_for(entry, key)
      string = entry[key.to_s]
      string.nil? ? entry[key.to_sym] : string
    end
    private_class_method :value_for
  end
end
