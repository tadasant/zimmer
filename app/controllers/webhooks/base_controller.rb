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
  # Nothing here calls `params`, which would parse the body before step 3.
  class BaseController < ActionController::API
    # Provider event payloads are a few kilobytes. The cap exists so an unauthenticated caller
    # cannot make this action HMAC an arbitrarily large body.
    MAX_BODY_BYTES = 1.megabyte

    private

    def raw_body
      @raw_body ||= request.raw_post.to_s
    end

    def body_too_large?
      request.content_length.to_i > MAX_BODY_BYTES || raw_body.bytesize > MAX_BODY_BYTES
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
