# Tpay::Openapi

Taking payments through Tpay. It creates a transaction and sends the payer to
Tpay's payment page, verifies the signed notification Tpay posts back, and reads
the transaction's status for reconciliation when a notification goes missing.
It also refunds a transaction in full or in part.

Pure Ruby (stdlib only): no Rails, no ActiveSupport, no runtime dependencies.

API reference: [api.tpay.com](https://api.tpay.com), guides at
[docs-api.tpay.com](https://docs-api.tpay.com/en/). What this library relies
on, with a source for every field and a list of what is still unconfirmed,
is in [docs/api-notes.md](docs/api-notes.md).

> **Not the `tpay` gem.** [`tpay`](https://rubygems.org/gems/tpay) on RubyGems
> is an old client for the legacy transferuj.pl API and is unrelated to this
> one. Both define a top-level `Tpay` module, so loading both in one process
> is unsupported.

## Installation

Not on RubyGems yet; install from git:

```ruby
gem "tpay-openapi", git: "https://github.com/trusive/tpay-openapi"
```

```ruby
require "tpay/openapi"
```

## Building a client

Credentials come from the merchant panel: *Integration → API → Open API Keys*.
For the sandbox, register an account at
[register.sandbox.tpay.com](https://register.sandbox.tpay.com/); the sandbox
panel is [panel.sandbox.tpay.com](https://panel.sandbox.tpay.com).

```ruby
# Sandbox, which is the default environment
client = Tpay::Openapi::Client.new(
  client_id:     ENV.fetch("TPAY_CLIENT_ID"),
  client_secret: ENV.fetch("TPAY_CLIENT_SECRET")
)

# Production has to be asked for by name
client = Tpay::Openapi::Client.new(
  client_id:     ENV.fetch("TPAY_CLIENT_ID"),
  client_secret: ENV.fetch("TPAY_CLIENT_SECRET"),
  env:           :production
)

# Development / tests: no HTTP, no credentials
client = Tpay::Openapi::Client.new(driver: Tpay::Openapi::Drivers::Fake.new)
```

To name the credentials once instead of at every call site, set them globally
(in an initializer, say) and build clients with no arguments:

```ruby
Tpay::Openapi.configure do |config|
  config.client_id     = ENV.fetch("TPAY_CLIENT_ID")
  config.client_secret = ENV.fetch("TPAY_CLIENT_SECRET")
  config.env           = :sandbox      # the default; :production must be explicit
  config.open_timeout  = 5             # seconds, the default
  config.read_timeout  = 30            # seconds, the default
end

Tpay::Openapi::Client.new                    # takes all of it
Tpay::Openapi::Client.new(read_timeout: 10)  # overrides one, inherits the rest
```

These are defaults for *building* a client, not a singleton the resources read
on the way out: there is deliberately no `Tpay::Openapi.transactions`.
`Client.new(driver:)` reads no configuration at all, so tests on the Fake driver
need no global state. If a test does set some, `Tpay::Openapi.reset_config!`
puts it back.

`env` is `:sandbox` unless something names `:production`, and an unknown value
raises `ArgumentError` rather than falling back to either. Credentials and the
access token never appear in `inspect`.

The client fetches an OAuth token (`client_credentials`) on first use. It
keeps that token in memory until 60 seconds before the expiry Tpay reports,
then fetches a new one. This is thread-safe: concurrent requests share one
token fetch. A request answered with 401 is retried once with a fresh token.

## Creating a transaction

```ruby
created = client.transactions.create(
  amount:             BigDecimal("199.00"),   # or "199.00"; never a Float
  description:        "Pakiet AML Standard",  # shown to the payer, up to 128 characters
  hidden_description: order.id.to_s,          # your order id; comes back in the notification
  payer:              { email: "jan@example.com", name: "Jan Kowalski" },
  success_url:        "https://staging.example.com/orders/#{order.id}/paid",
  error_url:          "https://staging.example.com/orders/#{order.id}/failed",
  notification_url:   "https://staging.example.com/tpay/notifications",
  group_id:           150                     # optional: preselect a bank group…
  # channel_id:       64                      # …or a channel, not both
)

return handle_failure(created.errors) unless created.success?

order.update!(tpay_transaction_id: created.transaction_id,  # "01K5BK4HEPB0WBCGT51FMTYSYJ"
              tpay_title:          created.title)           # "TR-BRA-KGZK0X"
redirect_to created.payment_url, allow_other_host: true
```

Keep both identifiers. `transaction_id` is what `get` and `refund` take.
`title` is what the notification carries (as `tr_id`).

`payer` takes `email:` and `name:` (both required), and optionally
`phone:`, `address:`, `code:`, `city:`, `country:`, `tax_id:`, `ip:` and
`user_agent:`. An unknown key raises `ArgumentError`, so a typo fails instead of
silently disappearing.

Amounts go out as JSON numbers with exactly two decimals (`199.00`), built
straight from the `BigDecimal` or `String` without passing through `Float`. A
`Float` or `Integer` raises `ArgumentError`, and so does an amount with more
than two decimals: the library never rounds money for you.

`notification_url` takes effect only if *Allow override* is enabled for the
POS in the merchant panel (*Settings → Notifications*); otherwise Tpay uses the
URL saved there and answers `url_override_is_disabled`.

## Webhook handling

Tpay posts `application/x-www-form-urlencoded` to the notification URL when a
payment succeeds, and again when a transaction is **fully** refunded. It
does not notify failed payments. Every notification carries a detached JWS in
`X-JWS-Signature`. Verify it before reading anything in the body:

```ruby
class TpayNotificationsController < ActionController::API
  def create
    Tpay::Openapi::Notification.verify!(
      raw_body:   request.raw_post,                    # the exact bytes, before any parsing
      jws_header: request.headers["X-JWS-Signature"],
      env:        Rails.configuration.x.tpay_env       # :sandbox on staging
    )
    payment = Tpay::Openapi::Notification.parse(request.raw_post, content_type: request.content_type)

    RecordTpayPaymentJob.perform_later(
      title:              payment.title,               # same on every resend: the idempotency key
      hidden_description: payment.hidden_description, # your order id
      amount:             payment.amount,              # "199.00", as sent
      paid:               payment.paid?,               # false for a full refund (payment.refunded?)
      payer_email:        payment.payer_email
    )

    render plain: Tpay::Openapi::Notification.acknowledgement   # "TRUE"
  rescue Tpay::Openapi::SignatureError => e
    Rails.logger.warn("Tpay notification rejected: #{e.message}")
    head :bad_request
  end
end
```

- **Respond fast, do the work in a job.** Tpay waits for `TRUE` with HTTP 200.
  Any other answer makes it resend: every minute at first, backing off to
  hourly, with the last resend 24 hours after the one before it.
- **Never answer 404 for a bad signature.** A 404 makes Tpay *stop* resending,
  so a temporary failure would lose the notification for good. A
  `SignatureError` also covers "could not fetch the certificates", so answer it
  with a 4xx/5xx that Tpay will retry.
- **Process idempotently.** The same notification can arrive more than once.
  Key on `payment.title` (or on your own order id from `hidden_description`),
  and enqueue before acknowledging.
- **`tr_paid` can differ from `tr_amount`** depending on account settings, and
  both are available (`paid_amount`, `amount`). Compare against your order
  before fulfilling.

What `verify!` checks, in order (any failure raises `SignatureError`; it never
returns `false`):

1. The header is `header..signature` (detached payload).
2. `alg` is exactly `RS256`, so `none` and `HS256` are refused.
3. `x5u` is `https` on exactly `secure.sandbox.tpay.com` (sandbox) or
   `secure.tpay.com` (production). The URL is parsed and the host compared
   whole: `secure.tpay.com.evil.example` fails, where Tpay's own sample
   code's prefix check would let it through.
4. The certificate there is within its validity dates and chains to that
   host's `/x509/tpay-jws-root.pem`. Both environments share Tpay's root CA, so
   the chain is built from the environment's own bundle only, never from
   certificates served alongside the leaf. A sandbox signature therefore cannot
   pass a production verifier, and the reverse holds too.
5. The RSA-SHA256 signature matches `header_b64 + "." + base64url(raw_body)`.

`valid?` takes the same arguments and answers a boolean.

Certificates are fetched once and cached in memory for 24 hours per process
(`Tpay::Openapi::Notification.default_fetcher`). To change that, use:

```ruby
Tpay::Openapi::Notification.default_fetcher =
  Tpay::Openapi::Notification::CachingFetcher.new(ttl: 3600)
```

`verify!` also takes `fetcher:` (anything with `fetch(url) → String`) and
`trust_anchors:` (an array of `OpenSSL::X509::Certificate` to trust instead of
the fetched bundle), which is how the tests run offline.

`md5sum` is not checked. The JWS covers the whole body, `md5sum` included, so a
verified signature already proves where the notification came from and that it
is intact.

## Reconciliation

When a notification never arrives (endpoint down, deploy in progress), ask Tpay
directly:

```ruby
result = client.transactions.get(order.tpay_transaction_id)

if result.success?
  result.transaction_status   # "pending", "paid", "correct", "refund", "canceled"
  result.settled?             # true for "paid" or "correct"
  result.record["amount"]     # 199.0 (JSON number; BigDecimal(result.record["amount"].to_s) is exact)
else
  result.error_codes          # ["transaction_does_not_exist"] for an unknown id (HTTP 404)
end
```

A scheduled job that sweeps orders still pending after some minutes and runs
`get` on each is enough. Feed a settled result into the same idempotent path
the notification uses.

## Refunds

```ruby
client.transactions.refund(order.tpay_transaction_id)                     # the full amount
client.transactions.refund(order.tpay_transaction_id, amount: "50.00")    # part of it
```

A full refund moves the transaction to `refund`, and Tpay sends a notification
whose `refunded?` is true. A partial refund changes neither, even once partial
refunds add up to the whole amount. The money comes out of the merchant
balance at the moment of the request, together with the refund fee. Refunds
fail as a `Result` with codes such as `already_refunded`,
`refund_period_expired` or `no_sufficient_funds_or_refund_limit_reached`.

## Results and errors

Every call returns a `Tpay::Openapi::Result`:

```ruby
result.success?            # 2xx and the body does not say result: "failed"
result.record              # the transaction Hash, or nil on failure
result.records             # [record], or [] on failure
result.transaction_id      # "01K5BK4HEPB0WBCGT51FMTYSYJ"
result.title               # "TR-BRA-KGZK0X"
result.payment_url         # transactionPaymentUrl, on create
result.transaction_status  # "pending", …
result.errors              # ["payer: Object payer is required (field_required)"]
result.error_codes         # ["field_required"]
result.status_code         # the HTTP status, e.g. 400
result.request_id          # Tpay's requestId, for support tickets
result.raw                 # the full parsed body
```

A response about the data you sent is a `Result` with `success? == false`, so
your code can decide what to do with it: a 400 with field errors, a 404 for an
unknown id, a 409 conflict. Anything that aborts the request is **raised**:

| Exception | HTTP status / Tpay error code | Retry? |
|---|---|---|
| `Tpay::Openapi::ConnectionError` | network failure, timeout, unparseable response | yes (see below) |
| `Tpay::Openapi::AuthError` | 401 (after one retry with a fresh token), 403, rejected `client_id`/`client_secret` | no: fix the credentials, the key's scope, or the `env` |
| `Tpay::Openapi::RequestError` | 405, other 4xx; `invalid_request_body`, `incorrect_content_type` | no: the request is wrong (report it as a bug) |
| `Tpay::Openapi::RateLimitError` | 429 | yes, with backoff |
| `Tpay::Openapi::ServiceUnavailableError` | 502, 503, 504 | yes, with backoff |
| `Tpay::Openapi::ServerError` | 500, other 5xx; `internal_server_error` | yes, with backoff |
| `Tpay::Openapi::ApiError` | any other non-2xx (e.g. 3xx) | no |
| `Tpay::Openapi::SignatureError` | notification failed verification | Tpay resends; never act on it |

400, 404 and 409 (with any other error code) arrive as a `Result`.

Every exception answers `retryable?`, so a job does not need this table:

```ruby
rescue Tpay::Openapi::Error => e
  raise if e.retryable?   # let Sidekiq reschedule
  report_and_give_up(e)
end
```

All the API failures are `Tpay::Openapi::ApiError` and carry `status_code`,
`errors` and `request_id`. `Tpay::Openapi::Error` also covers
`ConnectionError` and `SignatureError`, neither of which is an answer from the
API. Tpay documents only 400 and 404, plus the 401/403/405/409 meanings in its
PHP SDK; the 429 and 5xx rows follow the HTTP RFCs (see
[docs/api-notes.md](docs/api-notes.md)).

**Retrying `create`.** A timeout or a 5xx may come after Tpay has already
created the transaction. If the POS enforces unique hidden descriptions, a
retry with the same `hidden_description` is answered with `crc_not_unique`,
which tells you the first attempt landed. Otherwise, reconcile before you
create a second one.

## What the library deliberately does not do

- **No retries or backoff.** Exceptions say whether a retry makes sense; when
  and how often is the application's call (Sidekiq's retry schedule, say). The
  one exception is the single retry after a 401, which is part of handling the
  token rather than a retry policy.
- **No Floats, no rounding.** Amounts must already be exact.
- **No `md5sum` check.** The JWS supersedes it (see above).
- **No persistence.** Tokens and certificates live in memory, per process.
  Each process fetches its own token.
- **No business logic.** Nothing here knows about orders or invoices. The
  notification is verified and parsed, and what happens next is the
  application's.
- **Transaction notifications only.** `parse` reads the form-encoded payment
  notification. The JSON notifications for tokenization and marketplace are
  out of scope, along with those flows.

## PoC on staging

The v0.1.0 proof of concept runs on staging against the **Tpay sandbox only**,
with no production credentials anywhere in it.

- **The notification URL must be reachable from the internet over HTTPS.**
  Staging qualifies; `localhost` does not. Tpay follows no redirects (so give
  the final URL, not one that redirects http→https), uses ports 80, 8080 and 443
  only, and needs TLS 1.2.
- **Sandbox certificates live on `secure.sandbox.tpay.com`**, so verify with
  `env: :sandbox`. A production verifier rejects sandbox notifications, and
  that is intended.
- **Enable "Allow override"** for the sandbox POS (*Settings → Notifications*),
  or set the staging URL there, so that `notification_url` is honoured.

The sequence the PoC exercises:

1. **Notification verified**: `Notification.verify!` with `env: :sandbox`,
   then `parse`.
2. **Payment recorded idempotently** by the Tpay transaction title
   (`payment.title`; a unique index on it), then `TRUE` returned.
3. **A job creates a draft invoice in wFirma** with the
   [`wfirma`](https://github.com/trusive/wfirma) gem:
   `client.invoices.create({...}, draft: true)`, so the invoice gets no book
   number and is not sent to KSeF. This gem knows nothing about wFirma.

**Open question to answer during the PoC:** does wFirma accept a payment record
(`payments.pay_invoice`) against a **draft** invoice, or only once the draft is
issued? The answer decides whether step 3 can also mark the invoice paid.

### Manual checklist on the sandbox

- [ ] Sandbox account registered at register.sandbox.tpay.com; Open API key
      created in the sandbox panel; `TPAY_CLIENT_ID` / `TPAY_CLIENT_SECRET`
      set on staging only.
- [ ] *Allow override* enabled (or the staging notification URL saved) for the
      sandbox POS.
- [ ] From a staging console: `client.transactions.create(...)` answers
      `success?` with a `transaction_id`, a `title` and a `payment_url` on
      `secure.sandbox.tpay.com`.
- [ ] Open `payment_url`, pay with a sandbox method (BLIK code `777xxx`, or a
      test card), and land on `success_url`.
- [ ] The staging endpoint receives the POST: `X-JWS-Signature` is present,
      `verify!(env: :sandbox)` passes, and the endpoint answers `TRUE`. In the
      sandbox panel the notification shows as delivered, with no resends.
      Note the `x5u` and `alg` from the decoded header: both are
      `UNVERIFIED` in docs/api-notes.md until seen here.
- [ ] `parse` gives `title` equal to the created `title`, `hidden_description`
      equal to the order id, and the `amount` and `status` you expected. Record
      the exact `tr_status`, `tr_amount` and `tr_date` formats seen (also
      `UNVERIFIED`).
- [ ] Resend the notification from the sandbox panel: the payment is not
      recorded twice and the job does not create a second invoice.
- [ ] Tamper check: replay the captured body with one byte changed (for
      example with curl) and get a 400 with `SignatureError` in the log.
- [ ] Reconciliation: `client.transactions.get(transaction_id)` reports the
      settled status. Write down whether it says `paid` or `correct`
      (`UNVERIFIED`), and whether `get(title)` works too (`UNVERIFIED`).
- [ ] Create a transaction and abandon it: `get` keeps answering `pending`,
      and no notification arrives.
- [ ] The job creates the wFirma **draft**, and the open question above is
      answered.
- [ ] Optional: full and partial `refund` in the sandbox; a full refund sends a
      notification with `refunded?` true.

## Development mode

`Drivers::Fake` runs the whole library with no HTTP: request building, the
same status→exception mapping, `Result` parsing. It keeps transactions in
memory, so `create` → `get` → `refund` behave as they do against the API.

```ruby
fake = Tpay::Openapi::Drivers::Fake.new          # env: :sandbox by default
client = Tpay::Openapi::Client.new(driver: fake)

created = client.transactions.create(amount: "199.00", …)
client.transactions.get(created.transaction_id).transaction_status   # => "pending"

fake.requests            # every call made, in order; request.json is the exact wire body
fake.transaction(id)     # the stored transaction
fake.reset!              # clear calls, transactions and armed failures
```

Playing Tpay's side of a payment:

```ruby
delivery = fake.pay!(created.transaction_id)     # status → "correct"; returns the notification
delivery.raw_body        # "id=1010&tr_id=TR-FAK-000001&…&tr_status=TRUE&…"
delivery.headers         # {"Content-Type" => "application/x-www-form-urlencoded",
                         #  "X-JWS-Signature" => "eyJ…..…"}

# The notification is signed for real, with a throwaway CA the fake generates.
# Its certificate_fetcher serves those certificates at the real Tpay URLs, so
# verification runs every production step against them:
Tpay::Openapi::Notification.verify!(raw_body: delivery.raw_body, jws_header: delivery.jws_header,
                                    env: :sandbox, fetcher: fake.certificate_fetcher)

fake.fail!(created.transaction_id)               # a failed attempt: stays pending, returns nil
```

`fail!` returns no notification because Tpay sends none for a failed payment,
so a test built on one would test a path production never takes.

In a request spec, post the delivery to your own endpoint. Point the
controller at the fake's fetcher, for example through
`Notification.default_fetcher = fake.certificate_fetcher` in the test setup:

```ruby
post "/tpay/notifications", params: delivery.raw_body, headers: delivery.headers
```

Failure scenarios. Each code raises exactly what the HTTP driver raises for
it, or returns the same failed `Result`:

```ruby
fake.fail_next!(code: 503)                   # => Tpay::Openapi::ServiceUnavailableError
fake.fail_next!(code: 429)                   # => Tpay::Openapi::RateLimitError
fake.fail_next!(code: 401)                   # => Tpay::Openapi::AuthError (a persistent rejection)
fake.fail_next!(code: "internal_server_error")  # => Tpay::Openapi::ServerError
fake.fail_next!(code: "crc_not_unique")      # => Result, success? false, error_codes ["crc_not_unique"]
fake.fail_next!(code: :connection)           # => Tpay::Openapi::ConnectionError
fake.fail_always!(code: 503)                 # every call, until reset!
```

## Roadmap

Out of scope for v0.1.0:

- BLIK Level 0 (code entered on the merchant's page)
- card tokenization and the token notifications
- recurring payments
- marketplace / split payments
- reports and payouts
- Apple Pay / Google Pay as separate flows
- transaction listing and cancellation, refund status lookups (`GET /refunds`)
- refetching certificates early after a rotation (today a rotated certificate
  is picked up when the 24-hour cache expires)

## Development

```sh
bin/setup                  # bundle install
bundle exec rake           # tests + rubocop
bundle exec yard server -r # preview the API docs at localhost:8808
```

Minitest, and the suite runs entirely offline. The Fake driver covers the
resource layer, webmock covers `Drivers::Http`, and the JWS verifier runs
against a certificate hierarchy generated per test run, plus Tpay's real public
certificates in `test/fixtures` for the chain checks.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
