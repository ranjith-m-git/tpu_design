module fp32_adder
(
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,

    output logic [31:0] sum_o
);

    //=========================================================
    // Simplified IEEE754 FP32 Adder
    //=========================================================
    //
    // FP32 Format
    //
    //      31      30:23          22:0
    //   +------+-----------+-------------+
    //   | Sign | Exponent  | Fraction    |
    //   +------+-----------+-------------+
    //
    // Value:
    //
    //      (-1)^sign
    //      ×
    //      (1.fraction)
    //      ×
    //      2^(exponent-127)
    //
    // This adder performs:
    //
    //      result = a + b
    //
    // Simplifications:
    //
    //  - No NaN support
    //  - No Infinity support
    //  - No Denormal support
    //  - No Rounding logic
    //  - No Overflow handling
    //  - No Underflow handling
    //
    //=========================================================



    //---------------------------------------------------------
    // Field Extraction
    //---------------------------------------------------------

    logic       sign_a;
    logic [7:0] exp_a;
    logic [22:0] frac_a;

    logic       sign_b;
    logic [7:0] exp_b;
    logic [22:0] frac_b;

    assign sign_a = a_i[31];
    assign exp_a  = a_i[30:23];
    assign frac_a = a_i[22:0];

    assign sign_b = b_i[31];
    assign exp_b  = b_i[30:23];
    assign frac_b = b_i[22:0];



    //---------------------------------------------------------
    // Restore Hidden Leading 1
    //---------------------------------------------------------
    //
    // Stored:
    //
    //      1.xxx...
    //
    // Fraction field stores only:
    //
    //      xxx...
    //
    // We restore:
    //
    //      1.xxx...
    //
    //---------------------------------------------------------

    logic [23:0] mant_a;
    logic [23:0] mant_b;

    assign mant_a = {1'b1, frac_a};
    assign mant_b = {1'b1, frac_b};



    //---------------------------------------------------------
    // Exponent Alignment
    //---------------------------------------------------------
    //
    // Example:
    //
    //      1.0 × 2^10
    //    + 1.0 × 2^8
    //
    // Smaller exponent mantissa must be shifted
    // right until exponents match.
    //
    //---------------------------------------------------------

    logic [7:0] exp_large;
    logic [23:0] mant_large;
    logic [23:0] mant_small;
    logic sign_large;
    logic sign_small;

    logic [7:0] exp_diff;

    always_comb begin

        if (exp_a >= exp_b) begin

            exp_large  = exp_a;

            mant_large = mant_a;
            mant_small = mant_b >> (exp_a - exp_b);

            sign_large = sign_a;
            sign_small = sign_b;

            exp_diff   = exp_a - exp_b;

        end
        else begin

            exp_large  = exp_b;

            mant_large = mant_b;
            mant_small = mant_a >> (exp_b - exp_a);

            sign_large = sign_b;
            sign_small = sign_a;

            exp_diff   = exp_b - exp_a;

        end

    end



    //---------------------------------------------------------
    // Mantissa Add/Subtract
    //---------------------------------------------------------
    //
    // Same sign:
    //
    //      add mantissas
    //
    // Different sign:
    //
    //      subtract smaller from larger
    //
    //---------------------------------------------------------

    logic [24:0] mant_sum;
    logic result_sign;

    always_comb begin

        if (sign_large == sign_small) begin

            //---------------------------------
            // Addition
            //---------------------------------

            mant_sum    = mant_large + mant_small;
            result_sign = sign_large;

        end
        else begin

            //---------------------------------
            // Subtraction
            //---------------------------------

            if (mant_large >= mant_small) begin

                mant_sum    = mant_large - mant_small;
                result_sign = sign_large;

            end
            else begin

                mant_sum    = mant_small - mant_large;
                result_sign = sign_small;

            end

        end

    end



    //---------------------------------------------------------
    // Normalization
    //---------------------------------------------------------
    //
    // Desired form:
    //
    //      1.xxxxxxxxx
    //
    //---------------------------------------------------------

    logic [7:0]  exp_norm;
    logic [23:0] mant_norm;

    integer i;

    always_comb begin

        exp_norm  = exp_large;
        mant_norm = mant_sum[23:0];

        //-------------------------------------
        // Addition overflow
        //
        // Example:
        //
        //      1.8 + 1.7
        //          =
        //      11.xxxxx
        //
        //-------------------------------------

        if (mant_sum[24]) begin

            mant_norm = mant_sum[24:1];
            exp_norm  = exp_large + 1;

        end

        //-------------------------------------
        // Subtraction normalization
        //-------------------------------------

        else begin

            for (i = 0; i < 24; i++) begin

                if ((mant_norm[23] == 1'b0) &&
                    (mant_norm != 24'd0))
                begin
                    mant_norm = mant_norm << 1;
                    exp_norm  = exp_norm - 1;
                end
            end

        end

    end



    //---------------------------------------------------------
    // Result Packing
    //---------------------------------------------------------
    //
    // Remove hidden leading one.
    //
    //---------------------------------------------------------

    always_comb begin

        //-------------------------------------
        // Exact zero
        //-------------------------------------

        if (mant_sum == 0) begin

            sum_o = 32'd0;

        end
        else begin

            sum_o =
            {
                result_sign,
                exp_norm,
                mant_norm[22:0]
            };

        end

    end

endmodule