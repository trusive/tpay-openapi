require "net/http"
require "openssl"
require "uri"
require "json"

module Tpay
  module Openapi
    module Drivers
      # Real transport: JSON over HTTPS to the Open API, authorized with an
      # OAuth client_credentials token held in a {TokenCache}.
      #
      # A 401 is answered once by refetching the token and repeating the
      # request; a second 401 raises {AuthError}. Nothing else is retried.
      class Http
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 30

        USER_AGENT = "tpay-openapi-ruby/#{VERSION} (+https://github.com/trusive/tpay-openapi)".freeze

        # @return [Environment::Settings]
        attr_reader :environment

        # @param client_id [String]
        # @param client_secret [String]
        # @param env [Symbol] `:sandbox` (default) or `:production`
        # @param open_timeout [Numeric] seconds
        # @param read_timeout [Numeric] seconds
        # @param token_margin [Numeric] seconds before expiry at which the
        #   token is refreshed
        # @raise [ArgumentError] when a credential is missing
        def initialize(client_id:, client_secret:, env: Environment::DEFAULT,
                       open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
                       token_margin: TokenCache::DEFAULT_MARGIN)
          raise ArgumentError, "client_id is required" if client_id.to_s.empty?
          raise ArgumentError, "client_secret is required" if client_secret.to_s.empty?

          @client_id = client_id
          @client_secret = client_secret
          @environment = Environment.fetch(env)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @tokens = TokenCache.new(fetcher: -> { fetch_token }, margin: token_margin)
        end

        # @param method [Symbol] `:get` or `:post`
        # @param path [String] e.g. "/transactions"
        # @param body [Hash, nil] serialized as JSON
        # @return [Result]
        def request(method, path, body = nil)
          json = body.nil? ? nil : JSON.generate(body)
          token = @tokens.token
          response = perform(method, path, json, token)

          if response.code.to_i == 401
            @tokens.invalidate(token)
            response = perform(method, path, json, @tokens.token)
          end

          Status.handle(response.code.to_i, response.body)
        end

        # Never shows the credentials or the token.
        def inspect
          "#<#{self.class.name} env=#{@environment.name} client_id=[FILTERED] client_secret=[FILTERED]>"
        end

        private

        def perform(method, path, json, token)
          uri = URI.join(@environment.api_url, path)
          request = build_request(method, uri, json)
          request["Authorization"] = "Bearer #{token}"
          send_request(uri, request)
        end

        def build_request(method, uri, json)
          request = case method
                    when :get then Net::HTTP::Get.new(uri)
                    when :post then Net::HTTP::Post.new(uri)
                    else raise ArgumentError, "unsupported HTTP method #{method.inspect}"
                    end
          request["Accept"] = "application/json"
          request["User-Agent"] = USER_AGENT
          if json
            request["Content-Type"] = "application/json"
            request.body = json
          end
          request
        end

        # POST /oauth/auth, form-encoded as the Authorization guide shows.
        # TODO(unverified): the status a rejected login answers with
        # (docs/api-notes.md, unverified item 1). Any non-2xx is read as
        # rejected credentials, except where Status raises something more
        # specific (429, 5xx).
        def fetch_token
          uri = URI.join(@environment.api_url, "/oauth/auth")
          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json"
          request["User-Agent"] = USER_AGENT
          request.set_form_data("client_id" => @client_id, "client_secret" => @client_secret)

          response = send_request(uri, request)
          token_response(response.code.to_i, response.body)
        end

        def token_response(status_code, body)
          if (400..499).cover?(status_code) && status_code != 429
            raise AuthError.new("Tpay: token request rejected - check client_id/client_secret " \
                                "and the environment (HTTP #{status_code})", status_code: status_code)
          end

          Status.handle(status_code, body).raw
        end

        def send_request(uri, request)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.request(request)
        rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
          raise ConnectionError, "Tpay request failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
