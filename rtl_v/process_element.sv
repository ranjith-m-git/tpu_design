//=========================================================
// Synthesizable Processing Element (PE)
//=========================================================
module process_element
(
    input  logic        clk,
    input  logic        rstn,
    input  logic        en,

    input  logic        clear_acc_in,
    output logic        clear_acc_out,

    //------------------------------------------------------
    // Systolic operands
    //------------------------------------------------------
    input  logic [7:0]  weight_in,   // FP8 Weight (E4M3)
    input  logic [15:0] data_in,     // BF16 Activation

    output logic [7:0]  weight_out,  // Forwarded Weight (to bottom PE)
    output logic [15:0] data_out,    // Forwarded Data (to right PE)

    //------------------------------------------------------
    // Accumulator output
    //------------------------------------------------------
    output logic [31:0] acc_out
);

    //------------------------------------------------------
    // Multiplier output (FP32)
    //------------------------------------------------------
    logic [31:0] product_fp32;

    //------------------------------------------------------
    // Accumulator registers
    //------------------------------------------------------
    logic [31:0] acc_reg;
    logic [31:0] acc_next;

    //------------------------------------------------------
    // FP8 × BF16 Multiplier
    //------------------------------------------------------
    fp8_bf16_mult u_fp8_bf16_mult
    (
        .fp8_a_i  (weight_in),
        .bf16_b_i (data_in),
        .result_o (product_fp32)
    );

    //------------------------------------------------------
    // FP32 Adder for Accumulation
    //------------------------------------------------------
    fp32_adder u_adder (
        .a_i(acc_reg),
        .b_i(product_fp32),
        .sum_o(acc_next)
    );
    
    //------------------------------------------------------
    // Sequential logic for pipeline registers and accumulator
    //------------------------------------------------------
    always_ff @(posedge clk or negedge rstn)
    begin
        if(!rstn) begin
            acc_reg       <= 32'h00000000;
            weight_out    <= 8'd0;
            data_out      <= 16'd0;
            clear_acc_out <= 1'b0;
        end
        else if(en)
        begin
            weight_out    <= weight_in;
            data_out      <= data_in;
            clear_acc_out <= clear_acc_in;
            
            if(clear_acc_in)
                acc_reg <= product_fp32;
            else
                acc_reg <= acc_next;
        end
    end

    assign acc_out = acc_reg;

endmodule
