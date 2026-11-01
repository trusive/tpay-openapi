module Tpay
  module Openapi
    # Holds one OAuth access token in memory until shortly before it expires.
    #
    # Tpay asks integrations not to fetch a token per request and warns that
    # the lifetime "may change", so the expiry comes from each response's
    # `expires_in`, measured on the local monotonic clock from when the token
    # was received. The server's `issued_at` is ignored, so clock skew
    # between the two machines does not matter.
    #
    # Thread-safe: concurrent callers that find no valid token wait on one
    # fetch rather than each making their own.
    class TokenCache
      # Seconds before expiry at which a token stops being used.
      DEFAULT_MARGIN = 60

      # @param fetcher [#call] returns the parsed token response Hash
      #   (`access_token`, `expires_in`); raises on failure
      # @param margin [Numeric] seconds of safety margin
      # @param clock [#call] monotonic seconds, injectable for tests
      def initialize(fetcher:, margin: DEFAULT_MARGIN,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @fetcher = fetcher
        @margin = margin
        @clock = clock
        @mutex = Mutex.new
        @token = nil
        @expires_at = nil
      end

      # @return [String] a token valid for at least the margin, fetching one
      #   if needed
      def token
        @mutex.synchronize do
          refresh! unless fresh?
          @token
        end
      end

      # Drops the token if it is still the one given, so that of several
      # threads that all saw the same 401, one refetches and the rest reuse
      # its result.
      # @param stale [String]
      def invalidate(stale)
        @mutex.synchronize do
          @token = @expires_at = nil if @token == stale
        end
      end

      # Never shows the token.
      def inspect
        "#<#{self.class.name} token=#{@token ? "[FILTERED]" : "nil"}>"
      end

      private

      def fresh?
        @token && @clock.call < @expires_at
      end

      def refresh!
        response = @fetcher.call
        access_token = response["access_token"]
        unless access_token.is_a?(String) && !access_token.empty?
          raise AuthError.new("Tpay: token response carried no access_token", status_code: 200)
        end

        @token = access_token
        @expires_at = @clock.call + usable_lifetime(response["expires_in"])
      end

      # A lifetime shorter than twice the margin is used for half its length
      # instead, so a short-lived token is still used at all.
      def usable_lifetime(expires_in)
        lifetime = Integer(expires_in || 7200, exception: false) || 7200
        lifetime > @margin * 2 ? lifetime - @margin : lifetime / 2.0
      end
    end
  end
end
