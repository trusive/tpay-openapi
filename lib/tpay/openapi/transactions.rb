module Tpay
  module Openapi
    # Transactions resource: create a payment, read its status back, refund it.
    # See docs/api-notes.md, "Endpoints", for the sources of every field.
    class Transactions
      # Only PLN is in the API's currency enum.
      CURRENCY = "PLN".freeze

      # Payer keys this library accepts, mapped to the API's names. `email`
      # and `name` are required by the API.
      PAYER_FIELDS = {
        email: "email", name: "name", phone: "phone", address: "address",
        code: "code", city: "city", country: "country", tax_id: "taxId",
        ip: "ip", user_agent: "userAgent"
      }.freeze

      # Transaction ids are ULIDs or `ta_…`; nothing outside this set may
      # reach the request path.
      ID = /\A[A-Za-z0-9_-]+\z/

      # @param client [Client]
      def initialize(client)
        @client = client
      end

      # POST /transactions.
      #
      # @param amount [BigDecimal, String] see {Amount.build}
      # @param description [String] shown to the payer (Tpay allows 128
      #   characters)
      # @param hidden_description [String] your order id; comes back as
      #   `tr_crc` in the notification
      # @param payer [Hash] `email:` and `name:` required; optional `phone:`,
      #   `address:`, `code:`, `city:`, `country:`, `tax_id:`, `ip:`,
      #   `user_agent:`
      # @param success_url [String] where Tpay sends the payer afterwards
      # @param error_url [String] where Tpay sends the payer on failure
      # @param notification_url [String] where Tpay posts the notification.
      #   Takes effect only if the POS allows overriding the result URL.
      # @param group_id [Integer, nil] bank group to preselect
      # @param channel_id [Integer, nil] payment channel to preselect; not
      #   together with group_id
      # @return [Result] `transaction_id`, `title`, `payment_url` on success
      # @raise [ArgumentError] for a malformed amount, payer or channel choice,
      #   before anything is sent
      def create(amount:, description:, hidden_description:, payer:,
                 success_url:, error_url:, notification_url:, group_id: nil, channel_id: nil)
        body = {
          "amount" => Amount.build(amount),
          "currency" => CURRENCY,
          "description" => description,
          "hiddenDescription" => hidden_description,
          "payer" => build_payer(payer),
          "callbacks" => {
            "payerUrls" => { "success" => success_url, "error" => error_url },
            "notification" => { "url" => notification_url }
          }
        }
        pay = build_pay(group_id, channel_id)
        body["pay"] = pay if pay
        @client.request(:post, "/transactions", body)
      end

      # GET /transactions/{id}. The way to find out what happened to a payment
      # whose notification never arrived.
      #
      # TODO(unverified): whether Tpay also accepts the `TR-…` title here
      # (docs/api-notes.md, unverified item 3). Store the transaction_id from
      # {#create}.
      #
      # @param transaction_id [String]
      # @return [Result] `transaction_status`, `settled?`; a 404 for an
      #   unknown id is a Result with `success? == false`
      def get(transaction_id)
        @client.request(:get, "/transactions/#{path_id(transaction_id)}")
      end

      # POST /transactions/{id}/refunds. A full refund moves the transaction
      # to `refund` and triggers a notification with `tr_status=chargeback`;
      # a partial one changes neither, even once the partial refunds add up to
      # the full amount.
      #
      # @param transaction_id [String]
      # @param amount [BigDecimal, String, nil] nil refunds the whole amount
      # @return [Result]
      def refund(transaction_id, amount: nil)
        body = amount.nil? ? {} : { "amount" => Amount.build(amount) }
        @client.request(:post, "/transactions/#{path_id(transaction_id)}/refunds", body)
      end

      private

      def build_payer(payer)
        raise ArgumentError, "payer must be a Hash" unless payer.is_a?(Hash)

        unknown = payer.keys.map(&:to_sym) - PAYER_FIELDS.keys
        raise ArgumentError, "unknown payer keys: #{unknown.join(", ")}" unless unknown.empty?

        built = payer.to_h { |key, value| [PAYER_FIELDS.fetch(key.to_sym), value] }.compact
        %w[email name].each do |required|
          raise ArgumentError, "payer #{required} is required" if built[required].to_s.empty?
        end
        built
      end

      # TODO(unverified): whether Tpay accepts a transaction with no `pay`
      # at all (docs/api-notes.md, unverified item 2). Every documented example
      # sends one; without group_id or channel_id this sends none.
      def build_pay(group_id, channel_id)
        if group_id && channel_id
          raise ArgumentError, "pass group_id or channel_id, not both (Tpay: channel_passed_with_group)"
        end

        return { "groupId" => Integer(group_id) } if group_id
        return { "channelId" => Integer(channel_id) } if channel_id

        nil
      end

      def path_id(transaction_id)
        id = transaction_id.to_s
        raise ArgumentError, "invalid transaction id #{transaction_id.inspect}" unless id.match?(ID)

        id
      end
    end
  end
end
