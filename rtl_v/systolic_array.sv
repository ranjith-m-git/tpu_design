//=========================================================
// Synthesizable N x N Systolic Array (Strictly Scalar Ports)
//=========================================================
module systolic_array #(
    parameter int N = 256
)(
    input  logic        clk,
    input  logic        rstn,
    input  logic        en,

    // Global clear accumulator pulse
    input  logic        clear_acc_in,

    // Boundary Inputs (Scalar)
    input  logic [7:0]  weight_in,    // Scalar weight input
    input  logic [15:0] data_in,      // Scalar activation input

    // Buffer Control
    input  logic        buffer_wr_en,
    input  logic [$clog2(N)-1:0] wr_row_sel,
    input  logic [$clog2(N)-1:0] wr_col_sel,

    // Parallel Feeding Selector
    input  logic [$clog2(N)-1:0] feed_idx,

    // Serialized Readout Selector
    input  logic [$clog2(N)-1:0] result_row_sel,
    input  logic [$clog2(N)-1:0] result_col_sel,

    // Scalar Result Output
    output logic [31:0] result_out
);

    //---------------------------------------------------------
    // Internal Matrix Buffers
    //---------------------------------------------------------
    logic [7:0]  weight_buffer [0:N-1][0:N-1];
    logic [15:0] data_buffer   [0:N-1][0:N-1];

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (int r = 0; r < N; r++) begin
                for (int c = 0; c < N; c++) begin
                    weight_buffer[r][c] <= 8'd0;
                    data_buffer[r][c]   <= 16'd0;
                end
            end
        end else if (buffer_wr_en) begin
            weight_buffer[wr_row_sel][wr_col_sel] <= weight_in;
            data_buffer[wr_row_sel][wr_col_sel]   <= data_in;
        end
    end

    //---------------------------------------------------------
    // Unpacking Vectors from Internal Buffers
    //---------------------------------------------------------
    logic [7:0]  weight_array [0:N-1];
    logic [15:0] data_array   [0:N-1];

    always_comb begin
        for (int k = 0; k < N; k++) begin
            weight_array[k] = weight_buffer[feed_idx][k];
            data_array[k]   = data_buffer[k][feed_idx];
        end
    end

    //---------------------------------------------------------
    // Input Skewing Registers
    //---------------------------------------------------------
    // Weights are skewed by column index: column j is delayed by j cycles.
    // Activations and clear_acc are skewed by row index: row i is delayed by i cycles.
    
    logic [7:0]  weight_skewed [0:N-1];
    logic [15:0] data_skewed   [0:N-1];
    logic        clear_acc_skewed [0:N-1];

    generate
        genvar s;
        for (s = 0; s < N; s = s + 1) begin : SKEW_LOGIC

            // --- Weight Skewing (Column s delayed by s cycles) ---
            if (s == 0) begin
                assign weight_skewed[0] = weight_array[0];
            end else begin
                logic [7:0] weight_delay [1:s];
                always_ff @(posedge clk or negedge rstn) begin
                    if (!rstn) begin
                        for (int k = 1; k <= s; k++) weight_delay[k] <= 8'd0;
                    end else if (en) begin
                        weight_delay[1] <= weight_array[s];
                        for (int k = 2; k <= s; k++) weight_delay[k] <= weight_delay[k-1];
                    end
                end
                assign weight_skewed[s] = weight_delay[s];
            end

            // --- Activation and Clear Skewing (Row s delayed by s cycles) ---
            if (s == 0) begin
                assign data_skewed[0] = data_array[0];
                assign clear_acc_skewed[0] = clear_acc_in;
            end else begin
                logic [15:0] data_delay [1:s];
                logic        clear_delay [1:s];
                always_ff @(posedge clk or negedge rstn) begin
                    if (!rstn) begin
                        for (int k = 1; k <= s; k++) begin
                            data_delay[k]  <= 16'd0;
                            clear_delay[k] <= 1'b0;
                        end
                    end else if (en) begin
                        data_delay[1]  <= data_array[s];
                        clear_delay[1] <= clear_acc_in;
                        for (int k = 2; k <= s; k++) begin
                            data_delay[k]  <= data_delay[k-1];
                            clear_delay[k] <= clear_delay[k-1];
                        end
                    end
                end
                assign data_skewed[s] = data_delay[s];
                assign clear_acc_skewed[s] = clear_delay[s];
            end

        end
    endgenerate

    //---------------------------------------------------------
    // PE Grid Interconnects
    //---------------------------------------------------------
    logic [7:0]  weight_bus [0:N-1][0:N-1];
    logic [15:0] data_bus   [0:N-1][0:N-1];
    logic        clear_acc_bus [0:N-1][0:N-1];
    logic [31:0] result_grid [0:N-1][0:N-1];

    //---------------------------------------------------------
    // PE Grid Instantiation
    //---------------------------------------------------------
    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : ROWS
            for (j = 0; j < N; j = j + 1) begin : COLS

                process_element u_pe (
                    .clk(clk),
                    .rstn(rstn),
                    .en(en),

                    // Clear Accumulator Propagation
                    .clear_acc_in(
                        (j == 0) ? clear_acc_skewed[i] : clear_acc_bus[i][j-1]
                    ),
                    .clear_acc_out(
                        clear_acc_bus[i][j]
                    ),

                    // Weight Propagation (Top to Bottom)
                    .weight_in(
                        (i == 0) ? weight_skewed[j] : weight_bus[i-1][j]
                    ),
                    .weight_out(
                        weight_bus[i][j]
                    ),

                    // Data Propagation (Left to Right)
                    .data_in(
                        (j == 0) ? data_skewed[i] : data_bus[i][j-1]
                    ),
                    .data_out(
                        data_bus[i][j]
                    ),

                    // Output Accumulator
                    .acc_out(
                        result_grid[i][j]
                    )
                );

            end
        end
    endgenerate

    //---------------------------------------------------------
    // Output Multiplexer for Serialized Readout
    //---------------------------------------------------------
    assign result_out = result_grid[result_row_sel][result_col_sel];

endmodule
