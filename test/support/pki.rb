require "json"
require "openssl"

# Test certificate hierarchy shaped like Tpay's (docs/api-notes.md,
# "Certificates observed"): one root shared by both environments, an
# intermediate CA per environment, a signing certificate under each. The
# root bundle a verifier trusts is intermediate + root, as Tpay serves it.
#
# Key generation is the slow part, so the hierarchy is built once per run.
module TestPki
  Pki = Tpay::Openapi::Drivers::Fake::Pki

  HOSTS = { sandbox: "secure.sandbox.tpay.com", production: "secure.tpay.com" }.freeze
  LEAF_PATH = "/x509/notifications-jws.pem".freeze
  ROOT_PATH = "/x509/tpay-jws-root.pem".freeze

  module_function

  def now
    @now ||= Time.now
  end

  def year
    365 * 86_400
  end

  def root
    @root ||= Pki.issue(subject: "Test KIP SA Root CA", ca: true, not_before: now - year, not_after: now + (20 * year))
  end

  def intermediate(env)
    @intermediates ||= {}
    @intermediates[env] ||= Pki.issue(subject: "Test #{env} CA", ca: true, issuer: root,
                                      not_before: now - year, not_after: now + (10 * year))
  end

  def leaf(env)
    @leaves ||= {}
    @leaves[env] ||= Pki.issue(subject: "notification.#{env}.test", issuer: intermediate(env),
                               not_before: now - year, not_after: now + year)
  end

  # A signing certificate whose validity ended yesterday, under the real
  # sandbox intermediate.
  def expired_leaf
    @expired_leaf ||= Pki.issue(subject: "expired", issuer: intermediate(:sandbox),
                                not_before: now - (2 * year), not_after: now - 86_400)
  end

  # A signing certificate that is not valid until tomorrow.
  def future_leaf
    @future_leaf ||= Pki.issue(subject: "future", issuer: intermediate(:sandbox),
                               not_before: now + 86_400, not_after: now + year)
  end

  # A complete, well-formed hierarchy nobody trusts.
  def foreign_leaf
    @foreign_leaf ||= begin
      foreign_root = Pki.issue(subject: "Evil Root", ca: true, not_before: now - year, not_after: now + year)
      Pki.issue(subject: "notification.evil", issuer: foreign_root, not_before: now - year, not_after: now + year)
    end
  end

  # The root bundle as Tpay serves it: intermediate first, then the root.
  def bundle(env)
    [intermediate(env), root].map { |issued| issued.certificate.to_pem }.join
  end

  def leaf_url(env)
    "https://#{HOSTS.fetch(env)}#{LEAF_PATH}"
  end

  def root_url(env)
    "https://#{HOSTS.fetch(env)}#{ROOT_PATH}"
  end

  # Files served at both environments' real URLs.
  def files
    HOSTS.keys.each_with_object({}) do |env, served|
      served[leaf_url(env)] = leaf(env).certificate.to_pem
      served[root_url(env)] = bundle(env)
    end
  end

  def fetcher(overrides = {})
    Tpay::Openapi::Drivers::Fake::CertificateFiles.new(files.merge(overrides))
  end

  def base64url(data)
    [data].pack("m0").tr("+/", "-_").delete("=")
  end

  # A detached JWS over `body`, as Tpay builds it.
  def sign(body, signer: leaf(:sandbox), header: nil, x5u: leaf_url(:sandbox), alg: "RS256")
    header_b64 = base64url(JSON.generate(header || { "alg" => alg, "x5u" => x5u }))
    signature = signer.key.sign(OpenSSL::Digest.new("SHA256"), "#{header_b64}.#{base64url(body)}")
    "#{header_b64}..#{base64url(signature)}"
  end

  def fixture(name)
    File.read(File.expand_path("../fixtures/certificates/#{name}", __dir__))
  end
end
