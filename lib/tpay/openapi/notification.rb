require "uri"

module Tpay
  module Openapi
    # Tpay's payment notifications (webhooks): verifying, reading and
    # acknowledging them.
    #
    #   Tpay::Openapi::Notification.verify!(raw_body: request.raw_post,
    #                                       jws_header: request.headers["X-JWS-Signature"],
    #                                       env: :sandbox)
    #   payment = Tpay::Openapi::Notification.parse(request.raw_post,
    #                                               content_type: request.content_type)
    #   render plain: Tpay::Openapi::Notification.acknowledgement
    #
    # Verify first, then parse: nothing in an unverified body can be trusted.
    module Notification
      # The body Tpay expects back, with HTTP 200. Anything else makes Tpay
      # resend the notification; HTTP 404 stops the resending altogether.
      ACKNOWLEDGEMENT = "TRUE".freeze

      # The content type of transaction notifications.
      FORM = "application/x-www-form-urlencoded".freeze

      class << self
        # Verifies the X-JWS-Signature of a notification.
        #
        # @param raw_body [String] the request body exactly as received, before
        #   any parsing (`request.raw_post`, `request.body.read`)
        # @param jws_header [String, nil] the X-JWS-Signature header
        # @param env [Symbol] `:sandbox` or `:production`; decides the only
        #   certificate host accepted
        # @param fetcher [#fetch] certificate source; {default_fetcher} unless
        #   given
        # @param trust_anchors [Array<OpenSSL::X509::Certificate>, nil] trust
        #   these instead of the environment's root bundle
        # @return [true]
        # @raise [SignatureError] for any reason the signature cannot be
        #   verified
        def verify!(raw_body:, jws_header:, env:, fetcher: default_fetcher, trust_anchors: nil)
          Verifier.new(env: env, fetcher: fetcher, trust_anchors: trust_anchors)
                  .verify!(raw_body: raw_body, jws_header: jws_header)
        end

        # {verify!} as a boolean.
        # @return [Boolean]
        def valid?(**options)
          verify!(**options)
        rescue SignatureError
          false
        end

        # Reads a transaction notification. Only the form-encoded format Tpay
        # uses for transaction notifications is supported.
        #
        # @param raw_body [String]
        # @param content_type [String] the request's Content-Type
        # @return [Payment]
        # @raise [ArgumentError] for another content type, or a body missing
        #   the fields every transaction notification carries
        def parse(raw_body, content_type:)
          media_type = content_type.to_s.split(";").first.to_s.strip.downcase
          unless media_type == FORM
            raise ArgumentError, "unsupported notification content type #{content_type.inspect}; " \
                                 "transaction notifications are #{FORM}"
          end

          Payment.from_params(URI.decode_www_form(raw_body.to_s).to_h)
        end

        # @return [String] the response body that acknowledges a notification
        def acknowledgement
          ACKNOWLEDGEMENT
        end

        # The process-wide certificate cache: {CachingFetcher} over
        # {HttpFetcher}, 24-hour TTL.
        # @return [#fetch]
        def default_fetcher
          @default_fetcher || DEFAULT_FETCHER_LOCK.synchronize { @default_fetcher ||= CachingFetcher.new }
        end

        # Replaces the process-wide certificate source, e.g. with a
        # CachingFetcher of a different TTL.
        attr_writer :default_fetcher
      end

      DEFAULT_FETCHER_LOCK = Mutex.new
      private_constant :DEFAULT_FETCHER_LOCK
    end
  end
end
