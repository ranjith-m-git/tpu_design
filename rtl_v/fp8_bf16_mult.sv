module fp8_bf16_mult
(
    input  logic [7:0]  fp8_a_i,
    input  logic [15:0] bf16_b_i,

    //=========================================================
    // FP32 Output
    //
    // IEEE-754 Single Precision Format
    //
    //  Bit:
    //
    //   31      30:23           22:0
    // +----+---------------+-----------+
    // | S  | Exponent[7:0] | Fraction  |
    // +----+---------------+-----------+
    //
    // Sign     : 1 bit
    // Exponent : 8 bits
    // Fraction : 23 bits
    //
    // Exponent Bias = 127
    //
    //=========================================================
    output logic [31:0] result_o
);

    //=========================================================
    // Simplified FP8 × BF16 Floating Point Multiplier
    //=========================================================
    //
    // Datapath:
    //
    //         FP8 Weight
    //              |
    //              v
    //           Multiply
    //              ^
    //              |
    //       BF16 Activation
    //
    //              |
    //              v
    //         FP32 Product
    //
    //
    // This block performs ONLY floating-point multiplication.
    //
    // No accumulation is performed here.
    //
    // In a TPU Processing Element:
    //
    //       FP8 Weight
    //            \
    //             × --------+
    //            /          |
    //     BF16 Activation   |
    //                       v
    //                 FP32 Accumulator
    //
    // Mathematical operation:
    //
    //      Acc_next
    //          =
    //      Acc_old
    //          +
    //      (Weight × Activation)
    //
    // This module computes only:
    //
    //      Weight × Activation
    //
    //=========================================================



    //---------------------------------------------------------
    // FP8 Decode (E4M3 Format)
    //---------------------------------------------------------
    //
    // FP8 Layout
    //
    //    7      6:3      2:0
    // +-----+---------+-------+
    // | Sign| Exponent| Frac  |
    // +-----+---------+-------+
    //
    // Exponent Bias = 7
    //
    // Stored exponent:
    //
    //      ea
    //
    // Actual exponent:
    //
    //      Ea = ea - 7
    //
    // Hidden leading one:
    //
    //      1.frac
    //
    // Example:
    //
    //      frac = 101
    //
    //      mantissa = 1.101₂
    //
    //---------------------------------------------------------

    logic sign_a;
    logic [3:0] exp_a;
    logic [2:0] frac_a;

    logic [4:0] mant_a;

    assign sign_a = fp8_a_i[7];
    assign exp_a  = fp8_a_i[6:3];
    assign frac_a = fp8_a_i[2:0];

    assign mant_a = {1'b1, frac_a};



    //---------------------------------------------------------
    // BF16 Decode
    //---------------------------------------------------------
    //
    // BF16 Layout
    //
    //   15      14:7      6:0
    // +-----+----------+-------+
    // | Sign| Exponent | Frac  |
    // +-----+----------+-------+
    //
    // Exponent Bias = 127
    //
    // Actual exponent:
    //
    //      Eb = eb - 127
    //
    // Hidden leading one:
    //
    //      1.frac
    //
    //---------------------------------------------------------

    logic sign_b;
    logic [7:0] exp_b;
    logic [6:0] frac_b;

    logic [7:0] mant_b;

    assign sign_b = bf16_b_i[15];
    assign exp_b  = bf16_b_i[14:7];
    assign frac_b = bf16_b_i[6:0];

    assign mant_b = {1'b1, frac_b};



    //---------------------------------------------------------
    // Sign Calculation
    //---------------------------------------------------------
    //
    // Floating-point multiplication sign rule:
    //
    //     (+) × (+) = +
    //     (+) × (-) = -
    //     (-) × (+) = -
    //     (-) × (-) = +
    //
    // Therefore:
    //
    //      Sign_out
    //          =
    //      Sign_a XOR Sign_b
    //
    //---------------------------------------------------------

    logic sign_out;

    assign sign_out = sign_a ^ sign_b;



    //---------------------------------------------------------
    // Exponent Addition
    //---------------------------------------------------------
    //
    // FP8 exponent:
    //
    //      Ea = ea - 7
    //
    // BF16 exponent:
    //
    //      Eb = eb - 127
    //
    // Product exponent:
    //
    //      Eout = Ea + Eb
    //
    // Substitute:
    //
    //      Eout
    //          =
    //      (ea - 7)
    //          +
    //      (eb - 127)
    //
    //      Eout
    //          =
    //      ea + eb - 134
    //
    //
    // Output format is FP32.
    //
    // FP32 exponent bias = 127.
    //
    // Stored exponent:
    //
    //      eout
    //          =
    //      Eout + 127
    //
    // Therefore:
    //
    //      eout
    //          =
    //      ea + eb - 7
    //
    // Notice:
    //
    //      Only FP8 bias must be removed.
    //
    //---------------------------------------------------------

    localparam int FP8_BIAS = 7;

    logic signed [9:0] exp_sum;

    always_comb begin

        exp_sum =
              $signed({1'b0, exp_a})
            + $signed({1'b0, exp_b})
            - FP8_BIAS;

    end



    //---------------------------------------------------------
    // Mantissa Multiplication
    //---------------------------------------------------------
    //
    // FP8 mantissa:
    //
    //      1.xxx
    //
    // Width = 5 bits
    //
    // BF16 mantissa:
    //
    //      1.xxxxxxx
    //
    // Width = 8 bits
    //
    // Multiply:
    //
    //      5-bit × 8-bit
    //
    // Product width:
    //
    //      13 bits
    //
    //
    // Range:
    //
    //      1.0 × 1.0 = 1.0
    //
    //      up to
    //
    //      1.875 × 1.992
    //          ≈ 3.73
    //
    // Therefore product can be:
    //
    //      1.xxxxxxxxxxx
    //
    // or
    //
    //      10.xxxxxxxxxx
    //
    //---------------------------------------------------------

    logic [12:0] mant_prod;

    always_comb begin
        mant_prod = mant_a * mant_b;
    end



    //---------------------------------------------------------
    // Mantissa Normalization
    //---------------------------------------------------------
    //
    // Floating-point numbers must be stored as:
    //
    //      1.xxxxxxxxx
    //
    //
    // Case 1:
    //
    //      Product = 10.xxxxxxxxx
    //
    // Example:
    //
    //      1.75 × 1.75
    //
    //          =
    //
    //      11.0001...
    //
    // Action:
    //
    //      Shift right by 1
    //
    //      Increment exponent
    //
    //
    // Case 2:
    //
    //      Product = 1.xxxxxxxxx
    //
    // Already normalized.
    //
    //
    // FP32 fraction field:
    //
    //      23 bits
    //
    // Available product precision:
    //
    //      ~11 useful fraction bits
    //
    // Remaining lower bits are padded
    // with zeros.
    //
    //---------------------------------------------------------

    logic [7:0]  exp_norm;
    logic [22:0] frac_norm;

    always_comb begin

        if (mant_prod[12]) begin

            exp_norm = exp_sum + 1;

            frac_norm =
            {
                mant_prod[11:0],
                11'd0
            };

        end
        else begin

            exp_norm = exp_sum;

            frac_norm =
            {
                mant_prod[10:0],
                12'd0
            };

        end

    end



    //---------------------------------------------------------
    // FP32 Result Packing
    //---------------------------------------------------------
    //
    // IEEE-754 Single Precision
    //
    //    31      30:23          22:0
    // +------+-----------+-------------+
    // | Sign | Exponent  | Fraction    |
    // +------+-----------+-------------+
    //
    // This simplified model does NOT handle:
    //
    //  • NaN
    //  • Infinity
    //  • Denormal numbers
    //  • Rounding modes
    //  • Overflow
    //  • Underflow
    //
    //---------------------------------------------------------

    always_comb begin

        if ((exp_a == 0) || (exp_b == 0))
            result_o = 32'h00000000;
        else
            result_o =
            {
                sign_out,
                exp_norm,
                frac_norm
            };

    end

endmodule