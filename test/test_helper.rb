require "tpay/openapi"

require "minitest/autorun"
require "minitest/mock"
require "webmock/minitest"

require_relative "support/pki"

WebMock.disable_net_connect!
