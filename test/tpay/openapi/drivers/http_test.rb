require "test_helper"

module Tpay
  module Openapi
    module Drivers
      class HttpTest < Minitest::Test
        SANDBOX = "https://openapi.sandbox.tpay.com".freeze
        TOKEN_URL = "#{SANDBOX}/oauth/auth".freeze

        def setup
          @driver = Http.new(client_id: "test-id", client_secret: "test-secret")
        end

        def token_body(token = "tok-1", expires_in: 7200)
          { "issued_at" => 1_700_000_000, "scope" => "read", "token_type" => "Bearer",
            "expires_in" => expires_in, "client_id" => "test-id", "access_token" => token }.to_json
        end

        def stub_token(*tokens)
          stub_request(:post, TOKEN_URL)
            .with(body: { "client_id" => "test-id", "client_secret" => "test-secret" },
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
            .to_return(*tokens.map { |token| { status: 200, body: token_body(token) } })
        end

        def ok_body
          { "result" => "success", "transactionId" => "01ABC", "status" => "pending" }.to_json
        end

        def failed_body(code = "field_required")
          { "result" => "failed", "requestId" => "r1",
            "errors" => [{ "errorCode" => code, "errorMessage" => "m", "fieldName" => "f" }] }.to_json
        end

        def test_defaults_to_the_sandbox
          assert_equal :sandbox, @driver.environment.name
        end

        def test_production_is_reached_only_by_naming_it
          stub_request(:post, "https://api.tpay.com/oauth/auth").to_return(body: token_body)
          stub = stub_request(:get, "https://api.tpay.com/transactions/01ABC").to_return(body: ok_body)

          Http.new(client_id: "id", client_secret: "s", env: :production).request(:get, "/transactions/01ABC")

          assert_requested stub
        end

        def test_refuses_an_unknown_environment
          assert_raises(ArgumentError) { Http.new(client_id: "id", client_secret: "s", env: :staging) }
        end

        def test_requires_both_credentials
          assert_raises(ArgumentError) { Http.new(client_id: "", client_secret: "s") }
          assert_raises(ArgumentError) { Http.new(client_id: "id", client_secret: nil) }
        end

        def test_fetches_a_token_form_encoded_and_sends_it_as_bearer
          token = stub_token("tok-1")
          call = stub_request(:post, "#{SANDBOX}/transactions")
                 .with(body: '{"amount":1.00}',
                       headers: { "Authorization" => "Bearer tok-1", "Content-Type" => "application/json",
                                  "Accept" => "application/json" })
                 .to_return(status: 200, body: ok_body)

          result = @driver.request(:post, "/transactions", { "amount" => Amount.build("1") })

          assert_requested token
          assert_requested call
          assert_predicate result, :success?
          assert_equal "01ABC", result.transaction_id
        end

        def test_reuses_the_cached_token_across_requests
          token = stub_token("tok-1")
          stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(body: ok_body)

          3.times { @driver.request(:get, "/transactions/01ABC") }

          assert_requested token, times: 1
        end

        def test_a_get_sends_no_body
          stub_token("tok-1")
          stub = stub_request(:get, "#{SANDBOX}/transactions/01ABC")
                 .with { |request| request.body.to_s.empty? && request.headers["Content-Type"].nil? }
                 .to_return(body: ok_body)

          @driver.request(:get, "/transactions/01ABC")

          assert_requested stub
        end

        def test_a_401_refreshes_the_token_and_retries_once
          token = stub_token("tok-1", "tok-2")
          stale = stub_request(:get, "#{SANDBOX}/transactions/01ABC")
                  .with(headers: { "Authorization" => "Bearer tok-1" }).to_return(status: 401, body: "")
          fresh = stub_request(:get, "#{SANDBOX}/transactions/01ABC")
                  .with(headers: { "Authorization" => "Bearer tok-2" }).to_return(status: 200, body: ok_body)

          assert_predicate @driver.request(:get, "/transactions/01ABC"), :success?
          assert_requested token, times: 2
          assert_requested stale, times: 1
          assert_requested fresh, times: 1
        end

        def test_a_second_401_raises_auth_error_without_a_third_attempt
          stub_token("tok-1", "tok-2")
          call = stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(status: 401, body: "")

          error = assert_raises(AuthError) { @driver.request(:get, "/transactions/01ABC") }

          assert_equal 401, error.status_code
          assert_requested call, times: 2
        end

        def test_a_rejected_token_request_raises_auth_error
          stub_request(:post, TOKEN_URL).to_return(status: 401, body: { "error" => "invalid_client" }.to_json)

          error = assert_raises(AuthError) { @driver.request(:get, "/transactions/01ABC") }

          assert_match(/token request rejected/, error.message)
          refute_includes error.message, "test-secret"
        end

        def test_a_token_request_hitting_an_outage_raises_the_outage
          stub_request(:post, TOKEN_URL).to_return(status: 503, body: "")

          assert_raises(ServiceUnavailableError) { @driver.request(:get, "/transactions/01ABC") }
        end

        def test_a_token_request_rate_limited_raises_rate_limit_error
          stub_request(:post, TOKEN_URL).to_return(status: 429, body: "")

          assert_raises(RateLimitError) { @driver.request(:get, "/transactions/01ABC") }
        end

        {
          403 => AuthError, 405 => RequestError, 429 => RateLimitError, 500 => ServerError,
          502 => ServiceUnavailableError, 503 => ServiceUnavailableError, 504 => ServiceUnavailableError
        }.each do |status, error_class|
          define_method(:"test_http_#{status}_raises_#{error_class.name.split("::").last}") do
            stub_token("tok-1")
            stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(status: status, body: failed_body)

            assert_raises(error_class) { @driver.request(:get, "/transactions/01ABC") }
          end
        end

        { "invalid_request_body" => RequestError, "incorrect_content_type" => RequestError,
          "internal_server_error" => ServerError }.each do |code, error_class|
          define_method(:"test_error_code_#{code}_raises_#{error_class.name.split("::").last}") do
            stub_token("tok-1")
            stub_request(:post, "#{SANDBOX}/transactions").to_return(status: 400, body: failed_body(code))

            assert_raises(error_class) { @driver.request(:post, "/transactions", {}) }
          end
        end

        def test_a_400_is_a_failed_result_with_errors
          stub_token("tok-1")
          stub_request(:post, "#{SANDBOX}/transactions").to_return(status: 400, body: failed_body("crc_not_unique"))

          result = @driver.request(:post, "/transactions", {})

          refute_predicate result, :success?
          assert_equal 400, result.status_code
          assert_equal ["crc_not_unique"], result.error_codes
          assert_equal ["f: m (crc_not_unique)"], result.errors
        end

        def test_a_404_is_a_failed_result
          stub_token("tok-1")
          stub_request(:get, "#{SANDBOX}/transactions/01ABC")
            .to_return(status: 404, body: failed_body("transaction_does_not_exist"))

          result = @driver.request(:get, "/transactions/01ABC")

          refute_predicate result, :success?
          assert_nil result.record
        end

        def test_a_timeout_raises_connection_error
          stub_token("tok-1")
          stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_timeout

          error = assert_raises(ConnectionError) { @driver.request(:get, "/transactions/01ABC") }

          assert_predicate error, :retryable?
        end

        def test_a_refused_connection_raises_connection_error
          stub_request(:post, TOKEN_URL).to_raise(Errno::ECONNREFUSED)

          assert_raises(ConnectionError) { @driver.request(:get, "/transactions/01ABC") }
        end

        def test_a_non_json_success_raises_connection_error
          stub_token("tok-1")
          stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(status: 200, body: "<html>")

          assert_raises(ConnectionError) { @driver.request(:get, "/transactions/01ABC") }
        end

        def test_passes_the_timeouts_to_net_http
          driver = Http.new(client_id: "id", client_secret: "s", open_timeout: 2, read_timeout: 7)
          built = []
          original = Net::HTTP.method(:new)
          stub_request(:post, TOKEN_URL).to_return(body: token_body)
          stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(body: ok_body)

          Net::HTTP.stub(:new, ->(*args) { original.call(*args).tap { |http| built << http } }) do
            driver.request(:get, "/transactions/01ABC")
          end

          assert_equal [[2, 7]], built.map { |http| [http.open_timeout, http.read_timeout] }.uniq
        end

        def test_inspect_shows_no_secrets
          stub_token("tok-1")
          stub_request(:get, "#{SANDBOX}/transactions/01ABC").to_return(body: ok_body)
          @driver.request(:get, "/transactions/01ABC")

          refute_match(/test-id|test-secret|tok-1/, @driver.inspect)
        end
      end
    end
  end
end
