require "test_helper"

module Tpay
  module Openapi
    module Drivers
      class FakeTest < Minitest::Test
        ATTRS = {
          amount: "123.00", description: "Pakiet AML", hidden_description: "order-42",
          payer: { email: "jan@example.com", name: "Jan Kowalski" },
          success_url: "https://staging.example.com/paid", error_url: "https://staging.example.com/failed",
          notification_url: "https://staging.example.com/tpay/notifications"
        }.freeze

        def setup
          @fake = Fake.new
          @client = Client.new(driver: @fake)
        end

        def create(**overrides)
          @client.transactions.create(**ATTRS, **overrides)
        end

        def test_create_answers_like_the_api
          result = create

          assert_predicate result, :success?
          assert_equal 200, result.status_code
          assert_match(/\A01FAKE\d{20}\z/, result.transaction_id)
          assert_match(/\ATR-FAK-\d{6}\z/, result.title)
          assert_equal "https://secure.sandbox.tpay.com/?title=#{result.title}", result.payment_url
          assert_equal "pending", result.transaction_status
          assert_in_delta 123.0, result.record["amount"]
          assert_equal "order-42", result.record["hiddenDescription"]
        end

        def test_get_returns_what_create_stored
          created = create
          fetched = @client.transactions.get(created.transaction_id)

          assert_predicate fetched, :success?
          assert_equal created.title, fetched.title
          assert_equal "pending", fetched.transaction_status
          refute_predicate fetched, :settled?
          assert_nil fetched.record["date"]["realization"]
        end

        def test_get_of_an_unknown_id_is_a_failed_result
          result = @client.transactions.get("01UNKNOWN")

          refute_predicate result, :success?
          assert_equal 404, result.status_code
          assert_equal ["transaction_does_not_exist"], result.error_codes
        end

        def test_records_every_request_with_the_exact_json
          create

          request = @fake.requests.last

          assert_equal :post, request.http_method
          assert_equal "/transactions", request.path
          assert_includes request.json, '"amount":123.00'
          assert_equal "order-42", request.body["hiddenDescription"]
        end

        def test_pay_settles_the_transaction
          created = create
          @fake.pay!(created.transaction_id)

          fetched = @client.transactions.get(created.transaction_id)

          assert_predicate fetched, :settled?
          refute_nil fetched.record["date"]["realization"]
          assert_nil fetched.record["payments"]["attempts"].last["paymentErrorCode"]
        end

        def test_pay_builds_a_notification_that_verifies_and_parses
          created = create
          delivery = @fake.pay!(created.transaction_id)

          assert Notification.verify!(raw_body: delivery.raw_body, jws_header: delivery.headers["X-JWS-Signature"],
                                      env: :sandbox, fetcher: @fake.certificate_fetcher)
          payment = Notification.parse(delivery.raw_body, content_type: delivery.headers["Content-Type"])

          assert_predicate payment, :paid?
          assert_equal created.title, payment.title
          assert_equal "order-42", payment.hidden_description
          assert_equal "123.00", payment.amount
          assert_equal "jan@example.com", payment.payer_email
        end

        def test_the_notification_verifies_with_trust_anchors_too
          delivery = @fake.pay!(create.transaction_id)

          assert Notification.valid?(raw_body: delivery.raw_body, jws_header: delivery.jws_header, env: :sandbox,
                                     fetcher: @fake.certificate_fetcher, trust_anchors: @fake.trust_anchors)
        end

        def test_the_notification_does_not_verify_against_real_tpay_certificates
          delivery = @fake.pay!(create.transaction_id)

          refute Notification.valid?(raw_body: delivery.raw_body, jws_header: delivery.jws_header, env: :sandbox,
                                     fetcher: @fake.certificate_fetcher,
                                     trust_anchors: [OpenSSL::X509::Certificate.new(
                                       TestPki.fixture("secure.sandbox.tpay.com_tpay-jws-root.pem")
                                     )])
        end

        def test_a_production_fake_signs_for_the_production_host_only
          fake = Fake.new(env: :production)
          delivery = fake.pay!(Client.new(driver: fake).transactions.create(**ATTRS).transaction_id)

          assert Notification.valid?(raw_body: delivery.raw_body, jws_header: delivery.jws_header,
                                     env: :production, fetcher: fake.certificate_fetcher)
          refute Notification.valid?(raw_body: delivery.raw_body, jws_header: delivery.jws_header,
                                     env: :sandbox, fetcher: fake.certificate_fetcher)
        end

        def test_md5sum_follows_the_documented_formula_with_an_empty_code
          created = create
          payment = Notification.parse(@fake.pay!(created.transaction_id).raw_body, content_type: Notification::FORM)

          assert_equal Digest::MD5.hexdigest("1010#{created.title}123.00order-42"), payment.raw["md5sum"]
        end

        def test_paying_twice_is_an_argument_error
          created = create
          @fake.pay!(created.transaction_id)

          assert_raises(ArgumentError) { @fake.pay!(created.transaction_id) }
          assert_raises(ArgumentError) { @fake.pay!("01UNKNOWN") }
        end

        def test_fail_records_an_attempt_and_leaves_the_transaction_pending
          created = create

          assert_nil @fake.fail!(created.transaction_id)
          fetched = @client.transactions.get(created.transaction_id)

          assert_equal "pending", fetched.transaction_status
          assert_equal "101", fetched.record["payments"]["attempts"].last["paymentErrorCode"]
        end

        def test_a_failed_transaction_can_still_be_paid
          created = create
          @fake.fail!(created.transaction_id)

          assert_instance_of Fake::Delivery, @fake.pay!(created.transaction_id)
        end

        def test_full_refund_moves_the_status_to_refund
          created = create
          @fake.pay!(created.transaction_id)

          result = @client.transactions.refund(created.transaction_id)

          assert_predicate result, :success?
          assert_equal "refund", result.transaction_status
          assert_equal "{}", @fake.requests.last.json
        end

        def test_partial_refund_leaves_the_status_alone
          created = create
          @fake.pay!(created.transaction_id)

          result = @client.transactions.refund(created.transaction_id, amount: "23.00")

          assert_equal "correct", result.transaction_status
          assert_in_delta 23.0, result.record["refundsList"].last["amount"]
          assert_equal '{"amount":23.00}', @fake.requests.last.json
        end

        def test_refunding_twice_fails_with_already_refunded
          created = create
          @fake.pay!(created.transaction_id)
          @client.transactions.refund(created.transaction_id)

          assert_equal ["already_refunded"], @client.transactions.refund(created.transaction_id).error_codes
        end

        def test_refunding_an_unpaid_transaction_fails
          result = @client.transactions.refund(create.transaction_id)

          refute_predicate result, :success?
          assert_equal ["cannot_create_refund"], result.error_codes
        end

        def test_fail_next_applies_once
          @fake.fail_next!(code: 503)

          assert_raises(ServiceUnavailableError) { create }
          assert_predicate create, :success?
        end

        def test_fail_always_applies_until_reset
          @fake.fail_always!(code: 429)

          2.times { assert_raises(RateLimitError) { create } }
          @fake.reset!

          assert_predicate create, :success?
        end

        def test_a_failing_call_is_still_recorded
          @fake.fail_next!(code: :connection)

          assert_raises(ConnectionError) { create }
          assert_equal 1, @fake.requests.size
        end

        def test_an_armed_tpay_error_code_arrives_as_a_failed_result
          @fake.fail_next!(code: "crc_not_unique")
          result = create

          refute_predicate result, :success?
          assert_equal 400, result.status_code
          assert_equal ["crc_not_unique"], result.error_codes
        end

        def test_refuses_an_unknown_failure_kind
          assert_raises(ArgumentError) { @fake.fail_next!(code: 1.5) }
        end

        def test_reset_clears_requests_transactions_and_failures
          created = create
          @fake.fail_always!(code: 500)
          @fake.reset!

          assert_empty @fake.requests
          assert_nil @fake.transaction(created.transaction_id)
          assert_predicate create, :success?
        end

        def test_refuses_routes_it_does_not_simulate
          assert_raises(ArgumentError) { @fake.request(:get, "/refunds") }
        end

        def test_transaction_returns_an_independent_copy
          created = create
          @fake.transaction(created.transaction_id)["status"] = "paid"

          assert_equal "pending", @fake.transaction(created.transaction_id)["status"]
        end

        # Every code the README documents, answered by the Fake and by the HTTP
        # driver over webmock: the same exception, or the same failed Result.
        PARITY = [401, 403, 405, 429, 500, 502, 503, 504, 400, 404, 409,
                  "invalid_request_body", "incorrect_content_type", "internal_server_error",
                  "crc_not_unique"].freeze

        def outcome
          result = yield
          [:result, result.success?, result.status_code, result.error_codes]
        rescue Error => e
          [:raised, e.class]
        end

        def http_outcome(code)
          driver = Http.new(client_id: "id", client_secret: "secret")
          stub_request(:post, "https://openapi.sandbox.tpay.com/oauth/auth")
            .to_return(body: { "access_token" => "t", "expires_in" => 7200 }.to_json)
          status, body = Fake.new.send(:failure, code)
          stub_request(:post, "https://openapi.sandbox.tpay.com/transactions")
            .to_return(status: status, body: JSON.generate(body))
          outcome { driver.request(:post, "/transactions", {}) }
        end

        PARITY.each do |code|
          define_method(:"test_fake_and_http_agree_on_#{code}") do
            @fake.fail_next!(code: code)
            fake = outcome { @fake.request(:post, "/transactions", {}) }

            assert_equal http_outcome(code), fake
          end
        end
      end
    end
  end
end
