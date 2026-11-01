require "openssl"

module Tpay
  module Openapi
    module Drivers
      class Fake
        # A throwaway certificate authority for signing notifications offline:
        # a self-signed root and a signing certificate it issued, generated
        # in memory the first time they are needed. Nothing here is Tpay's;
        # a verifier trusts it only when told to (see {Fake#certificate_fetcher}).
        class Pki
          # One certificate with its key.
          Issued = Data.define(:certificate, :key)

          # @return [Issued]
          attr_reader :root, :signer

          def initialize
            now = Time.now
            @root = self.class.issue(subject: "Fake Tpay JWS Root", ca: true,
                                     not_before: now - 3600, not_after: now + (10 * 365 * 86_400))
            @signer = self.class.issue(subject: "notification.fake.tpay", issuer: @root,
                                       not_before: now - 3600, not_after: now + (365 * 86_400))
          end

          # RS256 signature over `signing_input`.
          # @param signing_input [String]
          # @return [String] raw signature bytes
          def sign(signing_input)
            signer.key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
          end

          class << self
            # Issues one certificate - self-signed when no issuer is given.
            # Public so tests can build the chains a verifier has to reject.
            #
            # @param subject [String] the CN
            # @param issuer [Issued, nil]
            # @param ca [Boolean]
            # @param not_before [Time]
            # @param not_after [Time]
            # @param key [OpenSSL::PKey::RSA, nil] generated when not given
            # @return [Issued]
            def issue(subject:, not_before:, not_after:, issuer: nil, ca: false, key: nil)
              key ||= OpenSSL::PKey::RSA.new(2048)
              certificate = OpenSSL::X509::Certificate.new
              certificate.version = 2
              certificate.serial = OpenSSL::BN.rand(64)
              certificate.subject = OpenSSL::X509::Name.parse("/CN=#{subject}")
              certificate.issuer = issuer ? issuer.certificate.subject : certificate.subject
              certificate.public_key = key.public_key
              certificate.not_before = not_before
              certificate.not_after = not_after
              add_extensions(certificate, issuer&.certificate || certificate, ca)
              certificate.sign(issuer ? issuer.key : key, OpenSSL::Digest.new("SHA256"))
              Issued.new(certificate: certificate, key: key)
            end

            private

            def add_extensions(certificate, issuer_certificate, ca)
              extensions = OpenSSL::X509::ExtensionFactory.new
              extensions.subject_certificate = certificate
              extensions.issuer_certificate = issuer_certificate
              certificate.add_extension(extensions.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE",
                                                                    true))
              usage = ca ? "keyCertSign,cRLSign" : "digitalSignature"
              certificate.add_extension(extensions.create_extension("keyUsage", usage, true))
              certificate.add_extension(extensions.create_extension("subjectKeyIdentifier", "hash", false))
            end
          end
        end
      end
    end
  end
end
