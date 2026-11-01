source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.0"
gem "rubocop", "~> 1.86", require: false
gem "rubocop-minitest", "~> 0.38", require: false
gem "rubocop-performance", "~> 1.26", require: false
gem "rubocop-rake", "~> 0.7", require: false
gem "webmock", "~> 3.25"
gem "yard", "~> 0.9", require: false
# YARD needs a markdown provider for --markup markdown; kramdown is pure Ruby,
# so it builds everywhere the matrix runs.
gem "kramdown", "~> 2.5", require: false
# `yard server` runs on webrick, which stopped being a default gem in Ruby 3.0
# and so has to be asked for explicitly inside a bundle.
gem "webrick", "~> 1.9", require: false
# Tests pass BigDecimal amounts. It left the default gems in Ruby 3.4, so a
# bundle has to ask for it; the library itself only recognises it.
gem "bigdecimal", require: false
