# frozen_string_literal: true

require "json"
require "faraday"
require "faraday/retry"
require "faraday_middleware"
require "rainbow"
require "addressable"

require "zoho_hub/response"

module ZohoHub
  class Connection
    class << self
      def infer_api_domain
        case ZohoHub.configuration.api_domain
        when "https://accounts.zoho.com" then "https://www.zohoapis.com"
        when "https://accounts.zoho.com.cn" then "https://www.zohoapis.com.cn"
        when "https://accounts.zoho.in" then "https://www.zohoapis.in"
        when "https://accounts.zoho.eu" then "https://www.zohoapis.eu"
        else DEFAULT_DOMAIN
        end
      end
    end

    attr_accessor :debug, :access_token, :expires_in, :api_domain, :refresh_token

    # This is a block to be run when the token is refreshed. This way you can do whatever you want
    # with the new parameters returned by the refresh method.
    attr_accessor :on_refresh_cb

    DEFAULT_DOMAIN = "https://www.zohoapis.com"

    BASE_PATH = "/crm/v8/"

    def initialize(access_token: nil, api_domain: nil, expires_in: 3600, refresh_token: nil)
      @refresh_mutex = Mutex.new
      @access_token = access_token
      @expires_in = expires_in
      @api_domain = api_domain || self.class.infer_api_domain
      @refresh_token ||= refresh_token # do not overwrite if it's already set
    end

    def base_adapter
      Faraday.new(url: base_url) do |conn|
        conn.headers = authorization_header if access_token?
        configure_retry(conn)
        conn.adapter Faraday.default_adapter
      end
    end

    def get_binary(path, params = {})
      response = with_refresh { base_adapter.get(path, params) }
      if response.status >= 400
        error = error_response(response)
        raise ZohoAPIError, error.msg || "Zoho download failed (HTTP #{response.status})"
      end
      response
    end

    def get(path, params = {})
      log "GET #{path} with #{params}"

      response = with_refresh { adapter.get(path, params) }
      response.body
    end

    def post(path, params = {})
      log "POST #{path} with #{params}"

      response = with_refresh { adapter.post(path, params) }
      response.body
    end

    def put(path, params = {})
      log "PUT #{path} with #{params}"

      response = with_refresh { adapter.put(path, params) }
      response.body
    end

    def delete(path, params = {})
      log "DELETE #{path} with #{params}"

      response = with_refresh { adapter.delete(path, params) }
      response.body
    end

    def access_token?
      @access_token
    end

    def refresh_token?
      @refresh_token
    end

    def log(text)
      return unless ZohoHub.configuration.debug?

      puts Rainbow("[ZohoHub] #{text}").magenta.bright
    end

    private

    def with_refresh
      request_token = @access_token
      http_response = yield

      response = error_response(http_response)

      # Try to refresh the token and try again
      if (response.invalid_token? || response.authentication_failure?) && refresh_token?
        log "Refreshing outdated token"
        @refresh_mutex.synchronize do
          if @access_token == request_token
            params = ZohoHub::Auth.refresh_token(@refresh_token)
            raise InvalidTokenError, "Zoho token refresh failed" unless params[:access_token]

            @on_refresh_cb&.call(params)
            @access_token = params[:access_token]
          end
        end

        http_response = yield
      elsif response.authentication_failure?
        raise ZohoAPIError, response.msg
      end

      if http_response.status == 429 || http_response.status >= 500
        raise ZohoAPIError, "Zoho request failed (HTTP #{http_response.status})"
      end

      http_response
    end

    def error_response(http_response)
      body = http_response.body
      if body.is_a?(String) && http_response.status >= 400
        begin
          body = JSON.parse(body, symbolize_names: true)
        rescue JSON::ParserError
          body = {}
        end
      end
      Response.new(body.is_a?(Hash) ? body : {})
    end

    def configure_retry(conn)
      conn.request :retry, max: 3, interval: 0.5, interval_randomness: 0.5,
        backoff_factor: 2, max_interval: 30, methods: [:get, :head],
        retry_statuses: [429, 500, 502, 503, 504],
        retry_if: ->(env, _) { env.method == :post && env.url.path.end_with?("/coql") }
    end

    def base_url
      Addressable::URI.join(@api_domain, BASE_PATH).to_s
    end

    # The authorization header that must be added to every request for authorized requests.
    def authorization_header
      {"Authorization" => "Zoho-oauthtoken #{@access_token}"}
    end

    def adapter
      Faraday.new(url: base_url) do |conn|
        conn.headers = authorization_header if access_token?
        conn.use FaradayMiddleware::EncodeJson
        conn.response :json, content_type: /\bjson$/, parser_options: {symbolize_names: true}
        configure_retry(conn)
        conn.adapter Faraday.default_adapter
      end
    end
  end
end
