require "uri"

module Tpay
  module Openapi
    module Notification
      # Fields the docs say always appear and this library relies on.
      REQUIRED_FIELDS = %w[tr_id tr_status tr_crc tr_amount].freeze

      # A transaction notification, as {Notification.parse} reads it. Values
      # are the Strings Tpay posted, never converted - in particular amounts
      # stay text, so `BigDecimal(payment.amount)` is exact.
      #
      # Field sources: docs/api-notes.md, "Notifications".
      #
      # TODO(unverified): the exact tr_amount and tr_date formats
      # (docs/api-notes.md, unverified item 6). Both are kept as sent rather
      # than parsed against a guessed format.
      Payment = Data.define(
        :merchant_id, :title, :status, :amount, :paid_amount, :currency,
        :hidden_description, :description, :payer_email, :date, :test_mode, :raw
      ) do
        # @param params [Hash{String => String}] the decoded form
        # @return [Payment]
        # @raise [ArgumentError] when a required field is missing
        def self.from_params(params)
          missing = REQUIRED_FIELDS.select { |name| params[name].to_s.empty? }
          raise ArgumentError, "notification is missing #{missing.join(", ")}" unless missing.empty?

          new(
            merchant_id: params["id"], title: params["tr_id"], status: params["tr_status"],
            amount: params["tr_amount"], paid_amount: params["tr_paid"], currency: params["tr_currency"],
            hidden_description: params["tr_crc"], description: params["tr_desc"],
            payer_email: params["tr_email"], date: params["tr_date"],
            test_mode: params["test_mode"] == "1", raw: params.freeze
          )
        end

        # The id that stays the same across resends of one transaction's
        # notification - the `TR-…` title. Record payments idempotently by
        # this (or by hidden_description, which is your own order id).
        alias_method :transaction_title, :title

        # TODO(unverified): the letter case of tr_status (docs/api-notes.md,
        # unverified item 6); compared case-insensitively.
        # @return [Boolean] a successful payment
        def paid?
          status.to_s.casecmp?("true")
        end

        # @return [Boolean] a full refund (Tpay calls it chargeback; it is
        #   not a bank chargeback)
        def refunded?
          status.to_s.casecmp?("chargeback")
        end

        alias_method :test_mode?, :test_mode

        # Leaves out the payer's email, which is personal data.
        def inspect
          "#<#{self.class.name} title=#{title.inspect} status=#{status.inspect} " \
            "amount=#{amount.inspect} hidden_description=#{hidden_description.inspect}>"
        end
      end
    end
  end
end
