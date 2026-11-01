# Tpay Open API: notes behind v0.1.0

What the gem relies on, where each fact came from, and what is still
unconfirmed. Written before the implementation and kept as the reference for
it. A field the code uses either has a source below or is marked
**UNVERIFIED**. The code marks each unverified spot with `TODO(unverified)`.

Sources, as read on 2026-11-01:

- **Spec**: the OpenAPI 3.0.0 document embedded in
  <https://api.tpay.com> (a NelmioApiDocBundle/Redoc page that carries the
  spec inline as `<script id="swagger-data">`). There is no separate
  downloadable file: `/docs.json`, `/openapi.json`, `/swagger.json` and
  `/api-docs` all answer 404. A snapshot is in
  [`openapi-snapshot.json`](openapi-snapshot.json) (sha256
  `d148024c…17af5e`), and it is the source of truth wherever it and the prose
  docs disagree.
- **Docs**: <https://docs-api.tpay.com/en/>, in particular
  [Authorization](https://docs-api.tpay.com/en/first-steps/authorization/),
  [Webhooks](https://docs-api.tpay.com/en/webhooks/),
  [Refunds](https://docs-api.tpay.com/en/refunds/) and
  [Error codes](https://docs-api.tpay.com/en/error-codes/).
- **PHP SDK**: <https://github.com/tpay-com/tpay-openapi-php> at
  `1708c255` (2026-10-22), used as a behavioural reference only.
- **Sandbox guide**:
  <https://support.tpay.com/sprzedawca/srodowisko-testowe-sandbox>.

## Base URLs

| | Sandbox | Production | Source |
|---|---|---|---|
| Open API | `https://openapi.sandbox.tpay.com` | `https://api.tpay.com` | spec `servers`; PHP [`ApiAction::TPAY_API_URL_*`](https://github.com/tpay-com/tpay-openapi-php/blob/1708c255d28b9c9b64949381f71c9d51dc641992/src/Api/ApiAction.php) |
| JWS certificates (`x5u` host) | `https://secure.sandbox.tpay.com` | `https://secure.tpay.com` | [Webhooks › Security](https://docs-api.tpay.com/en/webhooks/#security) (production only); PHP [`JWSVerifiedPaymentNotification::*_PREFIX`](https://github.com/tpay-com/tpay-openapi-php/blob/1708c255d28b9c9b64949381f71c9d51dc641992/src/Webhook/JWSVerifiedPaymentNotification.php) (both) |
| JWS root bundle | `https://secure.sandbox.tpay.com/x509/tpay-jws-root.pem` | `https://secure.tpay.com/x509/tpay-jws-root.pem` | same as above; both fetched and inspected, see below |
| Sandbox account | `https://register.sandbox.tpay.com`, panel `https://panel.sandbox.tpay.com` | — | sandbox guide |

The docs mention the sandbox certificate host nowhere; it comes from the PHP SDK.
Both hosts were fetched on 2026-11-01 and serve what the SDK expects (see
[Certificates](#certificates-observed-2026-11-01)).

## Endpoints

"Key response fields" lists what the gem reads, not the whole schema.

| Endpoint | Sandbox / production URL | Required request fields | Key response fields | Error responses | Source |
|---|---|---|---|---|---|
| `POST /oauth/auth` | `https://openapi.sandbox.tpay.com/oauth/auth` / `https://api.tpay.com/oauth/auth` | `client_id`, `client_secret` as `application/x-www-form-urlencoded` | `access_token`, `expires_in` (default 7200 s), `token_type` (`Bearer`), `issued_at`, `scope`, `client_id` | none documented. The HTTP status of a rejected login is **UNVERIFIED**. | [spec `post_api_login`](https://api.tpay.com/#tag/Authorization/operation/post_api_login); [Authorization › Request an OAuth token](https://docs-api.tpay.com/en/first-steps/authorization/) |
| `POST /transactions` | `https://openapi.sandbox.tpay.com/transactions` / `https://api.tpay.com/transactions` | `amount` (number, > 0), `currency` (enum: `PLN` only), `description` (≤ 128), `payer.email`, `payer.name` (≤ 255), `callbacks` (`payerUrls.success`/`.error`, `notification.url`), `pay`. Optional: `hiddenDescription` (≤ 255), `lang`, `pay.groupId` / `pay.channelId` (integers, mutually exclusive) | `transactionId`, `title`, `transactionPaymentUrl`, `status`, `result`, `requestId`, `amount`, `hiddenDescription`, `date.creation` | `400` `BadRequest`: `{result: "failed", requestId, errors: [{errorCode, errorMessage, fieldName, devMessage, docUrl}]}` | [spec `post_transactions_create`](https://api.tpay.com/#tag/Transactions/operation/post_transactions_create); [Webhooks › Notification address configuration](https://docs-api.tpay.com/en/webhooks/#notification-address-configuration) |
| `GET /transactions/{transactionId}` | `https://openapi.sandbox.tpay.com/transactions/{id}` / `https://api.tpay.com/transactions/{id}` | path `transactionId` | `transactionId`, `title`, `status` (`pending`, `paid`, `correct`, `refund`, `canceled`), `amount`, `hiddenDescription`, `date.creation`, `date.realization`, `payments.attempts[]` | `404` `BadRequest` (same shape as above) | [spec `get_transaction_get`](https://api.tpay.com/#tag/Transactions/operation/get_transaction_get) |
| `POST /transactions/{transactionId}/refunds` | `https://openapi.sandbox.tpay.com/transactions/{id}/refunds` / `https://api.tpay.com/transactions/{id}/refunds` | path `transactionId`. Body `{}` for a full refund, `{"amount": n}` for a partial one (`multipleOf 0.01`, > 0) | `result`, `status`, `transactionId`, `refundsList[]` | `400` `BadRequest` | [spec `post_transactions_create_refunds`](https://api.tpay.com/#tag/Transactions/operation/post_transactions_create_refunds); [Refunds › Full / Partial refund processing](https://docs-api.tpay.com/en/refunds/) |

### Request and response details

- **Authorization header** on every call except `/oauth/auth`:
  `Authorization: Bearer <access_token>` (spec `securitySchemes.Bearer`;
  [Authorization](https://docs-api.tpay.com/en/first-steps/authorization/)).
- **Token lifetime.** "The token is valid for the period specified in the
  `expires_in` parameter (by default, 2 hours) … It is important not to attempt
  to obtain a new token with every request … The token's validity period may
  change." So the gem caches the token for `expires_in` less a safety margin and
  never assumes 7200.
- **Token request encoding.** The prose docs say `application/x-www-form-urlencoded`.
  The spec says `multipart/form-data`. The PHP SDK sends JSON. The gem sends
  form-urlencoded, as the Authorization page says, which also matches its `curl -d` example.
- **Amounts.** The spec types `amount` as `number` / `format: float` with an
  example of `12.34`; the refund `amount` adds "multipleOf 0.01". The gem sends
  a JSON number literal with exactly two decimals (`12.30`), produced from a
  `BigDecimal` or a decimal `String` with no Float conversion. More than two
  decimals is rejected client-side rather than rounded.
- **`currency`** is required in the spec, with `PLN` as the only enum
  value, but the PHP SDK's own redirect example omits it. The gem always sends
  `"currency": "PLN"`.
- **`pay`** is listed as required in the spec, but the schema's own `required`
  list for it (`blikPaymentData`, `cardPaymentData`, … all at once) cannot be
  satisfied by any real request, so the spec is unreliable here. Every example
  (docs, PHP SDK) sends `pay.groupId`. **UNVERIFIED**: whether a transaction
  without `pay` is accepted and lets the payer choose a method on Tpay's page.
  The gem omits `pay` when neither `group_id:` nor `channel_id:` is given and
  carries a `TODO(unverified)`.
- **`channelId` together with `groupId`** is rejected (`channel_passed_with_group`,
  `ts:channel:both_channel_and_group_specified` in
  [Error codes](https://docs-api.tpay.com/en/error-codes/)). The gem raises
  `ArgumentError` before sending.
- **Transaction identifiers.** `transactionId` is a ULID or `ta_…` id (spec
  example `ta_6UvbBjehvHXA7vfD or 01K1Z6T40ZWKY1XZG9VD5AZ9Q4`); `title` is
  `TR-XXX-XXXXXX`. The `{transactionId}` path parameter is described only as
  "Transaction Id". **UNVERIFIED**: whether `GET /transactions/{id}` also
  accepts a title. The app should store `transactionId` from `create`.
- **Statuses** (`TransactionCreated.status`, `GetTransaction.status`):
  `pending`, `paid` ("transaction is paid"), `correct` ("merchant has accepted
  payment"), `refund` (fully refunded), `canceled`. **UNVERIFIED**: which of
  `paid` / `correct` a normal settled payment reports. The gem treats both as
  settled.
- **Partial refunds** never change the transaction status, "even if the sum of
  the partial refunds reaches 100%". A full refund moves it to `refund`
  ([Refunds](https://docs-api.tpay.com/en/refunds/)).

### HTTP status codes

The spec documents only `200`, `400` (create, refund) and `404` (get). The
PHP SDK's [`HttpCodesDictionary`](https://github.com/tpay-com/tpay-openapi-php/blob/1708c255d28b9c9b64949381f71c9d51dc641992/src/Dictionary/HttpCodesDictionary.php)
adds the meanings Tpay assigns to `201`, `202`, `204`, `401`, `403`, `405` and `409`. Nothing
documents `429` or any `5xx`; the gem maps those by their HTTP meaning
(RFC 9110 / RFC 6585), and the mapping is marked **UNVERIFIED** in the table
below.

| HTTP | Meaning (source) | Gem |
|---|---|---|
| 200, 201, 202, 204 | success (PHP SDK) | `Result`, `success?` unless body says `result: "failed"` |
| 400 | invalid data (spec, PHP SDK) | `Result`, `success? == false`, `errors` from body |
| 404 | object not found (spec, PHP SDK) | `Result`, `success? == false` |
| 409 | conflict with existing objects (PHP SDK) | `Result`, `success? == false` |
| 401 | authorization failed (PHP SDK) | refresh token, retry once, then `AuthError` |
| 403 | scope does not allow the operation (PHP SDK) | `AuthError` |
| 405, other 4xx | method not allowed (PHP SDK) / client error | `RequestError` |
| 429 | **UNVERIFIED**, RFC 6585 | `RateLimitError` |
| 502, 503, 504 | **UNVERIFIED**, RFC 9110 | `ServiceUnavailableError` |
| 500, other 5xx | **UNVERIFIED**, RFC 9110 | `ServerError` |

### Tpay error codes

Source: [Error codes](https://docs-api.tpay.com/en/error-codes/). They arrive in
`errors[].errorCode` of a `BadRequest` body. The page lists about 120 codes but not
the HTTP status that carries each one. Almost all of them describe the data sent,
so they stay in `Result#errors` / `Result#error_codes`. Three are raised because
they say something the caller cannot fix by changing the data:

| `errorCode` | Docs' description | Gem |
|---|---|---|
| `invalid_request_body` | Failed to decode request body | `RequestError` (a bug in this gem) |
| `incorrect_content_type` | Incorrect request content type | `RequestError` (a bug in this gem) |
| `internal_server_error` | Internal Server Error | `ServerError` |

Codes relevant to the PoC and left in `Result`: `crc_not_unique` ("Hidden
description is not unique!"), `too_low`, `transaction_does_not_exist`,
`already_refunded`, `cannot_create_refund`, `refund_period_expired`,
`no_sufficient_funds_or_refund_limit_reached`, `wrong_status`,
`url_override_is_disabled` / `ts:pos:result_url_not_overridable` (the
notification URL override is switched off in the merchant panel).

## Notifications (webhooks)

Source: [Webhooks › Notification after transaction settlement](https://docs-api.tpay.com/en/webhooks/#notification-after-transaction-settlement).

| Item | Value | Source |
|---|---|---|
| Method / format | `POST`, `application/x-www-form-urlencoded` | Webhooks › Notification after transaction settlement |
| When sent | "after each successful transaction", and on a **full** refund (`tr_status=chargeback`). Not sent for a failed payment; `tr_error` "always takes the value none". | Webhooks › Notification parameters |
| URL | merchant panel default, or `callbacks.notification.url` if "Allow override" is enabled for the POS | Webhooks › Notification address configuration |
| Expected acknowledgement | HTTP `200`, body `TRUE` | [Webhooks › Expected response](https://docs-api.tpay.com/en/webhooks/#expected-response) |
| Retries | on any other answer, on a schedule (every 1 min ×10, 3 min ×10, 10 min ×10, 1 h ×5, then +12 h, +24 h); **stops on HTTP 404** | [Webhooks › Automatic resending](https://docs-api.tpay.com/en/webhooks/#automatic-resending-of-notifications) |
| Idempotency | the same notification can arrive more than once; "Each notification for a given transaction will always contain the same identifier" | [Webhooks › Idempotent handling](https://docs-api.tpay.com/en/webhooks/#idempotent-handling-of-notifications) |
| Network | no 301/302 redirects followed; ports 80, 8080, 443 only; TLS 1.2 | [Webhooks › Requirements and limitations](https://docs-api.tpay.com/en/webhooks/#notification-system-requirements-and-limitations) |

Fields (`*` = always present per the docs):

| Field | Meaning | Gem (`Notification::Payment`) |
|---|---|---|
| `id`* | merchant's numeric id | `merchant_id` |
| `tr_id`* | transaction **title** (`TR-…`), not the `transactionId` | `title` |
| `tr_date`* | date paid. **UNVERIFIED** format | `date` (String, as sent) |
| `tr_crc`* | the `hiddenDescription` sent on create | `hidden_description` |
| `tr_amount`* | target amount. **UNVERIFIED** decimal format | `amount` (String, as sent) |
| `tr_paid`* | amount actually paid; "may differ from the transaction amount" | `paid_amount` (String) |
| `tr_currency` | ISO 4217 | `currency` |
| `tr_desc`* | description | `description` |
| `tr_status`* | `true` on payment, `chargeback` on full refund. **UNVERIFIED** letter case (docs show `TRUE` as the response, "the word true" for the field) | `status` (as sent); `paid?` / `refunded?` compare case-insensitively |
| `tr_error`* | always `none` (deprecated) | not exposed |
| `tr_email`* | payer's email | `payer_email` |
| `md5sum`* | `md5(id . tr_id . tr_amount . tr_crc . code)` | not verified (see below) |
| `test_mode`* | `1` test, `0` normal | `test_mode?` |

**`md5sum`.** The brief says it is deprecated. In the docs the word
"(deprecated)" appears only next to `md5sum` in the **BLIK alias**
notifications. The transaction-settlement section still says "This checksum
should always be verified", and the PHP SDK still checks it. The gem does not
verify it, as the brief instructs. The JWS signature covers the whole body,
`md5sum` included, so a valid JWS already proves integrity and origin, and
`md5sum` would add nothing but a second secret to manage.

### JWS (`X-JWS-Signature`)

Source: [Webhooks › Security](https://docs-api.tpay.com/en/webhooks/#security),
plus the PHP SDK's [`JWSVerifiedPaymentNotification::checkJwsSignature`](https://github.com/tpay-com/tpay-openapi-php/blob/1708c255d28b9c9b64949381f71c9d51dc641992/src/Webhook/JWSVerifiedPaymentNotification.php).

- Header `X-JWS-Signature`, RFC 7515, detached payload:
  `<b64url(header)>..<b64url(signature)>`. The docs' code reads only parts 0
  and 2.
- Signing input: `header_b64 + "." + b64url(raw_body)` without padding,
  verified with SHA-256 / RSASSA-PKCS1-v1_5 (`OPENSSL_ALGO_SHA256`) = `RS256`.
  **UNVERIFIED**: the literal `alg` value Tpay puts in the header. It is
  `RS256` by RFC 7518 for that algorithm, and the gem requires exactly that.
- `x5u` header → signing certificate URL. The docs and SDK check it with a string
  **prefix** (`substr($x5u, 0, strlen($prefix)) === $prefix`), which
  `https://secure.tpay.com.evil.example/…` passes. The gem parses the URL and
  compares scheme, host and port exactly instead.
- Signing certificate must be issued under `tpay-jws-root.pem` on the same host.
  **UNVERIFIED**: the exact `x5u` URL Tpay sends. The docs name
  `https://secure.tpay.com/x509/notifications-jws.pem` as the signing
  certificate, so the gem checks only the host and scheme, not the path.

### Certificates observed 2026-11-01

Fetched from both hosts and inspected with OpenSSL. Not shipped in the gem: they are
fetched at runtime and cached.

| File | Content |
|---|---|
| `secure.tpay.com/x509/notifications-jws.pem` | PEM, 1 cert: `CN=notification.tpay.com`, issuer `KIP SA HA CA`, RSA 2048, valid 2026-07-20 → 2028-07-19 |
| `secure.tpay.com/x509/tpay-jws-root.pem` | PEM, **2 certs**: `KIP SA HA CA` (issued by `KIP SA Root CA`) and self-signed `KIP SA Root CA`, valid to 2053 |
| `secure.sandbox.tpay.com/x509/notifications-jws.pem` | `openssl x509 -text` dump **followed by** the PEM block: `CN=notification.sandbox.tpay.com`, issuer `KIP SA Sandbox CA`, RSA 4096, valid 2023-07-05 → 2053-06-27 |
| `secure.sandbox.tpay.com/x509/tpay-jws-root.pem` | PEM, **2 certs**: `KIP SA Sandbox CA` (issued by `KIP SA Root CA`) and the same self-signed `KIP SA Root CA` |

What this means for the verifier:

1. **Both environments share one root** (`KIP SA Root CA`). Chaining "to the
   root" alone would accept a sandbox signature on a production endpoint as soon
   as the sandbox intermediate is supplied alongside it. The gem trusts the
   environment's whole bundle (intermediate + root) and builds the chain from
   the bundle only, never from extra certificates served at `x5u`. So a
   sandbox leaf cannot validate against the production bundle, nor the reverse.
2. The sandbox leaf file is not pure PEM. The gem extracts the
   `-----BEGIN CERTIFICATE-----` blocks rather than parsing the file whole.
3. The production leaf is valid only until 2028-07-19, so a rotation will happen.
   With a 24 h cache, a rotated certificate is picked up within a day, and Tpay
   keeps resending meanwhile.

## Sandbox behaviour

From the [sandbox guide](https://support.tpay.com/sprzedawca/srodowisko-testowe-sandbox):
BLIK codes starting with `777` succeed; bank transfers have no negative path
("waiting for payment", since banks do not report abandoned payments); card
amounts ending in `1` skip 3-D Secure. Nothing there covers notification
delivery, so the staging checklist in the README covers it.

## Unverified items (mirrored as `TODO(unverified)` in code)

1. HTTP status of a rejected `/oauth/auth` (`lib/tpay/openapi/drivers/http.rb`).
2. Whether `POST /transactions` accepts a body without `pay`
   (`lib/tpay/openapi/transactions.rb`).
3. Whether `GET /transactions/{id}` accepts a title as well as a transactionId
   (`lib/tpay/openapi/transactions.rb`).
4. Whether a settled payment reports `paid` or `correct`
   (`lib/tpay/openapi/drivers/fake.rb`, `lib/tpay/openapi/result.rb`).
5. `429` / `5xx` semantics (`lib/tpay/openapi/status.rb`).
6. `tr_status` letter case, and the `tr_amount` / `tr_date` formats
   (`lib/tpay/openapi/notification/payment.rb`).
7. The literal `alg` value and the exact `x5u` path
   (`lib/tpay/openapi/notification/verifier.rb`).
8. Which error code a refund of an unpaid transaction returns
   (`lib/tpay/openapi/drivers/fake.rb`).
9. Which HTTP status carries `internal_server_error` (`lib/tpay/openapi/drivers/fake.rb`).
