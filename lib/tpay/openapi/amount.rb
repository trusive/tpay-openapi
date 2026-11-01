module Tpay
  module Openapi
    # Money going out to Tpay.
    #
    # The API types amounts as JSON numbers with two decimal places
    # ("multipleOf 0.01"). A Float cannot hold most of those exactly, so one
    # is refused outright rather than formatted. A BigDecimal or a decimal
    # String is turned into the number literal directly, without passing
    # through Float.
    #
    # BigDecimal is recognised but not required: since Ruby 3.4 it is a
    # bundled gem rather than part of the standard library, and this library
    # has no runtime dependencies.
    module Amount
      DECIMAL = /\A(\d+)(?:\.(\d{1,2}))?\z/

      # A JSON number literal. `JSON.generate` writes whatever `to_json`
      # returns, so `12.30` goes on the wire exactly as written.
      class Literal
        # @return [String] the amount with two decimals, e.g. "12.30"
        attr_reader :to_s

        def initialize(text)
          @to_s = text.freeze
          freeze
        end

        def to_json(*)
          to_s
        end

        def ==(other)
          other.is_a?(Literal) && other.to_s == to_s
        end

        alias eql? ==

        def hash
          to_s.hash
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end

      module_function

      # @param value [BigDecimal, String] a positive amount with at most two
      #   decimal places
      # @return [Literal]
      # @raise [ArgumentError] for a Float, an Integer, a non-positive amount,
      #   or one with more than two decimal places (never rounded silently)
      def build(value)
        text = decimal_text(value)
        match = DECIMAL.match(text)
        raise ArgumentError, "amount must be a decimal with at most two places, got #{value.inspect}" unless match

        whole = match[1].sub(/\A0+(?=\d)/, "")
        cents = (match[2] || "").ljust(2, "0")
        if "#{whole}#{cents}".delete("0").empty?
          raise ArgumentError,
                "amount must be greater than zero, got #{value.inspect}"
        end

        Literal.new("#{whole}.#{cents}")
      end

      def decimal_text(value)
        case value
        when String then value.strip
        when ->(v) { big_decimal?(v) }
          raise ArgumentError, "amount must be finite, got #{value.inspect}" unless value.finite?

          value.to_s("F")
        else
          raise ArgumentError, "amount must be a BigDecimal or a String, got #{value.class} " \
                               "(#{value.inspect}); a Float cannot represent most amounts exactly"
        end
      end

      def big_decimal?(value)
        defined?(::BigDecimal) && value.is_a?(::BigDecimal)
      end
    end
  end
end
