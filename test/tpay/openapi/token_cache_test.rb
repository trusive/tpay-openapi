require "test_helper"

module Tpay
  module Openapi
    class TokenCacheTest < Minitest::Test
      def setup
        @now = 1_000.0
        @fetches = 0
        @cache = TokenCache.new(fetcher: -> { issue }, margin: 60, clock: -> { @now })
      end

      def issue(expires_in: 7200)
        @fetches += 1
        { "access_token" => "token-#{@fetches}", "expires_in" => expires_in }
      end

      def test_fetches_on_first_use
        assert_equal "token-1", @cache.token
        assert_equal 1, @fetches
      end

      def test_reuses_the_token_until_the_safety_margin
        @cache.token
        @now += 7200 - 60 - 1

        assert_equal "token-1", @cache.token
        assert_equal 1, @fetches
      end

      def test_refreshes_once_inside_the_safety_margin
        @cache.token
        @now += 7200 - 60

        assert_equal "token-2", @cache.token
      end

      def test_follows_the_lifetime_tpay_reports_rather_than_assuming_two_hours
        cache = TokenCache.new(fetcher: -> { issue(expires_in: 600) }, margin: 60, clock: -> { @now })
        cache.token
        @now += 540

        assert_equal "token-2", cache.token
      end

      def test_uses_a_lifetime_shorter_than_twice_the_margin_for_half_its_length
        cache = TokenCache.new(fetcher: -> { issue(expires_in: 100) }, margin: 60, clock: -> { @now })
        cache.token
        @now += 49

        assert_equal "token-1", cache.token
        @now += 1

        assert_equal "token-2", cache.token
      end

      def test_falls_back_to_the_documented_default_lifetime
        cache = TokenCache.new(fetcher: -> { { "access_token" => "t" } }, margin: 60, clock: -> { @now })
        cache.token
        @now += 7000

        assert_equal "t", cache.token
      end

      def test_invalidate_drops_the_given_token
        @cache.token
        @cache.invalidate("token-1")

        assert_equal "token-2", @cache.token
      end

      def test_invalidate_ignores_a_token_already_replaced
        @cache.token
        @cache.invalidate("token-1")
        @cache.token
        @cache.invalidate("token-1")

        assert_equal "token-2", @cache.token
        assert_equal 2, @fetches
      end

      def test_a_response_without_an_access_token_raises_auth_error
        cache = TokenCache.new(fetcher: -> { { "expires_in" => 7200 } })

        assert_raises(AuthError) { cache.token }
      end

      def test_a_failed_fetch_is_not_cached
        calls = 0
        cache = TokenCache.new(fetcher: lambda {
          calls += 1
          raise ConnectionError, "down" if calls == 1

          { "access_token" => "ok", "expires_in" => 7200 }
        })

        assert_raises(ConnectionError) { cache.token }
        assert_equal "ok", cache.token
      end

      def test_concurrent_callers_share_one_fetch
        fetches = 0
        cache = TokenCache.new(fetcher: lambda {
          fetches += 1
          sleep 0.05
          { "access_token" => "shared", "expires_in" => 7200 }
        })

        tokens = Array.new(16) { Thread.new { cache.token } }.map(&:value)

        assert_equal ["shared"], tokens.uniq
        assert_equal 1, fetches
      end

      def test_concurrent_invalidations_after_one_401_refetch_once
        fetches = 0
        cache = TokenCache.new(fetcher: lambda {
          fetches += 1
          sleep 0.01
          { "access_token" => "token-#{fetches}", "expires_in" => 7200 }
        })
        stale = cache.token

        tokens = Array.new(8) do
          Thread.new do
            cache.invalidate(stale)
            cache.token
          end
        end.map(&:value)

        assert_equal ["token-2"], tokens.uniq
        assert_equal 2, fetches
      end

      def test_inspect_hides_the_token
        @cache.token

        refute_includes @cache.inspect, "token-1"
        assert_includes @cache.inspect, "[FILTERED]"
      end
    end
  end
end
