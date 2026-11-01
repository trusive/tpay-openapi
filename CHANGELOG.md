# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-01

First version: what a pay → notify → invoice proof of concept on the Tpay
sandbox needs. Not published to RubyGems; install from git.

### Added

- `Tpay::Openapi::Client`, defaulting to the sandbox; production is reached
  only with `env: :production`. Credentials and tokens never appear in
  `inspect`.
- `Tpay::Openapi.configure` / `reset_config!`, supplying defaults for
  `Client.new` (credentials, `env`, `open_timeout`, `read_timeout`). They are
  defaults for building a client, not a singleton the resources read.
- OAuth `client_credentials` with an in-memory, thread-safe token cache that
  follows the `expires_in` Tpay reports, less a 60-second margin. A 401 is
  retried once with a fresh token.
- `client.transactions`: `create` (returns `transaction_id`, `title` and
  `payment_url`), `get` for reconciliation, and `refund` (full or partial).
- `Tpay::Openapi::Result` with `success?`, `record`, `records`, `errors`,
  `error_codes`, `status_code`, `request_id` and `raw`.
- An exception per class of failure: `AuthError`, `RequestError`,
  `RateLimitError`, `ServiceUnavailableError`, `ServerError` (all `ApiError`),
  plus `ConnectionError` and `SignatureError`. Each answers `retryable?`. The
  library itself never retries.
- `Tpay::Openapi::Amount`: amounts as `BigDecimal` or `String`, sent as
  two-decimal JSON numbers without passing through `Float`. Floats, Integers
  and amounts with more than two decimal places are refused.
- `Tpay::Openapi::Notification`: `verify!` / `valid?` for the detached JWS in
  `X-JWS-Signature`. It requires `RS256`, an `x5u` on exactly the
  environment's certificate host, a certificate within its validity dates that
  chains to that environment's own root bundle, and a matching signature.
  `parse` reads the form-encoded transaction notification; `acknowledgement`
  is the `TRUE` Tpay expects. Certificates are cached for 24 hours through an
  injectable fetcher.
- `Tpay::Openapi::Drivers::Http` and `Tpay::Openapi::Drivers::Fake`. The Fake
  keeps transactions in memory and signs `pay!` notifications with a
  generated test CA. Any armed code raises what the HTTP driver raises.
- `docs/api-notes.md`: a source for every field used, with a list of what is
  still unverified.
- CI across every supported Ruby (3.3, 3.4, 4.0).

[Unreleased]: https://github.com/trusive/tpay-openapi/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trusive/tpay-openapi/releases/tag/v0.1.0
