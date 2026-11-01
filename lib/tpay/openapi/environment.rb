module Tpay
  module Openapi
    # The two Tpay environments and the hosts each one uses. See
    # docs/api-notes.md, "Base URLs".
    #
    # Sandbox is the default everywhere a default exists; production is only
    # ever reached by naming it.
    module Environment
      # One environment's endpoints.
      Settings = Data.define(:name, :api_url, :secure_host)

      # @return [Hash{Symbol => Settings}] both environments, by name
      ALL = {
        sandbox: Settings.new(
          name: :sandbox,
          api_url: "https://openapi.sandbox.tpay.com",
          secure_host: "secure.sandbox.tpay.com"
        ),
        production: Settings.new(
          name: :production,
          api_url: "https://api.tpay.com",
          secure_host: "secure.tpay.com"
        )
      }.freeze

      # The environment used whenever none is named.
      DEFAULT = :sandbox

      module_function

      # @param env [Symbol, String] `:sandbox` or `:production`
      # @return [Settings]
      # @raise [ArgumentError] for anything else, rather than falling back to
      #   either environment
      def fetch(env)
        ALL.fetch(env.to_s.to_sym) do
          raise ArgumentError, "unknown Tpay environment #{env.inspect}; expected :sandbox or :production"
        end
      end
    end
  end
end
