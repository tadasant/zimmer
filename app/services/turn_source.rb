# frozen_string_literal: true

# Where one turn delivered to an agent session came from, and how it was produced:
# the Zimmer iOS app by voice, a Live Mode voice call, the web app's composer, a
# Slack trigger, another agent. Zimmer renders it as a short note at the end of
# the turn the agent receives, so the agent can match its reply to the medium — a
# few plain sentences for a voice call, full markdown for a typed request.
#
# == A style hint, never an authorization signal
#
# A client can claim any modality it likes: the iOS app's header saying "this was
# dictated" is the app's word, and nothing checks it. So nothing may gate a
# permission, a merge, a scope or a spend on this value, and the agent-facing
# explanation says the same. Who is speaking is a different question with a
# different answer — HumanMessage, written by HumanMessageCapture from the
# authenticated actor at the input boundary — and this class does not touch it.
#
# == What a source holds
#
# Allowlisted values only. `surface` and `modality` are enum keys; the client
# version is digits and dots; the Live conversation id is an integer. Anything a
# client sends that is not on a list is dropped, never echoed, so no free text,
# user agent, device identifier, IP or location reaches the note or the row.
#
# == Why the note is signed
#
# The note rides inside the prompt string, which is what lets it survive every
# path a turn takes on its way to the agent — the durable `pending_follow_up_prompt`
# stamp, a spot-gate requeue, a SIGTERM retry — without threading a second value
# through each one. The cost is that prompt text is untrusted: a follow-up, a
# GitHub comment or a Slack message could contain something shaped like a note.
#
# So #annotate first neutralizes every lookalike in the text, then appends the
# note with an HMAC over its own fields AND that text. AgentSessionJob runs every
# prompt it delivers through TurnSource.finalize, which keeps each note whose
# signature verifies against the text in front of it and neutralizes every other
# lookalike — so text can neither forge a note nor lift a real one off another
# turn. A genuine note is appended in its final form, so finalize leaves a tagged
# prompt byte-for-byte unchanged: the job's replay guards compare a stored prompt
# against the delivered one by prefix, and depend on that.
TurnSource = Data.define(:surface, :modality, :client_version, :live_conversation_id) do
  # surface key => how the note names it.
  surface_labels = {
    "web" => "the Zimmer web app",
    "ios" => "the Zimmer iOS app",
    "carplay" => "Zimmer on CarPlay",
    "browser_extension" => "the Zimmer browser extension",
    "api" => "the Zimmer REST API",
    "mcp" => "an MCP client",
    "slack" => "Slack, via a Zimmer trigger",
    "email" => "email, via a Zimmer trigger",
    "whatsapp" => "WhatsApp, via a Zimmer trigger",
    "trigger" => "a Zimmer trigger",
    "agent" => "another agent session",
    "unknown" => "an unidentified client"
  }.freeze
  const_set(:SURFACE_LABELS, surface_labels)
  const_set(:SURFACES, surface_labels.keys.freeze)

  # Surfaces whose words software wrote rather than a person typing or speaking
  # into a client. Their note says so, so an agent never reads a router's
  # follow-up or a scheduled prompt as a person waiting on the other end.
  const_set(:MACHINE_SURFACES, %w[trigger agent].freeze)

  modality_labels = {
    "text" => "typed",
    "voice_dictation" => "voice dictation",
    "live_voice" => "Live Mode, voice",
    "live_text" => "Live Mode, typed",
    "unknown" => nil
  }.freeze
  const_set(:MODALITY_LABELS, modality_labels)
  const_set(:MODALITIES, modality_labels.keys.freeze)

  # The modalities a client may claim in a header. The Live ones are derived by
  # the server from the conversation a delegation came out of, never accepted
  # from a request.
  const_set(:CLIENT_CLAIMABLE_MODALITIES, %w[text voice_dictation].freeze)

  # One line on what the modality implies for the reply. Style only, never scope.
  const_set(:HINTS, {
    "live_voice" => "the reply is likely to be read aloud: a few short, plain sentences; no markdown, tables or code blocks.",
    "live_text" => "relayed by the Live Mode assistant from a quick chat: keep anything you report back brief.",
    "voice_dictation" => "spoken and transcribed, so expect transcription slips; markdown is fine in the reply.",
    "text" => "full markdown is fine."
  }.freeze)

  const_set(:TAG, "zimmer-turn-source")
  const_set(:VERSION_PATTERN, /\A\d{1,5}(?:\.\d{1,5}){0,3}\z/)
  # "<surface>/<version>", e.g. "ios/1.4.2" or "carplay/1.4.2". Only refines a
  # native-app request; see .from_request.
  const_set(:CLIENT_HEADER, "X-Zimmer-Client")
  const_set(:MODALITY_HEADER, "X-Zimmer-Input-Modality")

  # A note as #annotate writes it. Attribute values are allowlisted, so the
  # pattern can afford to be strict; the label is checked against the one the
  # fields render, not trusted.
  const_set(:NOTE_PATTERN, %r{\n\n<zimmer-turn-source (?<attrs>(?:[a-z_]+="[0-9a-z_.]*" )*)sig="(?<sig>[0-9a-f]{32})">[^<\n]*</zimmer-turn-source>})

  def initialize(surface: "unknown", modality: "unknown", client_version: nil, live_conversation_id: nil)
    surface = surface.to_s
    modality = modality.to_s
    version = client_version.to_s.strip
    live_id = live_conversation_id.to_s.strip

    super(
      surface: TurnSource::SURFACES.include?(surface) ? surface : "unknown",
      modality: TurnSource::MODALITIES.include?(modality) ? modality : "unknown",
      client_version: version.match?(TurnSource::VERSION_PATTERN) ? version : nil,
      live_conversation_id: live_id.match?(/\A[1-9]\d{0,17}\z/) ? live_id.to_i : nil
    )
  end

  class << self
    # A stored hash back into a source. Tolerant of anything — a row written by a
    # later build, a hand-edited column — because a bad value must degrade to
    # "unknown", never raise in the delivery path.
    #
    # @return [TurnSource, nil] nil when there is nothing stored
    def from_h(hash)
      return nil unless hash.is_a?(Hash) && hash.present?

      h = hash.stringify_keys
      new(surface: h["surface"], modality: h["modality"], client_version: h["client_version"],
          live_conversation_id: h["live_conversation_id"])
    end

    # The source of an HTTP request at a boundary that already knows its surface:
    # the web controllers pass "web", Api::V1 passes "ios" on the app's bearer
    # token and "api" otherwise.
    #
    # The two headers can only REFINE that answer, never replace it:
    #   * `X-Zimmer-Client: carplay/…` turns an `ios` request into `carplay` (the
    #     same app, another screen), and the version is kept when it parses. Any
    #     other value is ignored, so a fleet API key cannot pass itself off as the
    #     iOS app.
    #   * `X-Zimmer-Input-Modality` is honoured for `text` and `voice_dictation`,
    #     on a surface a person types or speaks into. Anything else is dropped.
    #
    # @param default_modality [String] what to assume without a modality header:
    #   "text" for the web composer, which has no voice input; "unknown" for an API
    #   caller or an app build that sends nothing.
    def from_request(request, surface:, default_modality: "unknown")
      headers = request.respond_to?(:headers) ? request.headers : {}
      client_surface, client_version = parse_client_header(headers[TurnSource::CLIENT_HEADER])
      surface = "carplay" if surface == "ios" && client_surface == "carplay"
      client_version = nil unless %w[ios carplay].include?(surface) && %w[ios carplay].include?(client_surface)

      claimed = headers[TurnSource::MODALITY_HEADER].to_s.strip.downcase
      claimable = TurnSource::CLIENT_CLAIMABLE_MODALITIES.include?(claimed) && !TurnSource::MACHINE_SURFACES.include?(surface)

      new(surface: surface, modality: claimable ? claimed : default_modality, client_version: client_version)
    end

    # A delegation the Live Mode model made on a person's behalf. The modality is
    # the conversation's when the tool runs; the surface is whichever client last
    # drove the conversation.
    def for_live_conversation(conversation)
      new(
        surface: conversation.client_surface.presence || "unknown",
        modality: conversation.voice? ? "live_voice" : "live_text",
        live_conversation_id: conversation.id
      )
    end

    # A turn a trigger delivers, keyed off the genesis its condition type maps to.
    # Slack, email and WhatsApp are people writing on another surface, relayed;
    # everything else a trigger fires on is automation.
    def for_genesis(genesis)
      case genesis.to_s
      when SessionGenesis::SLACK then new(surface: "slack", modality: "text")
      when SessionGenesis::EMAIL then new(surface: "email", modality: "text")
      when SessionGenesis::WHATSAPP then new(surface: "whatsapp", modality: "text")
      else new(surface: "trigger")
      end
    end

    def agent = new(surface: "agent")

    # Keep every note in `prompt` whose signature verifies against the text in
    # front of it, and neutralize every other lookalike. AgentSessionJob calls
    # this on every prompt it delivers, tagged or not — which is what stops prompt
    # text forging a note on the paths that never call #annotate.
    #
    # @return [String] the prompt, unchanged when it carries only genuine notes
    def finalize(prompt)
      return prompt if prompt.blank? || !prompt.match?(/#{TurnSource::TAG}/io)

      out = +""
      cursor = 0
      prompt.to_enum(:scan, TurnSource::NOTE_PATTERN).each do
        match = Regexp.last_match
        next unless genuine?(match)

        out << neutralize(prompt[cursor...match.begin(0)]) << match[0]
        cursor = match.end(0)
      end
      out << neutralize(prompt[cursor..])
    end

    # Replace the angle brackets of anything shaped like a note's tag with
    # lookalikes, so a reader still sees the text but no agent takes it for
    # Zimmer's. Line-bounded: a mention with no closing `>` defuses itself, not
    # every `<` up to the next one further down the message.
    def neutralize(text)
      text.to_s.gsub(%r{<\s*/?\s*#{TurnSource::TAG}\b[^>\n]*>?}io) { |tag| tag.tr("<>", "‹›") }
    end

    # `text` with every genuine note removed and nothing else touched — the words
    # the caller sent. For comparing a delivered prompt with a stored copy of the
    # same words (the queue, `sent_message`).
    def strip(text)
      return text if text.blank? || !text.include?(TurnSource::TAG)

      out = +""
      cursor = 0
      text.to_enum(:scan, TurnSource::NOTE_PATTERN).each do
        match = Regexp.last_match
        next unless genuine?(match)

        out << text[cursor...match.begin(0)]
        cursor = match.end(0)
      end
      out << text[cursor..]
    end

    # Split a delivered prompt that ENDS with a genuine note into the caller's
    # words and the source, so a prompt going back into the queue is stored the
    # way every other queued message is: `content` the words, `source_context`
    # the source. A prompt that does not end with one comes back whole, with nil.
    #
    # @return [Array(String, TurnSource or nil)]
    def extract(text)
      return [ text, nil ] if text.blank? || !text.include?(TurnSource::TAG)

      match = text.to_enum(:scan, TurnSource::NOTE_PATTERN).map { Regexp.last_match }.last
      return [ text, nil ] unless match && match.end(0) == text.length && genuine?(match)

      [ match.pre_match, from_h(match[:attrs].scan(/([a-z_]+)="([^"]*)"/).to_h) ]
    end

    def hmac_key
      @hmac_key ||= Rails.application.key_generator.generate_key("zimmer-turn-source-v1", 32)
    end

    private

    # Genuine when re-rendering the note from its own attributes, over the exact
    # text in front of it, reproduces it byte for byte: the canonical attributes,
    # the signature, and the readable line the fields imply.
    def genuine?(match)
      source = from_h(match[:attrs].scan(/([a-z_]+)="([^"]*)"/).to_h)
      return false if source.nil?

      ActiveSupport::SecurityUtils.secure_compare(source.signed_note(match.pre_match), match[0])
    end

    def parse_client_header(value)
      name, version = value.to_s.strip.downcase.split("/", 2)
      [ TurnSource::SURFACES.include?(name) ? name : nil, version ]
    end
  end

  # `text` with this source's note appended, ready for delivery. Lookalikes in the
  # text are neutralized first, because the signature covers the text exactly as
  # delivered. A blank text is returned as-is: there is no turn to describe.
  #
  # @return [String]
  def annotate(text)
    return text if text.blank?

    body = TurnSource.neutralize(text)
    body + signed_note(body)
  end

  # The note as appended after `body`, e.g.
  #
  #   <zimmer-turn-source surface="ios" modality="live_voice" live_conversation_id="12" sig="…">Sent from the Zimmer iOS app · Live Mode, voice — the reply is likely to be read aloud: …</zimmer-turn-source>
  def signed_note(body)
    attrs = to_h.map { |key, value| %(#{key}="#{value}" ) }.join
    %(\n\n<#{TurnSource::TAG} #{attrs}sig="#{signature_for(body)}">#{text}</#{TurnSource::TAG}>)
  end

  # The note's readable line.
  def text
    [ label, hint ].compact.join(" — ")
  end

  # "Sent from the Zimmer iOS app · voice dictation", "Written by another agent session".
  def label
    verb = machine? ? "Written by" : "Sent from"
    [ "#{verb} #{TurnSource::SURFACE_LABELS.fetch(surface)}", TurnSource::MODALITY_LABELS[modality] ].compact.join(" · ")
  end

  def hint
    return "machine-written, not a person; no reply style is implied." if machine?

    TurnSource::HINTS[modality]
  end

  def machine? = TurnSource::MACHINE_SURFACES.include?(surface)

  # The stored shape — the `source_context` columns and metadata["last_turn_source"]
  # — and the order a note writes its attributes in.
  def to_h
    { "surface" => surface, "modality" => modality, "client_version" => client_version,
      "live_conversation_id" => live_conversation_id }.compact
  end

  # What get_session and the REST API serialize.
  def as_json(*) = to_h.merge("label" => label)

  private

  def signature_for(body)
    payload = [ surface, modality, client_version, live_conversation_id, Digest::SHA256.hexdigest(body.to_s) ].join("|")
    OpenSSL::HMAC.hexdigest("SHA256", TurnSource.hmac_key, payload)[0, 32]
  end
end
