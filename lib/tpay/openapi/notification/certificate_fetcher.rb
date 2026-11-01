require "net/http"
require "openssl"
require "uri"

module Tpay
  module Openapi
    module Notification
      # Downloads a certificate file over HTTPS. Knows nothing about which
      # URLs are acceptable - the {Verifier} decides that before calling.
      class HttpFetcher
        # @param open_timeout [Numeric] seconds
        # @param read_timeout [Numeric] seconds
        def initialize(open_timeout: 5, read_timeout: 10)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        # @param url [String] an https URL
        # @return [String] the response body
        # @raise [ConnectionError] for a transport failure or a non-200 answer
        def fetch(url)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          response = http.request(Net::HTTP::Get.new(uri))
          unless response.code == "200"
            raise ConnectionError,
                  "certificate fetch from #{url} answered HTTP #{response.code}"
          end

          response.body.to_s
        rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
          raise ConnectionError, "certificate fetch from #{url} failed: #{e.class}: #{e.message}"
        end
      end

      # Caches another fetcher's answers per URL for `ttl` seconds.
      # Thread-safe; failures are not cached.
      #
      # The default (one per process, see {Notification.default_fetcher})
      # wraps an {HttpFetcher}, so certificates are downloaded at most once
      # a day rather than on every notification.
      class CachingFetcher
        # Seconds a certificate file is reused: one day.
        DEFAULT_TTL = 24 * 60 * 60

        # @param fetcher [#fetch] the source of certificate files
        # @param ttl [Numeric] seconds a fetched file is reused
        # @param clock [#call] monotonic seconds, injectable for tests
        def initialize(fetcher: HttpFetcher.new, ttl: DEFAULT_TTL,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @fetcher = fetcher
          @ttl = ttl
          @clock = clock
          @mutex = Mutex.new
          @entries = {}
        end

        # @param url [String]
        # @return [String]
        def fetch(url)
          @mutex.synchronize do
            body, fetched_at = @entries[url]
            return body if body && @clock.call - fetched_at < @ttl

            body = @fetcher.fetch(url)
            @entries[url] = [body, @clock.call]
            body
          end
        end

        # Drops every cached file.
        def clear
          @mutex.synchronize { @entries.clear }
        end
      end
    end
  end
end
