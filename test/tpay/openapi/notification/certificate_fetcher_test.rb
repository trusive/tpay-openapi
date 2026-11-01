require "test_helper"

module Tpay
  module Openapi
    module Notification
      class CertificateFetcherTest < Minitest::Test
        URL = "https://secure.sandbox.tpay.com/x509/notifications-jws.pem".freeze

        class CountingFetcher
          attr_reader :calls

          def initialize
            @calls = 0
          end

          def fetch(url)
            @calls += 1
            "#{url} ##{@calls}"
          end
        end

        def setup
          @now = 0
          @inner = CountingFetcher.new
          @cache = CachingFetcher.new(fetcher: @inner, ttl: 100, clock: -> { @now })
        end

        def test_reuses_a_fetched_file_within_the_ttl
          @cache.fetch(URL)
          @now = 99

          assert_equal "#{URL} #1", @cache.fetch(URL)
          assert_equal 1, @inner.calls
        end

        def test_refetches_once_the_ttl_has_passed
          @cache.fetch(URL)
          @now = 100

          assert_equal "#{URL} #2", @cache.fetch(URL)
        end

        def test_caches_per_url
          @cache.fetch(URL)
          @cache.fetch("https://secure.sandbox.tpay.com/x509/tpay-jws-root.pem")

          assert_equal 2, @inner.calls
        end

        def test_does_not_cache_failures
          failing = Object.new
          def failing.fetch(_url) = raise(ConnectionError, "down")
          cache = CachingFetcher.new(fetcher: failing)

          assert_raises(ConnectionError) { cache.fetch(URL) }
          assert_raises(ConnectionError) { cache.fetch(URL) }
        end

        def test_clear_forgets_everything
          @cache.fetch(URL)
          @cache.clear
          @cache.fetch(URL)

          assert_equal 2, @inner.calls
        end

        def test_default_ttl_is_a_day
          assert_equal 86_400, CachingFetcher::DEFAULT_TTL
        end

        def test_concurrent_fetches_of_a_cold_url_fetch_once
          slow = CountingFetcher.new
          def slow.fetch(url)
            sleep 0.01
            super
          end
          cache = CachingFetcher.new(fetcher: slow)

          Array.new(8) { Thread.new { cache.fetch(URL) } }.each(&:join)

          assert_equal 1, slow.calls
        end

        def test_http_fetcher_returns_the_body
          stub_request(:get, URL).to_return(status: 200, body: "PEM")

          assert_equal "PEM", HttpFetcher.new.fetch(URL)
        end

        def test_http_fetcher_raises_on_anything_but_ok
          stub_request(:get, URL).to_return(status: 404, body: "")

          assert_raises(ConnectionError) { HttpFetcher.new.fetch(URL) }
        end

        def test_http_fetcher_does_not_follow_redirects
          stub_request(:get, URL).to_return(status: 302, headers: { "Location" => "https://evil.example/cert.pem" })

          assert_raises(ConnectionError) { HttpFetcher.new.fetch(URL) }
        end

        def test_http_fetcher_raises_connection_error_on_timeout
          stub_request(:get, URL).to_timeout

          assert_raises(ConnectionError) { HttpFetcher.new.fetch(URL) }
        end
      end
    end
  end
end
