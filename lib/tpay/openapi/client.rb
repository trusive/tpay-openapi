module Tpay
  module Openapi
    # Public entry point.
    #
    #   # Sandbox (the default environment):
    #   client = Tpay::Openapi::Client.new(client_id: "...", client_secret: "...")
    #
    #   # Production must be asked for by name:
    #   client = Tpay::Openapi::Client.new(client_id: "...", client_secret: "...",
    #                                      env: :production)
    #
    #   # Development and tests (no HTTP, no credentials):
    #   client = Tpay::Openapi::Client.new(driver: Tpay::Openapi::Drivers::Fake.new)
    #
    #   created = client.transactions.create(amount: "123.00", description: "Order 42",
    #                                        hidden_description: "order-42", …)
    #   redirect_to created.payment_url
    #   client.transactions.get(created.transaction_id).transaction_status
    class Client
      # @return [Drivers::Http, Drivers::Fake]
      attr_reader :driver

      # Anything passed here wins over {Tpay::Openapi.configure}; anything left
      # out falls back to it, and then to the driver's own defaults. An
      # injected driver is used as-is and reads no configuration at all.
      #
      # @param client_id [String, nil]
      # @param client_secret [String, nil]
      # @param env [Symbol, nil] `:sandbox` (default) or `:production`
      # @param open_timeout [Numeric, nil] seconds
      # @param read_timeout [Numeric, nil] seconds
      # @param driver [#request, nil]
      # @raise [ArgumentError] when no driver is given and a credential is
      #   missing from both the arguments and the configuration
      def initialize(client_id: nil, client_secret: nil, env: nil,
                     open_timeout: nil, read_timeout: nil, driver: nil)
        given = {
          client_id: client_id, client_secret: client_secret, env: env,
          open_timeout: open_timeout, read_timeout: read_timeout
        }.compact

        @driver = driver || build_http_driver(Tpay::Openapi.config.to_h.merge(given))
      end

      # @param method [Symbol]
      # @param path [String]
      # @param body [Hash, nil]
      # @return [Result]
      def request(method, path, body = nil)
        driver.request(method, path, body)
      end

      # @return [Transactions]
      def transactions
        @transactions ||= Transactions.new(self)
      end

      # Never shows the credentials.
      def inspect
        "#<#{self.class.name} driver=#{driver.inspect}>"
      end

      private

      def build_http_driver(settings)
        %i[client_id client_secret].each do |name|
          raise ArgumentError, "missing keyword: :#{name}" unless settings.key?(name)
        end

        Drivers::Http.new(**settings)
      end
    end
  end
end
