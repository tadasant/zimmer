# frozen_string_literal: true

module LiveConversations
  # The one way LiveSetting is written — by the settings page, the REST API, the
  # MCP tools and the live model's own `update_live_settings` function alike —
  # so all four meet the same checks and every write lands in the history.
  #
  # A bad write must not be able to break Live Mode, whoever makes it:
  #
  # - an unknown setting, or a model, voice or mode that is not on the list, is
  #   refused and nothing is saved;
  # - a number outside its range is clamped to the nearest end, and the answer
  #   says so;
  # - the guidance has a length cap.
  #
  # And should OpenAI still refuse what was saved, the text path and the voice
  # path both retry on the defaults rather than fail (TextReply, RealtimeSession).
  #
  # Blank (nil, "", or "default") puts a setting back on its default. `reset`
  # does that for every setting, and leaves the guidance alone: the guidance is
  # somebody's writing, not a knob, and has its own history to restore from.
  class SettingsUpdate
    class Invalid < StandardError; end

    Actor = Data.define(:kind, :label, :live_conversation) do
      def self.human(label) = new(kind: LiveSettingChange::HUMAN, label: label, live_conversation: nil)
      def self.agent(label, live_conversation: nil) = new(kind: LiveSettingChange::AGENT, label: label, live_conversation: live_conversation)
    end

    Result = Data.define(:setting, :change, :notes) do
      def changed? = !change.nil?
      def keys = change ? change.changeset.keys : []

      # Something an open voice call can take now, in a `session.update`.
      def mid_call_changed?
        keys.any? { |key| key == "guidance" || LiveSetting::MID_CALL_KEYS.include?(key.to_sym) }
      end

      # One line per change, in words — what the live model says back, and what
      # the history shows.
      def summary
        return "Nothing changed." unless changed?

        lines = change.changeset.map do |key, (before, after)|
          if key == "guidance"
            SettingsUpdate.describe_guidance_change(before, after)
          else
            field = LiveSetting.field(key)
            "#{field.label}: #{SettingsUpdate.describe_value(field, before)} → #{SettingsUpdate.describe_value(field, after)}"
          end
        end
        (lines + notes).join("\n")
      end
    end

    BLANK_VALUES = [ nil, "", "default" ].freeze

    def self.call(attributes, actor:, reset: false) = new(attributes, actor: actor, reset: reset).call

    def self.describe_value(field, raw)
      return "default (#{field.default.nil? ? 'not set' : field.default})" if raw.nil?

      raw.to_s
    end

    def self.describe_guidance_change(before, after)
      before = before.to_s
      after = after.to_s
      return "Guidance cleared (was #{before.length} characters)." if after.empty?
      return "Guidance written (#{after.length} characters)." if before.empty?
      return "Guidance appended: “#{after.delete_prefix(before).strip.truncate(300)}”" if after.start_with?(before)

      "Guidance rewritten (#{before.length} → #{after.length} characters)."
    end

    # @param attributes [Hash] setting keys (LiveSetting::KEYS) to values, plus
    #   optionally `guidance` (replaces it) or `append_guidance` (adds a line)
    def initialize(attributes, actor:, reset: false)
      @attributes = (attributes || {}).to_h.transform_keys(&:to_s)
      @actor = actor
      @reset = reset
      @notes = []
    end

    # @return [Result]
    # @raise [Invalid] naming every problem; nothing is saved
    def call
      values = normalize
      setting = LiveSetting.editable
      change = nil

      setting.with_lock do
        changeset = {}
        values.each do |key, value|
          if key == "append_guidance"
            key = "guidance"
            value = [ setting.guidance_text, value ].compact_blank.join("\n")
            # Re-checked under the lock: a concurrent append may have grown it.
            if value.length > LiveSetting::GUIDANCE_MAX_LENGTH
              raise Invalid, "Appending that would take the guidance past its #{LiveSetting::GUIDANCE_MAX_LENGTH}-character limit; rewrite it shorter instead."
            end
          end
          before = key == "guidance" ? setting.guidance_text : setting[key]
          next if before == value

          changeset[key] = [ before, value ]
          setting[key] = value
        end

        if changeset.any?
          setting.updated_by = actor_label
          setting.save!
          change = LiveSettingChange.create!(
            changeset: changeset, actor_kind: @actor.kind, actor: @actor.label.to_s.truncate(200),
            live_conversation: @actor.live_conversation
          )
          # Shipped, so a setting the live model moved on its own (Listening,
          # turn detection) is in the same logs as the call it changed.
          Rails.logger.warn(
            "[LiveSettings] #{actor_label.squish} changed " +
            changeset.except("guidance").map { |key, (before, after)| "#{key}: #{before.inspect} → #{after.inspect}" }
              .push(*("guidance" if changeset.key?("guidance"))).join(", ")
          )
        end
      end

      Result.new(setting: setting, change: change, notes: @notes)
    end

    private

    def actor_label
      [ @actor.kind, @actor.label ].join(": ").truncate(255)
    end

    # @return [Hash{String => Object}] column (or guidance) → value to store
    def normalize
      errors = []
      values = {}

      LiveSetting::KEYS.each { |key| values[key.to_s] = nil } if @reset

      @attributes.each do |key, raw|
        case key
        when "guidance", "append_guidance"
          text = raw.to_s.gsub("\r\n", "\n").strip
          next errors << "#{key} must be text." unless raw.nil? || raw.is_a?(String)
          next if key == "append_guidance" && text.empty?

          values[key] = text
        else
          field = LiveSetting::FIELDS_BY_KEY[key.to_sym]
          next errors << "Unknown setting #{key.inspect}. Settings: #{LiveSetting::KEYS.join(', ')}, guidance, append_guidance." if field.nil?

          begin
            values[key] = normalize_value(field, raw)
          rescue Invalid => e
            errors << e.message
          end
        end
      end

      if values.key?("guidance") && values.key?("append_guidance")
        errors << "Pass guidance (to replace it) or append_guidance (to add to it), not both."
      end
      max = LiveSetting::GUIDANCE_MAX_LENGTH
      errors << "Guidance is limited to #{max} characters." if values["guidance"].to_s.length > max
      if values["append_guidance"] && LiveSetting.current.guidance_text.length + 1 + values["append_guidance"].length > max
        errors << "Appending that would take the guidance past its #{max}-character limit; rewrite it shorter instead."
      end

      raise Invalid, errors.join(" ") if errors.any?

      values
    end

    def normalize_value(field, raw)
      raw = raw.strip if raw.is_a?(String)
      return nil if BLANK_VALUES.include?(raw)

      if field.enum?
        options = LiveSetting.options_for(field)
        value = raw.to_s
        return value if options.key?(value)

        raise Invalid, "#{field.label}: #{value.inspect} is not one of #{options.keys.join(', ')}."
      end

      number = begin
        Float(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      raise Invalid, "#{field.label} must be a number between #{field.min} and #{field.max}." unless number&.finite?

      number = number.round if field.type == :integer
      clamped = number.clamp(field.min, field.max)
      @notes << "#{field.label}: #{raw} is outside #{field.min}–#{field.max}, so it was set to #{clamped}." if clamped != number
      clamped
    end
  end
end
