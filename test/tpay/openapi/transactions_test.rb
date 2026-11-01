require "test_helper"
require "bigdecimal"

module Tpay
  module Openapi
    class TransactionsTest < Minitest::Test
      ATTRS = {
        amount: "199.00", description: "Pakiet AML Standard", hidden_description: "order-7",
        payer: { email: "jan@example.com", name: "Jan Kowalski" },
        success_url: "https://staging.example.com/paid", error_url: "https://staging.example.com/failed",
        notification_url: "https://staging.example.com/tpay/notifications"
      }.freeze

      def setup
        @fake = Drivers::Fake.new
        @transactions = Client.new(driver: @fake).transactions
      end

      def sent
        @fake.requests.last
      end

      def test_create_sends_the_documented_body
        @transactions.create(**ATTRS)

        assert_equal(
          '{"amount":199.00,"currency":"PLN","description":"Pakiet AML Standard",' \
          '"hiddenDescription":"order-7","payer":{"email":"jan@example.com","name":"Jan Kowalski"},' \
          '"callbacks":{"payerUrls":{"success":"https://staging.example.com/paid",' \
          '"error":"https://staging.example.com/failed"},' \
          '"notification":{"url":"https://staging.example.com/tpay/notifications"}}}',
          sent.json
        )
      end

      def test_create_accepts_a_big_decimal
        @transactions.create(**ATTRS, amount: BigDecimal("49.9"))

        assert_includes sent.json, '"amount":49.90'
      end

      def test_create_refuses_a_float_before_sending
        assert_raises(ArgumentError) { @transactions.create(**ATTRS, amount: 49.9) }
        assert_empty @fake.requests
      end

      def test_create_maps_optional_payer_fields
        @transactions.create(**ATTRS, payer: { email: "a@b.pl", name: "A", tax_id: "PL1234563218",
                                               user_agent: "UA", phone: nil, code: "00-001" })

        assert_equal({ "email" => "a@b.pl", "name" => "A", "taxId" => "PL1234563218",
                       "userAgent" => "UA", "code" => "00-001" }, sent.body["payer"])
      end

      def test_create_refuses_unknown_payer_keys
        error = assert_raises(ArgumentError) do
          @transactions.create(**ATTRS, payer: { email: "a@b.pl", name: "A", nip: "1" })
        end

        assert_match(/nip/, error.message)
      end

      def test_create_requires_payer_email_and_name
        assert_raises(ArgumentError) { @transactions.create(**ATTRS, payer: { name: "A" }) }
        assert_raises(ArgumentError) { @transactions.create(**ATTRS, payer: { email: "a@b.pl", name: "" }) }
      end

      def test_create_sends_a_group
        @transactions.create(**ATTRS, group_id: 150)

        assert_equal({ "groupId" => 150 }, sent.body["pay"])
      end

      def test_create_sends_a_channel
        @transactions.create(**ATTRS, channel_id: "64")

        assert_equal({ "channelId" => 64 }, sent.body["pay"])
      end

      def test_create_refuses_group_and_channel_together
        assert_raises(ArgumentError) { @transactions.create(**ATTRS, group_id: 150, channel_id: 64) }
      end

      def test_create_sends_no_pay_without_a_group_or_channel
        @transactions.create(**ATTRS)

        refute sent.body.key?("pay")
      end

      def test_get_requests_the_transaction_by_id
        @transactions.get("01K5BK4HEPB0WBCGT51FMTYSYJ")

        assert_equal [:get, "/transactions/01K5BK4HEPB0WBCGT51FMTYSYJ"], [sent.http_method, sent.path]
      end

      def test_ids_cannot_reach_outside_the_path
        ["../oauth/auth", "01X/refunds", "01X?x=1", "", nil].each do |id|
          assert_raises(ArgumentError, id.inspect) { @transactions.get(id) }
          assert_raises(ArgumentError, id.inspect) { @transactions.refund(id) }
        end
        assert_empty @fake.requests
      end

      def test_refund_without_an_amount_sends_an_empty_body
        @transactions.refund("01ABC")

        assert_equal [:post, "/transactions/01ABC/refunds", "{}"], [sent.http_method, sent.path, sent.json]
      end

      def test_refund_with_an_amount_sends_it
        @transactions.refund("01ABC", amount: "10.5")

        assert_equal '{"amount":10.50}', sent.json
      end

      def test_refund_refuses_a_float
        assert_raises(ArgumentError) { @transactions.refund("01ABC", amount: 10.5) }
      end
    end
  end
end
