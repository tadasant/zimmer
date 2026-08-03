# Helpers for tests that exercise the MCP OAuth token endpoint.
module McpOauthTestHelpers
  # Intercepts the POST a token grant makes, for the duration of the block.
  #
  # `McpOauthCredential#refresh!` posts its refresh grant through
  # `McpOauthService#post_form` — the same bounded path the initial exchange uses,
  # rather than the unbounded `Net::HTTP.post_form` — so the seam to stub is the
  # service, not Net::HTTP.
  #
  # @param response [Object] the response to return, or a callable invoked with
  #   (uri, params) — use a callable to capture the posted params or to raise a
  #   network error.
  # @return [Hash, nil] the params posted during the block
  def stub_token_post(response)
    captured_params = nil
    service = McpOauthService.new
    handler = lambda do |uri, params|
      captured_params = params
      response.respond_to?(:call) ? response.call(uri, params) : response
    end

    service.stub(:post_form, handler) do
      McpOauthService.stub(:new, service) do
        yield
      end
    end

    captured_params
  end
end
