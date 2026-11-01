require_relative "openapi/version"
require_relative "openapi/errors"
require_relative "openapi/environment"
require_relative "openapi/amount"
require_relative "openapi/result"
require_relative "openapi/status"
require_relative "openapi/token_cache"
require_relative "openapi/configuration"
require_relative "openapi/drivers/http"
require_relative "openapi/drivers/fake"
require_relative "openapi/drivers/fake/pki"
require_relative "openapi/transactions"
require_relative "openapi/client"
require_relative "openapi/notification"
require_relative "openapi/notification/certificate_fetcher"
require_relative "openapi/notification/verifier"
require_relative "openapi/notification/payment"

module Tpay
  # Client for the Tpay Open API (https://api.tpay.com). Unrelated to the
  # `tpay` gem, which targets the legacy transferuj.pl API; loading both in
  # one process is unsupported, as both define the top-level Tpay module.
  module Openapi
  end
end
