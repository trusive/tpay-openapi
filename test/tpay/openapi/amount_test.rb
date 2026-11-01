require "test_helper"
require "bigdecimal"

module Tpay
  module Openapi
    class AmountTest < Minitest::Test
      def literal(value)
        Amount.build(value).to_s
      end

      def test_formats_strings_with_two_decimals
        assert_equal "12.30", literal("12.3")
        assert_equal "12.00", literal("12")
        assert_equal "0.01", literal("0.01")
        assert_equal "7.00", literal("007")
        assert_equal "1.50", literal(" 1.5 ")
      end

      def test_formats_big_decimals_without_going_through_float
        assert_equal "12.30", literal(BigDecimal("12.3"))
        assert_equal "100.00", literal(BigDecimal("1E2"))
        assert_equal "123456789012.34", literal(BigDecimal("123456789012.34"))
      end

      def test_serializes_as_a_json_number
        assert_equal '{"amount":12.30}', JSON.generate("amount" => Amount.build("12.3"))
      end

      def test_refuses_floats
        error = assert_raises(ArgumentError) { Amount.build(12.3) }

        assert_match(/Float/, error.message)
      end

      def test_refuses_integers
        assert_raises(ArgumentError) { Amount.build(12) }
      end

      def test_refuses_more_than_two_decimals_rather_than_rounding
        assert_raises(ArgumentError) { Amount.build("12.345") }
        assert_raises(ArgumentError) { Amount.build(BigDecimal("12.345")) }
      end

      def test_refuses_zero_and_negative_amounts
        assert_raises(ArgumentError) { Amount.build("0") }
        assert_raises(ArgumentError) { Amount.build("0.00") }
        assert_raises(ArgumentError) { Amount.build("-1.00") }
        assert_raises(ArgumentError) { Amount.build(BigDecimal("-1")) }
      end

      def test_refuses_malformed_strings
        ["", "12,30", "1e2", "12.", ".5", "abc", "1 000.00"].each do |text|
          assert_raises(ArgumentError, text) { Amount.build(text) }
        end
      end

      def test_refuses_non_finite_big_decimals
        assert_raises(ArgumentError) { Amount.build(BigDecimal("NaN")) }
        assert_raises(ArgumentError) { Amount.build(BigDecimal("Infinity")) }
      end

      def test_literals_compare_by_value
        assert_equal Amount.build("1.5"), Amount.build(BigDecimal("1.50"))
      end
    end
  end
end
