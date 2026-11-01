require "json"

module Tpay
  module Openapi
    # Turns an HTTP status and response body into a {Result} or an exception.
    # Both drivers go through here, so the Fake raises exactly what the real
    # driver raises for the same answer.
    #
    # A status that says something about the *data sent* - 400 validation
    # errors, 404 for an unknown id, 409 for a conflict - is a Result: the
    # body explains it and the caller decides. Anything else that is not a
    # 2xx aborts the request and is raised. See docs/api-notes.md, "HTTP status
    # codes", for the sources.
    module Status
      # Non-2xx statuses that arrive as a failed Result rather than raised.
      RESULT_STATUSES = [400, 404, 409].freeze

      # TODO(unverified): Tpay documents no 429 or 5xx; these follow
      # RFC 6585 / RFC 9110 (docs/api-notes.md, unverified item 5).
      RAISED = {
        401 => [AuthError, "authorization failed - check client_id/client_secret"],
        403 => [AuthError, "the API key's scope does not allow this operation"],
        429 => [RateLimitError, "rate limit exceeded"],
        502 => [ServiceUnavailableError, "bad gateway"],
        503 => [ServiceUnavailableError, "service unavailable"],
        504 => [ServiceUnavailableError, "gateway timeout"]
      }.freeze

      # Error codes that say nothing about the data sent. Two mean this
      # library built a request Tpay could not read; one is Tpay's own
      # failure, whatever status carried it.
      RAISED_CODES = {
        "invalid_request_body" => [RequestError, "Tpay could not decode the request body"],
        "incorrect_content_type" => [RequestError, "Tpay rejected the request content type"],
        "internal_server_error" => [ServerError, "internal Tpay error"]
      }.freeze

      module_function

      # @param status_code [Integer]
      # @param body [String, nil] the raw response body
      # @return [Result]
      # @raise [ApiError] for a status or error code that aborts the request
      # @raise [ConnectionError] for a body that is not a JSON object where
      #   one is needed
      def handle(status_code, body)
        status_code = Integer(status_code)
        parsed = parse(body)
        error = error_for(status_code, parsed)
        raise error if error

        # 204 No Content is a success with nothing to read; any other
        # unreadable body leaves the outcome unknown.
        unless parsed || (status_code == 204 && body.to_s.strip.empty?)
          raise ConnectionError, "Tpay returned a non-JSON response (HTTP #{status_code})"
        end

        Result.new(parsed, status_code: status_code)
      end

      # @return [ApiError, nil] the exception for this response, or nil when
      #   it belongs in a Result
      def error_for(status_code, parsed)
        result = Result.new(parsed, status_code: status_code)
        error_class, explanation = classify(status_code, result.error_codes)
        return nil unless error_class

        error_class.new(
          message_for(explanation, status_code, result.errors),
          status_code: status_code, errors: result.errors, request_id: result.request_id
        )
      end

      # @api private
      def classify(status_code, codes)
        code = codes.find { |candidate| RAISED_CODES.key?(candidate) }
        return RAISED_CODES[code] if code
        return nil if (200..299).cover?(status_code) || RESULT_STATUSES.include?(status_code)

        RAISED.fetch(status_code) { fallback(status_code) }
      end

      # @api private
      def fallback(status_code)
        case status_code
        when 400..499 then [RequestError, "request rejected"]
        when 500..599 then [ServerError, "Tpay server error"]
        else [ApiError, "unexpected HTTP status"]
        end
      end

      # @api private
      def parse(body)
        return nil if body.nil? || body.strip.empty?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      # @api private
      def message_for(explanation, status_code, errors)
        text = "Tpay: #{explanation} (HTTP #{status_code})"
        errors.empty? ? text : "#{text}: #{errors.join("; ")}"
      end
    end
  end
end
