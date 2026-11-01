require "test_helper"

module Tpay
  module Openapi
    class ClientTest < Minitest::Test
      def test_builds_a_sandbox_http_driver_by_default
        client = Client.new(client_id: "id", client_secret: "secret")

        assert_instance_of Drivers::Http, client.driver
        assert_equal :sandbox, client.driver.environment.name
      end

      def test_uses_an_injected_driver_instead
        fake = Drivers::Fake.new

        assert_same fake, Client.new(driver: fake).driver
      end

      def test_transactions_is_memoized
        client = Client.new(driver: Drivers::Fake.new)

        assert_instance_of Transactions, client.transactions
        assert_same client.transactions, client.transactions
      end

      def test_inspect_hides_the_credentials
        client = Client.new(client_id: "my-client-id", client_secret: "my-secret")

        refute_match(/my-client-id|my-secret/, client.inspect)
      end
    end
  end
end
