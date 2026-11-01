module Tpay
  module Openapi
    # Base class of everything this library raises.
    #
    # Every subclass answers {#retryable?}, so a job can decide whether to
    # reschedule without knowing the hierarchy. The library itself never
    # retries: when and how often is the application's call.
    class Error < StandardError
      # @return [Boolean] whether sending the same request again later can
      #   succeed without anything being changed first
      def retryable?
        false
      end
    end

    # Network failure, timeout, or a response that is not parseable at all.
    #
    # Retryable, with one caveat for {Transactions#create}: a timeout after
    # the request was sent may still have created the transaction. Tpay
    # rejects a second one with the same hidden description
    # (`crc_not_unique`) when the POS enforces it, so a retry that answers
    # with that code means the first attempt landed.
    class ConnectionError < Error
      def retryable?
        true
      end
    end

    # A response Tpay sent that aborts the request. Outcomes about the data
    # sent - a 400 with field errors, a 404 for an id that does not exist -
    # are not raised; they arrive as a {Result} with `success? == false`.
    class ApiError < Error
      # @return [Integer, nil] the HTTP status
      attr_reader :status_code
      # @return [Array<String>] errors from the response body, if any
      attr_reader :errors
      # @return [String, nil] Tpay's requestId, for support tickets
      attr_reader :request_id

      # @param message [String]
      # @param status_code [Integer, nil]
      # @param errors [Array<String>]
      # @param request_id [String, nil]
      def initialize(message, status_code: nil, errors: [], request_id: nil)
        super(message)
        @status_code = status_code
        @errors = errors
        @request_id = request_id
      end
    end

    # HTTP 401 (after one retry with a fresh token) or 403, or a rejected
    # client_id / client_secret. Fix the credentials or the key's scope.
    class AuthError < ApiError; end

    # The request itself is wrong (405, an unexpected 4xx, or Tpay could not
    # decode the body). Sending it again unchanged fails the same way.
    class RequestError < ApiError; end

    # HTTP 429. Back off and retry later.
    class RateLimitError < ApiError
      def retryable?
        true
      end
    end

    # HTTP 502, 503, 504. Tpay or something in front of it is temporarily
    # unavailable.
    class ServiceUnavailableError < ApiError
      def retryable?
        true
      end
    end

    # HTTP 500 and other 5xx, or Tpay's `internal_server_error` code. Usually
    # transient, so retryable; the same caveat about {Transactions#create} as
    # for {ConnectionError} applies.
    class ServerError < ApiError
      def retryable?
        true
      end
    end

    # A notification whose X-JWS-Signature could not be verified, for any
    # reason: missing or malformed header, wrong algorithm, a certificate URL
    # outside Tpay's host, a certificate that does not chain to Tpay's CA or
    # is out of its validity period, a signature that does not match the
    # body, or a failure fetching the certificates at all.
    #
    # Not an ApiError: no API call was made. Never act on the notification.
    # Answer it with a non-200, non-404 status, so Tpay resends it later;
    # 404 stops Tpay's resending.
    class SignatureError < Error; end
  end
end
