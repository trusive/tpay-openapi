require "test_helper"

module Tpay
  module Openapi
    module Notification
      class VerifierTest < Minitest::Test
        BODY = "id=1010&tr_id=TR-ABC-123456&tr_crc=order-42&tr_amount=123.00&tr_status=TRUE".freeze

        def verify!(body: BODY, header: TestPki.sign(BODY), env: :sandbox, fetcher: TestPki.fetcher, **options)
          Notification.verify!(raw_body: body, jws_header: header, env: env, fetcher: fetcher, **options)
        end

        def assert_rejected(pattern, **options)
          error = assert_raises(SignatureError) { verify!(**options) }
          assert_match pattern, error.message
          error
        end

        def test_accepts_a_valid_signature
          assert verify!
        end

        def test_accepts_a_valid_production_signature
          header = TestPki.sign(BODY, signer: TestPki.leaf(:production), x5u: TestPki.leaf_url(:production))

          assert verify!(header: header, env: :production)
        end

        def test_accepts_the_payload_part_when_it_is_the_encoded_body
          header_b64, _, signature_b64 = TestPki.sign(BODY).split(".", -1)

          assert verify!(header: [header_b64, TestPki.base64url(BODY), signature_b64].join("."))
        end

        def test_rejects_a_payload_part_that_is_not_the_body
          header_b64, _, signature_b64 = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/payload does not match/,
                          header: [header_b64, TestPki.base64url("other"), signature_b64].join("."))
        end

        def test_rejects_a_tampered_body
          assert_rejected(/signature does not match/, body: BODY.sub("123.00", "1.00"))
        end

        def test_rejects_a_body_with_a_byte_appended
          assert_rejected(/signature does not match/, body: "#{BODY}&")
        end

        def test_rejects_a_signature_by_another_key_under_the_same_certificate_url
          header = TestPki.sign(BODY, signer: TestPki.leaf(:production))

          assert_rejected(/signature does not match/, header: header)
        end

        def test_rejects_a_foreign_x5u_host
          header = TestPki.sign(BODY, x5u: "https://evil.example/x509/notifications-jws.pem")

          assert_rejected(%r{is not on https://secure\.sandbox\.tpay\.com}, header: header)
        end

        def test_rejects_a_lookalike_host_that_a_prefix_check_would_accept
          url = "https://secure.sandbox.tpay.com.evil.example/x509/notifications-jws.pem"
          header = TestPki.sign(BODY, x5u: url)

          assert_rejected(/is not on/, header: header,
                                       fetcher: TestPki.fetcher(url => TestPki.leaf(:sandbox).certificate.to_pem))
        end

        def test_rejects_userinfo_tricks_in_x5u
          header = TestPki.sign(BODY, x5u: "https://secure.sandbox.tpay.com@evil.example/x509/notifications-jws.pem")

          assert_rejected(/is not on/, header: header)
        end

        def test_rejects_plain_http
          header = TestPki.sign(BODY, x5u: "http://secure.sandbox.tpay.com/x509/notifications-jws.pem")

          assert_rejected(/is not on/, header: header)
        end

        def test_rejects_a_non_default_port
          header = TestPki.sign(BODY, x5u: "https://secure.sandbox.tpay.com:8443/x509/notifications-jws.pem")

          assert_rejected(/is not on/, header: header)
        end

        def test_rejects_a_certificate_outside_the_chain
          header = TestPki.sign(BODY, signer: TestPki.foreign_leaf)
          fetcher = TestPki.fetcher(TestPki.leaf_url(:sandbox) => TestPki.foreign_leaf.certificate.to_pem)

          assert_rejected(/does not chain to Tpay's CA/, header: header, fetcher: fetcher)
        end

        # Intermediates served next to the leaf are ignored; only the
        # environment's own bundle builds the chain.
        def test_ignores_intermediates_served_with_the_leaf
          header = TestPki.sign(BODY, signer: TestPki.leaf(:sandbox), x5u: TestPki.leaf_url(:production))
          served = TestPki.leaf(:sandbox).certificate.to_pem + TestPki.intermediate(:sandbox).certificate.to_pem

          assert_rejected(/does not chain/, header: header, env: :production,
                                            fetcher: TestPki.fetcher(TestPki.leaf_url(:production) => served))
        end

        def test_rejects_an_expired_certificate
          header = TestPki.sign(BODY, signer: TestPki.expired_leaf)
          fetcher = TestPki.fetcher(TestPki.leaf_url(:sandbox) => TestPki.expired_leaf.certificate.to_pem)

          assert_rejected(/expired/, header: header, fetcher: fetcher)
        end

        def test_rejects_a_certificate_not_yet_valid
          header = TestPki.sign(BODY, signer: TestPki.future_leaf)
          fetcher = TestPki.fetcher(TestPki.leaf_url(:sandbox) => TestPki.future_leaf.certificate.to_pem)

          assert_rejected(/not valid before/, header: header, fetcher: fetcher)
        end

        def test_rejects_alg_none
          header_b64 = TestPki.base64url(JSON.generate("alg" => "none", "x5u" => TestPki.leaf_url(:sandbox)))

          assert_rejected(/unsupported JWS alg "none"/, header: "#{header_b64}..AAAA")
          # An unsecured JWS's empty signature fails earlier still.
          assert_rejected(/empty header or signature/, header: "#{header_b64}..")
        end

        def test_rejects_alg_none_even_with_a_signature_part
          header = TestPki.sign(BODY, alg: "none")

          assert_rejected(/unsupported JWS alg "none"/, header: header)
        end

        # The HS256 confusion attack: an HMAC keyed with the public
        # certificate, which an attacker can download.
        def test_rejects_alg_hs256
          header_b64 = TestPki.base64url(JSON.generate("alg" => "HS256", "x5u" => TestPki.leaf_url(:sandbox)))
          mac = OpenSSL::HMAC.digest("SHA256", TestPki.leaf(:sandbox).certificate.to_pem,
                                     "#{header_b64}.#{TestPki.base64url(BODY)}")

          assert_rejected(/unsupported JWS alg "HS256"/, header: "#{header_b64}..#{TestPki.base64url(mac)}")
        end

        def test_rejects_a_missing_alg
          assert_rejected(/unsupported JWS alg nil/,
                          header: TestPki.sign(BODY, header: { "x5u" => TestPki.leaf_url(:sandbox) }))
        end

        def test_rejects_a_crit_header
          header = TestPki.sign(BODY,
                                header: { "alg" => "RS256", "x5u" => TestPki.leaf_url(:sandbox), "crit" => ["exp"] })

          assert_rejected(/crit/, header: header)
        end

        def test_rejects_a_missing_x5u
          assert_rejected(/no x5u/, header: TestPki.sign(BODY, header: { "alg" => "RS256" }))
        end

        def test_rejects_malformed_base64_in_the_header
          _, _, signature_b64 = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/header is not base64url/, header: "e30*!..#{signature_b64}")
        end

        def test_rejects_malformed_base64_in_the_signature
          header_b64, = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/signature is not base64url/, header: "#{header_b64}..not*base64")
        end

        def test_rejects_base64_of_impossible_length
          header_b64, = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/signature is not base64url/, header: "#{header_b64}..A")
        end

        def test_rejects_padded_standard_base64
          header_b64, _, signature_b64 = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/not base64url/, header: "#{header_b64}..#{signature_b64.tr("-_", "+/")}==")
        end

        def test_rejects_a_header_that_is_not_json
          assert_rejected(/not valid JSON/, header: "#{TestPki.base64url("not json")}..AAAA")
        end

        def test_rejects_a_header_that_is_json_but_not_an_object
          assert_rejected(/not a JSON object/, header: "#{TestPki.base64url("[1]")}..AAAA")
        end

        def test_rejects_a_missing_header
          assert_rejected(/missing X-JWS-Signature/, header: nil)
        end

        def test_rejects_an_empty_header
          assert_rejected(/missing X-JWS-Signature/, header: "  ")
        end

        def test_rejects_a_compact_jws_with_too_few_parts
          assert_rejected(/expected 3 dot-separated parts, got 2/, header: "abc.def")
        end

        def test_rejects_a_jws_with_too_many_parts
          assert_rejected(/got 4/, header: "#{TestPki.sign(BODY)}.x")
        end

        def test_rejects_an_empty_signature
          header_b64, = TestPki.sign(BODY).split(".", -1)

          assert_rejected(/empty header or signature/, header: "#{header_b64}..")
        end

        def test_rejects_a_sandbox_certificate_url_on_a_production_verifier
          assert_rejected(%r{is not on https://secure\.tpay\.com}, env: :production)
        end

        def test_rejects_a_production_certificate_url_on_a_sandbox_verifier
          header = TestPki.sign(BODY, signer: TestPki.leaf(:production), x5u: TestPki.leaf_url(:production))

          assert_rejected(%r{is not on https://secure\.sandbox\.tpay\.com}, header: header)
        end

        # Both environments share a root, so these hold only because the
        # chain must run through the environment's own intermediate.
        def test_rejects_a_sandbox_certificate_served_from_the_production_host
          header = TestPki.sign(BODY, signer: TestPki.leaf(:sandbox), x5u: TestPki.leaf_url(:production))
          fetcher = TestPki.fetcher(TestPki.leaf_url(:production) => TestPki.leaf(:sandbox).certificate.to_pem)

          assert_rejected(/does not chain/, header: header, env: :production, fetcher: fetcher)
        end

        def test_rejects_a_production_certificate_served_from_the_sandbox_host
          header = TestPki.sign(BODY, signer: TestPki.leaf(:production))
          fetcher = TestPki.fetcher(TestPki.leaf_url(:sandbox) => TestPki.leaf(:production).certificate.to_pem)

          assert_rejected(/does not chain/, header: header, fetcher: fetcher)
        end

        def test_rejects_a_non_certificate_at_x5u
          assert_rejected(/no certificate found/,
                          fetcher: TestPki.fetcher(TestPki.leaf_url(:sandbox) => "<html>not found</html>"))
        end

        def test_rejects_a_corrupt_certificate
          pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
          error = assert_rejected(/could not be verified/, fetcher: TestPki.fetcher(TestPki.leaf_url(:sandbox) => pem))

          assert_kind_of OpenSSL::X509::CertificateError, error.cause
        end

        def test_turns_a_certificate_fetch_failure_into_a_signature_error
          failing = Object.new
          def failing.fetch(_url) = raise(ConnectionError, "timeout")

          error = assert_rejected(/could not be verified: Tpay::Openapi::ConnectionError: timeout/, fetcher: failing)

          assert_kind_of ConnectionError, error.cause
        end

        def test_uses_given_trust_anchors_instead_of_fetching_the_root_bundle
          fetcher = Drivers::Fake::CertificateFiles.new(
            TestPki.leaf_url(:sandbox) => TestPki.leaf(:sandbox).certificate.to_pem
          )

          assert verify!(fetcher: fetcher, trust_anchors: [TestPki.intermediate(:sandbox).certificate,
                                                           TestPki.root.certificate])
        end

        def test_given_trust_anchors_replace_the_bundle_rather_than_adding_to_it
          assert_rejected(/does not chain/, trust_anchors: [TestPki.intermediate(:production).certificate,
                                                            TestPki.root.certificate])
        end

        def test_unknown_environment_is_an_argument_error
          assert_raises(ArgumentError) { verify!(env: :staging) }
        end

        def test_valid_answers_true_and_false_without_raising
          assert Notification.valid?(raw_body: BODY, jws_header: TestPki.sign(BODY), env: :sandbox,
                                     fetcher: TestPki.fetcher)
          refute Notification.valid?(raw_body: "#{BODY}x", jws_header: TestPki.sign(BODY), env: :sandbox,
                                     fetcher: TestPki.fetcher)
          refute Notification.valid?(raw_body: BODY, jws_header: nil, env: :sandbox, fetcher: TestPki.fetcher)
        end
      end
    end
  end
end
