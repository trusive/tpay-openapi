module Tpay
  module Openapi
    # Application-wide defaults for {Client.new}, so the credentials are named
    # once - in an application's initializer, say - not at every call site.
    #
    #   Tpay::Openapi.configure do |config|
    #     config.client_id     = ENV.fetch("TPAY_CLIENT_ID")
    #     config.client_secret = ENV.fetch("TPAY_CLIENT_SECRET")
    #     config.env           = :sandbox
    #   end
    #
    #   Tpay::Openapi::Client.new                   # takes all of it
    #   Tpay::Openapi::Client.new(read_timeout: 10) # overrides one setting
    #
    # These are defaults for building a client, not a singleton the resources
    # read on the way out. Every request still goes through a Client someone
    # built, and Client.new(driver:) reads none of this at all.
    #
    # A setting left unset means "whatever Drivers::Http defaults to" - for
    # env, that is :sandbox.
    class Configuration
      SETTINGS = %i[client_id client_secret env open_timeout read_timeout].freeze

      attr_accessor(*SETTINGS)

      # Only the settings actually given, so unset ones fall through to the
      # driver rather than overriding it with nil.
      # @return [Hash{Symbol => Object}]
      def to_h
        SETTINGS.to_h { |name| [name, public_send(name)] }.compact
      end

      # Never shows the credentials.
      def inspect
        shown = to_h.map do |name, value|
          "#{name}=#{%i[client_id client_secret].include?(name) ? "[FILTERED]" : value.inspect}"
        end
        "#<#{self.class.name} #{shown.join(" ")}>"
      end
    end

    class << self
      # @return [Configuration]
      def config
        @config ||= Configuration.new
      end

      # @yieldparam config [Configuration]
      # @return [Configuration]
      def configure
        yield config
        config
      end

      # Mainly for tests: global defaults are the one piece of state here that
      # leaks between examples.
      def reset_config!
        @config = nil
      end
    end
  end
end
