module Tpay
  module Openapi
    # One Tpay response.
    #
    # Tpay answers with a single JSON object: the transaction itself on
    # success, `{result: "failed", requestId:, errors: [...]}` otherwise. An
    # outcome about the data sent - validation errors, an unknown id - is a
    # Result with `success? == false`; anything that aborts the request is
    # raised instead (see {Status}).
    #
    # Amounts in {#raw} and {#record} are whatever JSON parsing gives,
    # i.e. Floats. Two-decimal amounts survive that exactly as text, so
    # `BigDecimal(record["amount"].to_s)` is the exact value.
    class Result
      # @return [Hash] the parsed response body
      attr_reader :raw
      # @return [Integer] the HTTP status
      attr_reader :status_code

      # Statuses meaning the payer's money is with the merchant.
      # TODO(unverified): which of the two a settled payment reports
      # (docs/api-notes.md, unverified item 4). Both count, so a settled
      # transaction is never read as unsettled.
      SETTLED = %w[paid correct].freeze

      # @param raw [Hash, nil]
      # @param status_code [Integer]
      def initialize(raw, status_code:)
        @raw = raw.is_a?(Hash) ? raw : {}
        @status_code = status_code
      end

      # @return [Boolean] a 2xx that does not report `result: "failed"`
      def success?
        (200..299).cover?(status_code) && raw["result"] != "failed"
      end

      # The returned object (the transaction, for every v0.1.0 call), or nil
      # when the call failed.
      # @return [Hash, nil]
      def record
        success? ? raw : nil
      end

      # @return [Array<Hash>] {#record} as a list - empty on failure
      def records
        record ? [record] : []
      end

      # Errors from the body, each as "fieldName: errorMessage (errorCode)".
      # @return [Array<String>]
      def errors
        error_nodes.map do |node|
          text = [node["fieldName"], node["errorMessage"] || node["devMessage"]]
                 .compact.reject { |part| part.to_s.empty? }.join(": ")
          code = node["errorCode"]
          code.to_s.empty? ? text : "#{text} (#{code})"
        end
      end

      # Tpay's machine-readable codes, e.g. `["crc_not_unique"]`.
      # @return [Array<String>]
      def error_codes
        error_nodes.filter_map { |node| node["errorCode"] }
      end

      # @return [String, nil] Tpay's requestId, for support tickets
      def request_id
        raw["requestId"]
      end

      # @return [String, nil] the id {Transactions#get} and
      #   {Transactions#refund} take - a ULID or `ta_…`, not the title
      def transaction_id
        record&.fetch("transactionId", nil)
      end

      # @return [String, nil] the `TR-…` title, which is what notifications
      #   carry as `tr_id`
      def title
        record&.fetch("title", nil)
      end

      # @return [String, nil] where to redirect the payer, on create
      def payment_url
        record&.fetch("transactionPaymentUrl", nil)
      end

      # @return [String, nil] `pending`, `paid`, `correct`, `refund`,
      #   `canceled`
      def transaction_status
        record&.fetch("status", nil)
      end

      # @return [Boolean] whether {#transaction_status} means the money is in
      def settled?
        SETTLED.include?(transaction_status)
      end

      private

      def error_nodes
        nodes = raw["errors"]
        nodes.is_a?(Array) ? nodes.grep(Hash) : []
      end
    end
  end
end
