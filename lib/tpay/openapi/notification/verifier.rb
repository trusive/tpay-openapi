require "json"
require "openssl"
require "uri"

module Tpay
  module Openapi
    module Notification
      # Verifies the detached JWS (RFC 7515) Tpay sends in X-JWS-Signature.
      #
      # Every check raises {SignatureError}; there is no path that answers
      # false. In order:
      #
      # 1. the header is `<b64url header>..<b64url signature>` - three parts,
      #    the payload part empty (or, if present, exactly the encoded body);
      # 2. the protected header is a JSON object with `alg` exactly `RS256`,
      #    no `crit`, and an `x5u`;
      # 3. `x5u` is an https URL on exactly this environment's certificate
      #    host, on the default port, with no userinfo. The host is parsed
      #    and compared whole, never by prefix, so
      #    `secure.tpay.com.evil.example` fails;
      # 4. the certificate there is within its validity period and chains to
      #    the environment's `tpay-jws-root.pem` bundle (or to the trust
      #    anchors given). The chain is built from that bundle only, not
      #    from anything else served at `x5u`;
      # 5. its RSA key verifies the signature over
      #    `header_b64 + "." + b64url(raw_body)`.
      #
      # See docs/api-notes.md, "JWS", for why each rule is there.
      class Verifier
        # The only JWS algorithm accepted.
        ALGORITHM = "RS256".freeze
        # Where each certificate host serves its CA bundle.
        ROOT_PATH = "/x509/tpay-jws-root.pem".freeze
        # @api private
        PEM_BLOCK = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
        # @api private
        BASE64URL = /\A[A-Za-z0-9_-]*\z/

        # @param env [Symbol] `:sandbox` or `:production`
        # @param fetcher [#fetch] returns a certificate file's contents for
        #   a URL
        # @param trust_anchors [Array<OpenSSL::X509::Certificate>, nil]
        #   certificates to trust instead of the environment's root bundle;
        #   for tests and for pinning
        # @param clock [#call] current Time, injectable for tests
        def initialize(env:, fetcher: Notification.default_fetcher, trust_anchors: nil, clock: -> { Time.now })
          @environment = Environment.fetch(env)
          @fetcher = fetcher
          @trust_anchors = trust_anchors
          @clock = clock
        end

        # @param raw_body [String] the request body exactly as received
        # @param jws_header [String, nil] the X-JWS-Signature header
        # @return [true]
        # @raise [SignatureError]
        def verify!(raw_body:, jws_header:)
          header_b64, signature_b64 = split(jws_header, raw_body)
          header = decode_header(header_b64)
          certificate = signing_certificate(certificate_url(header))
          verify_signature(certificate, "#{header_b64}.#{base64url(raw_body)}", signature_b64)
          true
        rescue SignatureError
          raise
        rescue StandardError => e
          # Anything unexpected in the checks themselves - a fetch failure, an
          # OpenSSL parse error - still means "not verified".
          raise SignatureError, "notification signature could not be verified: #{e.class}: #{e.message}"
        end

        private

        def split(jws_header, raw_body)
          raise SignatureError, "missing X-JWS-Signature header" if jws_header.nil? || jws_header.to_s.strip.empty?
          raise SignatureError, "raw_body must be a String" unless raw_body.is_a?(String)

          parts = jws_header.to_s.strip.split(".", -1)
          unless parts.size == 3
            raise SignatureError,
                  "malformed JWS: expected 3 dot-separated parts, got #{parts.size}"
          end

          header_b64, payload_b64, signature_b64 = parts
          raise SignatureError, "malformed JWS: empty header or signature" if header_b64.empty? || signature_b64.empty?
          unless payload_b64.empty? || payload_b64 == base64url(raw_body)
            raise SignatureError, "JWS payload does not match the request body"
          end

          [header_b64, signature_b64]
        end

        def decode_header(header_b64)
          header = JSON.parse(decode64url(header_b64, "header"))
          raise SignatureError, "malformed JWS: header is not a JSON object" unless header.is_a?(Hash)

          # TODO(unverified): the literal alg Tpay sends (docs/api-notes.md,
          # unverified item 7); RS256 is RFC 7518's name for what the docs
          # verify with (SHA-256, PKCS#1 v1.5).
          unless header["alg"] == ALGORITHM
            raise SignatureError, "unsupported JWS alg #{header["alg"].inspect}; only #{ALGORITHM} is accepted"
          end
          raise SignatureError, "JWS crit header is not supported" if header.key?("crit")

          header
        rescue JSON::ParserError
          raise SignatureError, "malformed JWS: header is not valid JSON"
        end

        # TODO(unverified): the exact x5u path (docs/api-notes.md, unverified
        # item 7). The host is what Tpay controls, so only scheme, host and
        # port are pinned.
        def certificate_url(header)
          x5u = header["x5u"]
          raise SignatureError, "JWS header has no x5u" unless x5u.is_a?(String) && !x5u.empty?

          uri = URI.parse(x5u)
          unless uri.is_a?(URI::HTTPS) && uri.host == @environment.secure_host &&
                 uri.port == 443 && uri.userinfo.nil?
            raise SignatureError, "x5u #{x5u.inspect} is not on https://#{@environment.secure_host}"
          end

          x5u
        rescue URI::InvalidURIError
          raise SignatureError, "x5u #{x5u.inspect} is not a valid URL"
        end

        def signing_certificate(url)
          certificate = certificates_in(@fetcher.fetch(url), url).first
          now = @clock.call
          check_validity!(certificate, now)
          check_chain!(certificate, now)
          certificate
        end

        def check_validity!(certificate, now)
          if now < certificate.not_before
            raise SignatureError, "signing certificate is not valid before #{certificate.not_before.utc}"
          end
          return unless now > certificate.not_after

          raise SignatureError, "signing certificate expired at #{certificate.not_after.utc}"
        end

        # OpenSSL also checks dates while building the chain; the explicit
        # check above is there so the reason is named, and the chain below
        # is re-checked the same way so an expired CA is named too.
        def check_chain!(certificate, now)
          store = OpenSSL::X509::Store.new
          anchors.each { |anchor| store.add_cert(anchor) }
          store.time = now
          context = OpenSSL::X509::StoreContext.new(store, certificate, [])
          unless context.verify
            raise SignatureError, "signing certificate does not chain to Tpay's CA: #{context.error_string}"
          end

          context.chain.drop(1).each { |ca| check_validity!(ca, now) }
        end

        def anchors
          return @trust_anchors if @trust_anchors

          url = "https://#{@environment.secure_host}#{ROOT_PATH}"
          certificates_in(@fetcher.fetch(url), url)
        end

        # The sandbox leaf file is an `openssl x509 -text` dump followed by
        # the PEM block, so blocks are extracted rather than the file parsed
        # whole.
        def certificates_in(contents, url)
          blocks = contents.to_s.scan(PEM_BLOCK)
          raise SignatureError, "no certificate found at #{url}" if blocks.empty?

          blocks.map { |pem| OpenSSL::X509::Certificate.new(pem) }
        end

        def verify_signature(certificate, signing_input, signature_b64)
          key = certificate.public_key
          raise SignatureError, "signing certificate does not carry an RSA key" unless key.is_a?(OpenSSL::PKey::RSA)

          signature = decode64url(signature_b64, "signature")
          return if key.verify(OpenSSL::Digest.new("SHA256"), signature, signing_input)

          raise SignatureError, "JWS signature does not match the request body"
        end

        def decode64url(text, part)
          raise SignatureError, "malformed JWS: #{part} is not base64url" unless text.match?(BASE64URL)

          padded = text.tr("-_", "+/")
          padded += "=" * (-padded.length % 4)
          padded.unpack1("m0")
        rescue ArgumentError
          raise SignatureError, "malformed JWS: #{part} is not base64url"
        end

        def base64url(data)
          [data].pack("m0").tr("+/", "-_").delete("=")
        end
      end
    end
  end
end
