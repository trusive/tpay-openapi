require "test_helper"

module Tpay
  module Openapi
    class ResultTest < Minitest::Test
      CREATED = {
        "result" => "success", "requestId" => "r1", "transactionId" => "01ABC", "title" => "TR-ABC-123456",
        "transactionPaymentUrl" => "https://secure.sandbox.tpay.com/?title=TR-ABC-123456", "status" => "pending"
      }.freeze

      FAILED = {
        "result" => "failed", "requestId" => "r2",
        "errors" => [
          { "errorCode" => "field_required", "errorMessage" => "Object payer is required", "fieldName" => "payer" },
          { "errorCode" => "too_low", "errorMessage" => "amount Is too low", "fieldName" => "" }
        ]
      }.freeze

      def test_a_successful_response
        result = Result.new(CREATED, status_code: 200)

        assert_predicate result, :success?
        assert_equal CREATED, result.record
        assert_equal [CREATED], result.records
        assert_equal "01ABC", result.transaction_id
        assert_equal "TR-ABC-123456", result.title
        assert_equal CREATED["transactionPaymentUrl"], result.payment_url
        assert_equal "pending", result.transaction_status
        assert_equal "r1", result.request_id
        assert_empty result.errors
        assert_same CREATED, result.raw
      end

      def test_a_failed_response
        result = Result.new(FAILED, status_code: 400)

        refute_predicate result, :success?
        assert_nil result.record
        assert_empty result.records
        assert_nil result.transaction_id
        assert_equal ["payer: Object payer is required (field_required)", "amount Is too low (too_low)"], result.errors
        assert_equal %w[field_required too_low], result.error_codes
        assert_equal 400, result.status_code
      end

      def test_a_2xx_that_reports_failed_is_not_a_success
        refute_predicate Result.new(FAILED, status_code: 200), :success?
      end

      def test_settled_counts_paid_and_correct
        assert_predicate Result.new(CREATED.merge("status" => "paid"), status_code: 200), :settled?
        assert_predicate Result.new(CREATED.merge("status" => "correct"), status_code: 200), :settled?
        refute_predicate Result.new(CREATED, status_code: 200), :settled?
        refute_predicate Result.new(CREATED.merge("status" => "refund"), status_code: 200), :settled?
      end

      def test_tolerates_a_missing_or_odd_body
        assert_empty Result.new(nil, status_code: 204).errors
        assert_empty Result.new({ "errors" => "nope" }, status_code: 400).errors
      end
    end
  end
end
