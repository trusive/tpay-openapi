require "test_helper"

module Tpay
  module Openapi
    class StatusTest < Minitest::Test
      def failed_body(code: nil)
        errors = code ? [{ "errorCode" => code, "errorMessage" => "msg", "fieldName" => "field" }] : []
        JSON.generate("result" => "failed", "requestId" => "req-1", "errors" => errors)
      end

      # Every status and code the README's exception table lists.
      RAISED = {
        401 => AuthError, 403 => AuthError, 405 => RequestError, 415 => RequestError,
        422 => RequestError, 429 => RateLimitError, 500 => ServerError, 501 => ServerError,
        502 => ServiceUnavailableError, 503 => ServiceUnavailableError,
        504 => ServiceUnavailableError, 302 => ApiError
      }.freeze

      RAISED_CODES = {
        "invalid_request_body" => RequestError,
        "incorrect_content_type" => RequestError,
        "internal_server_error" => ServerError
      }.freeze

      RAISED.each do |status, error_class|
        define_method(:"test_http_#{status}_raises_#{error_class.name.split("::").last}") do
          error = assert_raises(error_class) { Status.handle(status, failed_body) }

          assert_instance_of error_class, error
          assert_equal status, error.status_code
          assert_equal "req-1", error.request_id
        end
      end

      RAISED_CODES.each do |code, error_class|
        define_method(:"test_error_code_#{code}_raises_#{error_class.name.split("::").last}") do
          error = assert_raises(error_class) { Status.handle(400, failed_body(code: code)) }

          assert_instance_of error_class, error
          assert_equal ["field: msg (#{code})"], error.errors
        end
      end

      [400, 404, 409].each do |status|
        define_method(:"test_http_#{status}_is_a_failed_result") do
          result = Status.handle(status, failed_body(code: "crc_not_unique"))

          refute_predicate result, :success?
          assert_equal status, result.status_code
          assert_equal ["crc_not_unique"], result.error_codes
        end
      end

      def test_a_2xx_is_a_result
        result = Status.handle(200, JSON.generate("result" => "success", "transactionId" => "01X"))

        assert_predicate result, :success?
        assert_equal "01X", result.transaction_id
      end

      def test_a_204_with_no_body_is_a_successful_result
        assert_predicate Status.handle(204, ""), :success?
      end

      def test_a_non_json_success_body_raises_connection_error
        assert_raises(ConnectionError) { Status.handle(200, "<html>") }
      end

      def test_a_non_json_400_raises_connection_error
        assert_raises(ConnectionError) { Status.handle(400, "<html>") }
      end

      def test_a_raised_status_is_raised_even_with_a_non_json_body
        assert_raises(ServiceUnavailableError) { Status.handle(503, "<html>Cloudflare</html>") }
      end

      def test_the_message_carries_status_and_errors
        error = assert_raises(RequestError) { Status.handle(400, failed_body(code: "invalid_request_body")) }

        assert_match(/HTTP 400.*field: msg \(invalid_request_body\)/, error.message)
      end

      def test_retryable_follows_the_exception_table
        assert_predicate ConnectionError.new, :retryable?
        assert_predicate RateLimitError.new("x"), :retryable?
        assert_predicate ServiceUnavailableError.new("x"), :retryable?
        assert_predicate ServerError.new("x"), :retryable?
        refute_predicate AuthError.new("x"), :retryable?
        refute_predicate RequestError.new("x"), :retryable?
        refute_predicate ApiError.new("x"), :retryable?
        refute_predicate SignatureError.new, :retryable?
      end
    end
  end
end
