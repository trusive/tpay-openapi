require "digest"
require "json"
require "uri"

module Tpay
  module Openapi
    module Drivers
      # Dev/test driver - no HTTP at all. Keeps transactions in memory and
      # answers in the shapes the Open API answers with, through the same
      # {Status} mapping the real driver uses, so Result parsing and the
      # exceptions behave exactly as in production.
      #
      # It also plays Tpay's side of a payment: {#pay!} settles a transaction
      # and returns the notification Tpay would post, signed with a test key
      # whose certificates {#certificate_fetcher} serves.
      class Fake
        # One call made through the driver. `json` is exactly what would have
        # gone on the wire; `body` is that JSON parsed back.
        Request = Struct.new(:http_method, :path, :body, :json)

        # A notification ready to post to your endpoint.
        Delivery = Data.define(:raw_body, :jws_header, :content_type) do
          # @return [Hash{String => String}] the HTTP headers Tpay sends
          def headers
            { "Content-Type" => content_type, "X-JWS-Signature" => jws_header }
          end
        end

        TRANSACTION_PATH = %r{\A/transactions/([A-Za-z0-9_-]+)\z}
        REFUND_PATH = %r{\A/transactions/([A-Za-z0-9_-]+)/refunds\z}

        # Statuses a refund can be made from; see Result::SETTLED.
        REFUNDABLE = Result::SETTLED

        # Error descriptions from Tpay's error-code table.
        MESSAGES = {
          "transaction_does_not_exist" => "Transaction does not exist",
          "already_refunded" => "Transaction is already refunded",
          "cannot_create_refund" => "Cannot create refund for this payment channel"
        }.freeze

        # @return [Array<Request>] every call made, in order
        attr_reader :requests

        # @return [Environment::Settings]
        attr_reader :environment

        # @param env [Symbol] which certificate host signed notifications name
        #   in `x5u`; `:sandbox` (default) or `:production`
        # @param merchant_id [String] the `id` field of notifications
        def initialize(env: Environment::DEFAULT, merchant_id: "1010")
          @environment = Environment.fetch(env)
          @merchant_id = merchant_id
          reset!
        end

        # Clears recorded calls, stored transactions and armed failures. The
        # test certificates survive, as generating them is the slow part.
        def reset!
          @requests = []
          @transactions = {}
          @sequence = 0
          @fail_next = nil
          @fail_always = nil
        end

        # Makes the next call fail. `code` is one of:
        #
        # - an HTTP status (Integer): 401 → AuthError, 429 → RateLimitError,
        #   400 → Result with success? false, …, exactly as {Status} maps it;
        # - a Tpay error code (String), e.g. "crc_not_unique", sent as a 400
        #   body (or 500 for "internal_server_error");
        # - `:connection`, which raises ConnectionError.
        #
        # A 401 stands for a persistent rejection: the real driver refreshes
        # the token once and raises AuthError when the retry is rejected too.
        def fail_next!(code:)
          @fail_next = failure(code)
        end

        # As {#fail_next!}, for every call until {#reset!}.
        def fail_always!(code:)
          @fail_always = failure(code)
        end

        # The driver contract {Client#request} calls.
        # @return [Result]
        def request(method, path, body = nil)
          json = body.nil? ? nil : JSON.generate(body)
          @requests << Request.new(method, path, json && JSON.parse(json), json)

          failure = @fail_next || @fail_always
          @fail_next = nil
          return simulate(failure) if failure

          respond(*route(method, path, json && JSON.parse(json)))
        end

        # A stored transaction, as GET would return it.
        # @return [Hash, nil]
        def transaction(transaction_id)
          found = @transactions[transaction_id.to_s]
          found && JSON.parse(JSON.generate(found))
        end

        # Settles a pending transaction as a successful payment would, and
        # returns the notification Tpay would post for it.
        #
        # @return [Delivery]
        # @raise [ArgumentError] for an unknown or non-pending transaction
        def pay!(transaction_id)
          found = pending!(transaction_id)
          now = timestamp
          # TODO(unverified): paid or correct (docs/api-notes.md, unverified
          # item 4).
          found["status"] = "correct"
          found["date"]["realization"] = now
          found["payments"]["attempts"] << { "date" => now, "paymentErrorCode" => nil }
          deliver(notification_params(found, now))
        end

        # Fully refunds a settled transaction as the merchant would through
        # `transactions.refund`, and returns the notification Tpay posts for a
        # full refund (`tr_status=chargeback`).
        #
        # @return [Delivery]
        # @raise [ArgumentError] for an unknown or unsettled transaction
        def refund!(transaction_id)
          found = @transactions.fetch(transaction_id.to_s) do
            raise ArgumentError, "no transaction #{transaction_id.inspect} in Drivers::Fake"
          end
          unless REFUNDABLE.include?(found["status"])
            raise ArgumentError, "transaction #{transaction_id} is #{found["status"]}, not settled"
          end

          now = timestamp
          found["refunds"] << { "amount" => found["amount"], "date" => now }
          found["status"] = "refund"
          deliver(notification_params(found, now).merge("tr_status" => "chargeback"))
        end

        # Records a failed payment attempt. The transaction stays pending, and
        # no notification is returned: Tpay notifies only successful payments
        # and full refunds, so a failed one produces no notification for an
        # application to handle.
        #
        # @return [nil]
        # @raise [ArgumentError] for an unknown or non-pending transaction
        def fail!(transaction_id)
          found = pending!(transaction_id)
          # 101 is "Rejected by the payer" in GetTransaction's attempt codes.
          found["payments"]["attempts"] << { "date" => timestamp, "paymentErrorCode" => "101" }
          nil
        end

        # Serves this driver's test certificates at the URLs a notification
        # names, for {Notification.verify!}'s `fetcher:`. The root is served
        # at the environment's real root URL, so verification runs every step
        # it runs in production, but only against these certificates.
        # @return [#fetch]
        def certificate_fetcher
          files = {
            signing_certificate_url => pki.signer.certificate.to_pem,
            "https://#{environment.secure_host}#{Notification::Verifier::ROOT_PATH}" => pki.root.certificate.to_pem
          }
          CertificateFiles.new(files)
        end

        # @return [Array<OpenSSL::X509::Certificate>] the test root, for
        #   {Notification.verify!}'s `trust_anchors:`
        def trust_anchors
          [pki.root.certificate]
        end

        # @return [Pki]
        def pki
          @pki ||= Pki.new
        end

        def inspect
          "#<#{self.class.name} env=#{environment.name} transactions=#{@transactions.size}>"
        end

        # A fixed set of certificate files by URL.
        class CertificateFiles
          def initialize(files)
            @files = files
          end

          def fetch(url)
            @files.fetch(url) { raise ConnectionError, "certificate fetch from #{url} answered HTTP 404" }
          end
        end

        private

        def route(method, path, body)
          return create(body) if method == :post && path == "/transactions"

          shown = TRANSACTION_PATH.match(path) if method == :get
          return show(shown[1]) if shown

          refunded = REFUND_PATH.match(path) if method == :post
          return refund(refunded[1], body) if refunded

          raise ArgumentError, "Drivers::Fake does not simulate #{method.to_s.upcase} #{path}"
        end

        def create(body)
          @sequence += 1
          transaction = {
            "transactionId" => format("01FAKE%020d", @sequence),
            "title" => format("TR-FAK-%06d", @sequence),
            "posId" => "ps_FAKEFAKEFAKEFAKE",
            "status" => "pending",
            "amount" => Amount.build(format_amount(body["amount"])),
            "currency" => body["currency"],
            "description" => body["description"],
            "hiddenDescription" => body["hiddenDescription"],
            "payer" => body["payer"],
            "date" => { "creation" => timestamp, "realization" => nil },
            "payments" => { "attempts" => [] },
            "refunds" => []
          }
          @transactions[transaction["transactionId"]] = transaction
          [200, envelope.merge(public_view(transaction)).merge(
            "transactionPaymentUrl" => "https://#{environment.secure_host}/?title=#{transaction["title"]}",
            "payer" => transaction["payer"]
          )]
        end

        def show(transaction_id)
          found = @transactions[transaction_id]
          return not_found unless found

          [200, envelope.merge(public_view(found))]
        end

        # TODO(unverified): the code Tpay answers a refund of an unpaid
        # transaction with (docs/api-notes.md, unverified item 8);
        # cannot_create_refund is the closest documented one.
        def refund(transaction_id, body)
          found = @transactions[transaction_id]
          return not_found unless found
          return failed(400, "already_refunded") if found["status"] == "refund"
          return failed(400, "cannot_create_refund") unless REFUNDABLE.include?(found["status"])

          amount = body && body["amount"] ? Amount.build(format_amount(body["amount"])) : found["amount"]
          found["refunds"] << { "amount" => amount, "date" => timestamp }
          found["status"] = "refund" if body.nil? || body["amount"].nil?
          [200, envelope.merge(public_view(found)).merge("refundsList" => found["refunds"])]
        end

        def public_view(transaction)
          transaction.except("payer", "refunds")
        end

        def respond(status_code, body)
          Status.handle(status_code, JSON.generate(body))
        end

        def simulate(failure)
          raise ConnectionError, "Tpay request failed (simulated)" if failure == :connection

          respond(*failure)
        end

        def failure(code)
          case code
          when :connection then :connection
          when Integer then [code, { "result" => "failed", "requestId" => request_id, "errors" => [] }]
          # TODO(unverified): the status that carries internal_server_error
          # (docs/api-notes.md, unverified item 9).
          when String then failed(code == "internal_server_error" ? 500 : 400, code, "simulated")
          else raise ArgumentError, "code must be an HTTP status, a Tpay error code or :connection"
          end
        end

        def not_found
          failed(404, "transaction_does_not_exist")
        end

        def failed(status_code, code, message = MESSAGES.fetch(code, code))
          error = { "errorCode" => code, "errorMessage" => message, "fieldName" => "",
                    "devMessage" => message, "docUrl" => "https://docs-api.tpay.com/en/error-codes/" }
          [status_code, { "result" => "failed", "requestId" => request_id, "errors" => [error] }]
        end

        def envelope
          { "result" => "success", "requestId" => request_id }
        end

        def request_id
          format("fake%015d", @requests.size)
        end

        def pending!(transaction_id)
          found = @transactions.fetch(transaction_id.to_s) do
            raise ArgumentError, "no transaction #{transaction_id.inspect} in Drivers::Fake"
          end
          unless found["status"] == "pending"
            raise ArgumentError,
                  "transaction #{transaction_id} is #{found["status"]}, not pending"
          end

          found
        end

        # The amount came back from JSON as a Float holding a two-decimal
        # value; its shortest text form is that value.
        def format_amount(value)
          value.is_a?(Float) ? format("%.2f", value) : value.to_s
        end

        # Field order and contents as listed under "Notification parameters".
        # md5sum is computed the way the docs describe with an empty security
        # code, which is what Tpay assumes when none is set.
        def notification_params(transaction, paid_at)
          amount = transaction["amount"].to_s
          params = {
            "id" => @merchant_id, "tr_id" => transaction["title"], "tr_date" => paid_at,
            "tr_crc" => transaction["hiddenDescription"].to_s, "tr_amount" => amount, "tr_paid" => amount,
            "tr_desc" => transaction["description"].to_s, "tr_status" => "TRUE", "tr_error" => "none",
            "tr_email" => transaction.dig("payer", "email").to_s, "tr_currency" => transaction["currency"].to_s
          }
          params["md5sum"] = Digest::MD5.hexdigest("#{@merchant_id}#{transaction["title"]}#{amount}#{params["tr_crc"]}")
          params["test_mode"] = "0"
          params
        end

        def deliver(params)
          raw_body = URI.encode_www_form(params)
          header_b64 = base64url(JSON.generate("alg" => "RS256", "x5u" => signing_certificate_url))
          signature = pki.sign("#{header_b64}.#{base64url(raw_body)}")
          Delivery.new(raw_body: raw_body, jws_header: "#{header_b64}..#{base64url(signature)}",
                       content_type: Notification::FORM)
        end

        def signing_certificate_url
          "https://#{environment.secure_host}/x509/notifications-jws.pem"
        end

        def base64url(data)
          [data].pack("m0").tr("+/", "-_").delete("=")
        end

        def timestamp
          Time.now.strftime("%Y-%m-%d %H:%M:%S")
        end
      end
    end
  end
end
