# frozen_string_literal: true

# Tells apart a request a human asked for from one the browser issued on its own
# initiative, speculatively, because the cursor drifted over a link.
#
# Turbo Drive prefetches same-origin links on `mouseenter` and has done so by
# default since Turbo 8 (`config/importmap.rb` pins turbo-rails 2.x). That makes
# "hovering" a network event, and two parts of the app have to care:
#
#   - SessionsController must not count a hover as a human viewing a session;
#   - Supervisor::ApplicationController must not answer a hover with a Basic-auth
#     challenge, which the browser turns into a sign-in dialog over a page the
#     human never tried to leave.
module SpeculativeRequest
  extend ActiveSupport::Concern

  # Turbo sends `X-Sec-Purpose: prefetch` — JavaScript may not set a `Sec-`
  # prefixed header, so it uses the `X-` spelling. A browser prefetching on its
  # own (speculation rules, `<link rel=prefetch>`) sends the real `Sec-Purpose:
  # prefetch`; Chrome sent the pre-standard `Purpose: prefetch` for years and
  # still does for some prefetch paths.
  PREFETCH_HEADERS = %w[X-Sec-Purpose Sec-Purpose Purpose].freeze

  private

  # True when the browser fetched this speculatively rather than because someone
  # asked for it. Header-based and therefore advisory: a client that sends
  # nothing is treated as a real request, which is the safe direction to be
  # wrong in — it means we under-suppress, never under-serve.
  def prefetch_request?
    PREFETCH_HEADERS.any? { |header| request.headers[header].to_s.include?("prefetch") }
  end
end
