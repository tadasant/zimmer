# frozen_string_literal: true

module Webhooks
  # Inbound deliveries from an external provider — the one surface in Zimmer that answers
  # requests nobody on the tailnet made.
  #
  # Outside /api on purpose. Api::BaseController authenticates with Zimmer's own API key, which
  # a provider does not have; a webhook authenticates with the provider's signature over the raw
  # body instead, and every subclass checks it before it reads anything else. ActionController::API
  # rather than ::Base because there is no browser and no session here, so there is nothing for
  # CSRF protection to protect.
  #
  # A subclass follows one order, and the order is the security property:
  #
  #   1. inert unless the source is switched on and has a secret (Webhooks::Source#accepting?)
  #   2. refuse an oversized body without reading it
  #   3. verify the signature over the raw bytes
  #   4. only then parse JSON, and only then act on it
  #
  # Rails would otherwise parse a JSON body before any of that: the request instrumentation reads
  # `filtered_parameters` for its log line, and ParamsWrapper reads the body to wrap it, both
  # before the action runs. ParamsWrapper is switched off and #process_action stops the other, so
  # the first thing to parse the body is step 4.
  class BaseController < ActionController::API
    # Provider event payloads are a few kilobytes. The cap exists so an unauthenticated caller
    # cannot make this action HMAC an arbitrarily large body.
    MAX_BODY_BYTES = 1.megabyte

    wrap_parameters false

    # Hand Rails an empty params hash before anything asks for one. The instrumentation runs
    # inside the super call, and a request whose parameters are already set is never parsed. The
    # body stays readable through `request.raw_post`, which is all a subclass reads.
    def process_action(*)
      request.request_parameters = {}
      super
    end

    private

    # At most MAX_BODY_BYTES + 1 bytes, however the body arrives. A Content-Length lets
    # #body_too_large? refuse without reading at all; a chunked body carries none, so the read
    # itself is bounded, and one byte past the cap is enough to know it is over.
    def raw_body
      @raw_body ||= begin
        io = request.body
        io.rewind if io.respond_to?(:rewind)
        io.read(MAX_BODY_BYTES + 1).to_s
      end
    end

    def body_too_large?
      request.content_length.to_i > MAX_BODY_BYTES || raw_body.bytesize > MAX_BODY_BYTES
    end

    # Step 4: only ever called after the signature has verified.
    def parse_payload
      JSON.parse(raw_body)
    rescue JSON::ParserError
      nil
    end

    # 404, as if the route did not exist: a switched-off source has nothing to say to anyone,
    # including whether it exists. INFO, because a disabled endpoint being probed is not news.
    def render_inert(source)
      Rails.logger.info("[Webhooks] #{source.name} webhook is not accepting deliveries (mode #{source.mode}); answered 404")
      head :not_found
    end

    # WARN rather than ERROR: an unsigned or stale request is a client-side condition, and one
    # ERROR line pages (see ApplicationJob). WARN still reaches the log pipeline, which is where
    # a misconfigured signing secret shows up as a run of these.
    def reject(status, source, reason)
      Rails.logger.warn("[Webhooks] Rejected a #{source.name} delivery from #{request.remote_ip}: #{reason}")
      head status
    end
  end
end
