require "test_helper"

module Tpay
  class OpenapiTest < Minitest::Test
    LIB = File.expand_path("../../lib", __dir__)

    def test_has_a_version_number
      assert_match(/\A\d+\.\d+\.\d+\z/, Openapi::VERSION)
    end

    def test_defines_the_error_hierarchy
      [Openapi::AuthError, Openapi::RequestError, Openapi::RateLimitError,
       Openapi::ServiceUnavailableError, Openapi::ServerError].each do |error_class|
        assert_operator error_class, :<, Openapi::ApiError
      end
      assert_operator Openapi::ApiError, :<, Openapi::Error
      assert_operator Openapi::Error, :<, StandardError
      [Openapi::ConnectionError, Openapi::SignatureError].each do |error_class|
        assert_operator error_class, :<, Openapi::Error
        refute_operator error_class, :<, Openapi::ApiError
      end
    end

    def test_defaults_to_the_sandbox
      assert_equal :sandbox, Openapi::Environment::DEFAULT
    end

    def test_has_no_runtime_dependencies
      spec = Gem::Specification.load(File.expand_path("../../tpay-openapi.gemspec", __dir__))

      assert_empty spec.runtime_dependencies
    end

    def test_does_not_depend_on_rails
      files = Dir["#{LIB}/**/*.rb"]

      refute_empty files, "found no library source to check"
      refute_match(/\bRails\b|ActiveSupport|ActiveRecord/, files.map { |file| File.read(file) }.join)
    end

    # base64 and bigdecimal left the default gems in Ruby 3.4; requiring
    # either would be a hidden runtime dependency.
    def test_requires_only_default_gems
      required = Dir["#{LIB}/**/*.rb"].flat_map { |file| File.read(file).scan(/^\s*require "([^"]+)"/).flatten }.uniq

      assert_empty required - %w[net/http openssl uri json digest]
    end
  end
end
