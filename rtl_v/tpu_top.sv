//=========================================================
// Synthesizable Top-Level TPU Engine (Strictly Scalar Connections)
//=========================================================
module tpu_top #(
    parameter int N = 8
)(
    input  logic        clk,
    input  logic        rstn,

    // Control Handshake
    input  logic        start_i,
    output logic        done_o,

    // Weight FIFO Input Interface (Scalar)
    input  logic        weight_fifo_wr_en,
    input  logic [7:0]  weight_fifo_wr_data,
    output logic        weight_fifo_full,
    output logic [$clog2(N*N):0] weight_fifo_count,

    // Activation Data FIFO Input Interface (Scalar)
    input  logic        data_fifo_wr_en,
    input  logic [15:0] data_fifo_wr_data,
    output logic        data_fifo_full,
    output logic [$clog2(N*N):0] data_fifo_count,

    // Result FIFO Output Interface (Scalar)
    input  logic        result_fifo_rd_en,
    output logic [31:0] result_fifo_rd_data,
    output logic        result_fifo_empty,
    output logic [$clog2(N*N):0] result_fifo_count
);

    //---------------------------------------------------------
    // Internal Control & Handshake Signals
    //---------------------------------------------------------
    logic        weight_fifo_rd_en;
    logic [7:0]  weight_fifo_rd_data;
    logic        weight_fifo_empty;

    logic        data_fifo_rd_en;
    logic [15:0] data_fifo_rd_data;
    logic        data_fifo_empty;

    logic        result_fifo_wr_en;
    logic [31:0] result_fifo_wr_data;
    logic        result_fifo_full;

    logic [$clog2(N)-1:0] wr_row_sel;
    logic [$clog2(N)-1:0] wr_col_sel;
    logic                 buffer_wr_en;

    logic [$clog2(N)-1:0] feed_idx;

    logic [$clog2(N)-1:0] result_row_sel;
    logic [$clog2(N)-1:0] result_col_sel;

    logic sys_en;
    logic clear_acc;

    //---------------------------------------------------------
    // Scalar FIFOs Instantiation
    //---------------------------------------------------------
    
    // Weight FIFO (Depth = N*N, Width = 8)
    sync_fifo #(
        .WIDTH(8),
        .DEPTH(N*N)
    ) u_weight_fifo (
        .clk(clk),
        .rstn(rstn),
        .wr_en(weight_fifo_wr_en),
        .wr_data(weight_fifo_wr_data),
        .rd_en(weight_fifo_rd_en),
        .rd_data(weight_fifo_rd_data),
        .full(weight_fifo_full),
        .empty(weight_fifo_empty),
        .count(weight_fifo_count)
    );

    // Activation Data FIFO (Depth = N*N, Width = 16)
    sync_fifo #(
        .WIDTH(16),
        .DEPTH(N*N)
    ) u_data_fifo (
        .clk(clk),
        .rstn(rstn),
        .wr_en(data_fifo_wr_en),
        .wr_data(data_fifo_wr_data),
        .rd_en(data_fifo_rd_en),
        .rd_data(data_fifo_rd_data),
        .full(data_fifo_full),
        .empty(data_fifo_empty),
        .count(data_fifo_count)
    );

    // Result FIFO (Depth = N*N, Width = 32)
    sync_fifo #(
        .WIDTH(32),
        .DEPTH(N*N)
    ) u_result_fifo (
        .clk(clk),
        .rstn(rstn),
        .wr_en(result_fifo_wr_en),
        .wr_data(result_fifo_wr_data),
        .rd_en(result_fifo_rd_en),
        .rd_data(result_fifo_rd_data),
        .full(result_fifo_full),
        .empty(result_fifo_empty),
        .count(result_fifo_count)
    );

    //---------------------------------------------------------
    // Systolic Controller Instantiation
    //---------------------------------------------------------
    systolic_controller #(
        .N(N)
    ) u_controller (
        .clk(clk),
        .rstn(rstn),
        
        .start_i(start_i),
        .done_o(done_o),

        .weight_fifo_empty(weight_fifo_empty),
        .data_fifo_empty(data_fifo_empty),
        .result_fifo_full(result_fifo_full),

        .weight_fifo_rd_en(weight_fifo_rd_en),
        .data_fifo_rd_en(data_fifo_rd_en),
        .result_fifo_wr_en(result_fifo_wr_en),

        .wr_row_sel(wr_row_sel),
        .wr_col_sel(wr_col_sel),
        .buffer_wr_en(buffer_wr_en),

        .feed_idx(feed_idx),

        .result_row_sel(result_row_sel),
        .result_col_sel(result_col_sel),

        .sys_en(sys_en),
        .clear_acc_o(clear_acc)
    );

    //---------------------------------------------------------
    // Systolic Array Instantiation (Direct Scalar Ports)
    //---------------------------------------------------------
    systolic_array #(
        .N(N)
    ) u_systolic_array (
        .clk(clk),
        .rstn(rstn),
        .en(sys_en),
        
        .clear_acc_in(clear_acc),
        
        .weight_in(weight_fifo_rd_data),
        .data_in(data_fifo_rd_data),
        
        .buffer_wr_en(buffer_wr_en),
        .wr_row_sel(wr_row_sel),
        .wr_col_sel(wr_col_sel),
        
        .feed_idx(feed_idx),
        
        .result_row_sel(result_row_sel),
        .result_col_sel(result_col_sel),
        
        .result_out(result_fifo_wr_data)
    );

endmodule
