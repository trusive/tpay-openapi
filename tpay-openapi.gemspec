require_relative "lib/tpay/openapi/version"

Gem::Specification.new do |spec|
  spec.name = "tpay-openapi"
  spec.version = Tpay::Openapi::VERSION
  spec.authors = ["Radosław Woźniak"]
  spec.email = ["184065+radwo@users.noreply.github.com"]

  spec.summary = "Ruby client for the Tpay Open API"
  spec.description = "Create Tpay transactions, read their status back for " \
                     "reconciliation, refund them, and verify the JWS-signed " \
                     "payment notifications Tpay posts. Pure Ruby, stdlib only, " \
                     "with a Fake driver for development and tests. Unrelated to " \
                     "the `tpay` gem, which targets the legacy transferuj.pl API."
  spec.homepage = "https://github.com/trusive/tpay-openapi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  # No homepage_uri: spec.homepage already carries it, and rubygems warns when
  # two metadata URIs are identical because it only shows the first.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  # Unversioned on purpose: rubydoc.info redirects to the newest release, so
  # this never needs bumping.
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/tpay-openapi"
  spec.metadata["rubygems_mfa_required"] = "true"

  # .yardopts is packaged deliberately: rubydoc.info builds from the released
  # gem, not from the repository, so the options only apply if they ship.
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt", ".yardopts"]
  spec.require_paths = ["lib"]
end
