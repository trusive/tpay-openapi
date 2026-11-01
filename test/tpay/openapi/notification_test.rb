require "test_helper"

module Tpay
  module Openapi
    class NotificationTest < Minitest::Test
      FORM = "application/x-www-form-urlencoded".freeze

      # As documented under "Notification parameters".
      PARAMS = {
        "id" => "1010", "tr_id" => "TR-ABC-123456", "tr_date" => "2026-11-01 12:00:00",
        "tr_crc" => "order-42", "tr_amount" => "123.00", "tr_paid" => "123.00",
        "tr_desc" => "Pakiet AML", "tr_status" => "TRUE", "tr_error" => "none",
        "tr_email" => "jan@example.com", "tr_currency" => "PLN",
        "md5sum" => "d41d8cd98f00b204e9800998ecf8427e", "test_mode" => "0"
      }.freeze

      def body(overrides = {})
        URI.encode_www_form(PARAMS.merge(overrides).compact)
      end

      def teardown
        Notification.default_fetcher = nil
        super
      end

      def test_acknowledgement_is_the_body_tpay_expects
        assert_equal "TRUE", Notification.acknowledgement
      end

      def test_parse_reads_the_fields_the_application_needs
        payment = Notification.parse(body, content_type: FORM)

        assert_equal "TR-ABC-123456", payment.title
        assert_equal "TR-ABC-123456", payment.transaction_title
        assert_equal "TRUE", payment.status
        assert_predicate payment, :paid?
        refute_predicate payment, :refunded?
        assert_equal "123.00", payment.amount
        assert_equal "123.00", payment.paid_amount
        assert_equal "PLN", payment.currency
        assert_equal "order-42", payment.hidden_description
        assert_equal "jan@example.com", payment.payer_email
        assert_equal "1010", payment.merchant_id
        assert_equal "2026-11-01 12:00:00", payment.date
        refute_predicate payment, :test_mode?
        assert_equal PARAMS, payment.raw
      end

      def test_parse_keeps_amounts_as_the_exact_text_sent
        assert_equal "0.10", Notification.parse(body("tr_amount" => "0.10"), content_type: FORM).amount
      end

      def test_parse_accepts_a_content_type_with_parameters_and_any_case
        payment = Notification.parse(body, content_type: "Application/X-WWW-Form-Urlencoded; charset=UTF-8")

        assert_equal "order-42", payment.hidden_description
      end

      def test_status_is_compared_case_insensitively
        assert_predicate Notification.parse(body("tr_status" => "true"), content_type: FORM), :paid?
      end

      def test_a_full_refund_is_refunded_not_paid
        payment = Notification.parse(body("tr_status" => "CHARGEBACK"), content_type: FORM)

        assert_predicate payment, :refunded?
        refute_predicate payment, :paid?
      end

      def test_test_mode
        assert_predicate Notification.parse(body("test_mode" => "1"), content_type: FORM), :test_mode?
      end

      def test_parse_refuses_json
        error = assert_raises(ArgumentError) { Notification.parse("{}", content_type: "application/json") }

        assert_match(/unsupported notification content type/, error.message)
      end

      def test_parse_refuses_a_body_missing_required_fields
        error = assert_raises(ArgumentError) do
          Notification.parse(body("tr_id" => nil, "tr_crc" => nil), content_type: FORM)
        end

        assert_match(/missing tr_id, tr_crc/, error.message)
      end

      def test_inspect_leaves_out_the_payer_email
        refute_includes Notification.parse(body, content_type: FORM).inspect, "jan@example.com"
      end

      def test_the_default_fetcher_is_one_shared_cache
        assert_instance_of Notification::CachingFetcher, Notification.default_fetcher
        assert_same Notification.default_fetcher, Notification.default_fetcher
      end

      # Tpay's real, public certificate files as served on 2026-11-01. No
      # Tpay signature is available offline, so the check is that each
      # environment's chain validates (verification gets as far as the
      # signature) and that each refuses the other's certificate.
      def real_files
        %w[secure.sandbox.tpay.com secure.tpay.com].each_with_object({}) do |host, files|
          %w[notifications-jws.pem tpay-jws-root.pem].each do |name|
            files["https://#{host}/x509/#{name}"] = TestPki.fixture("#{host}_#{name}")
          end
        end
      end

      def verify_with_real_certificates(env, leaf_host)
        host = TestPki::HOSTS.fetch(env)
        files = real_files.merge(
          "https://#{host}/x509/notifications-jws.pem" => real_files["https://#{leaf_host}/x509/notifications-jws.pem"]
        )
        header_b64 = TestPki.base64url(JSON.generate("alg" => "RS256", "x5u" => "https://#{host}/x509/notifications-jws.pem"))
        assert_raises(SignatureError) do
          Notification.verify!(raw_body: body, jws_header: "#{header_b64}..#{TestPki.base64url("x" * 256)}",
                               env: env, fetcher: Drivers::Fake::CertificateFiles.new(files))
        end
      end

      def test_real_sandbox_certificates_chain
        assert_match(/signature does not match/,
                     verify_with_real_certificates(:sandbox, "secure.sandbox.tpay.com").message)
      end

      def test_real_production_certificates_chain
        assert_match(/signature does not match/, verify_with_real_certificates(:production, "secure.tpay.com").message)
      end

      def test_real_sandbox_certificate_does_not_chain_to_the_production_bundle
        assert_match(/does not chain/, verify_with_real_certificates(:production, "secure.sandbox.tpay.com").message)
      end

      def test_real_production_certificate_does_not_chain_to_the_sandbox_bundle
        assert_match(/does not chain/, verify_with_real_certificates(:sandbox, "secure.tpay.com").message)
      end
    end
  end
end
