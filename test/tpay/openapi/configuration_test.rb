require "test_helper"

module Tpay
  module Openapi
    class ConfigurationTest < Minitest::Test
      # Global defaults are the one piece of state in this library that
      # outlives an example, so every test here puts it back. super matters:
      # webmock hangs its reset off teardown.
      def teardown
        Tpay::Openapi.reset_config!
        super
      end

      def configure_all
        Tpay::Openapi.configure do |config|
          config.client_id = "configured-id"
          config.client_secret = "configured-secret"
        end
      end

      def test_configure_yields_the_configuration_and_keeps_it
        returned = Tpay::Openapi.configure { |config| config.client_id = "a" }

        assert_same Tpay::Openapi.config, returned
        assert_equal "a", Tpay::Openapi.config.client_id
      end

      def test_an_untouched_configuration_holds_nothing
        assert_empty Tpay::Openapi.config.to_h
      end

      def test_reset_config_drops_everything
        configure_all
        Tpay::Openapi.reset_config!

        assert_empty Tpay::Openapi.config.to_h
      end

      def test_a_client_built_with_no_arguments_uses_the_configured_credentials
        configure_all
        token = stub_request(:post, "https://openapi.sandbox.tpay.com/oauth/auth")
                .with(body: { "client_id" => "configured-id", "client_secret" => "configured-secret" })
                .to_return(body: { "access_token" => "t", "expires_in" => 7200 }.to_json)
        stub_request(:get, "https://openapi.sandbox.tpay.com/transactions/01ABC").to_return(body: "{}")

        Client.new.transactions.get("01ABC")

        assert_requested token
      end

      def test_unconfigured_env_is_sandbox
        configure_all

        assert_equal :sandbox, Client.new.driver.environment.name
      end

      def test_an_explicit_setting_wins_over_the_configured_one
        configure_all
        Tpay::Openapi.configure { |config| config.env = :sandbox }

        assert_equal :production, Client.new(env: :production).driver.environment.name
      end

      def test_an_injected_driver_ignores_the_configuration_entirely
        Tpay::Openapi.configure { |config| config.env = :nonsense }
        fake = Drivers::Fake.new

        assert_same fake, Client.new(driver: fake).driver
      end

      def test_building_a_client_with_no_credentials_anywhere_fails_immediately
        error = assert_raises(ArgumentError) { Client.new }

        assert_match(/client_id/, error.message)
      end

      def test_inspect_hides_the_credentials
        configure_all
        Tpay::Openapi.configure { |config| config.read_timeout = 10 }

        refute_match(/configured-id|configured-secret/, Tpay::Openapi.config.inspect)
        assert_includes Tpay::Openapi.config.inspect, "read_timeout=10"
      end
    end
  end
end
