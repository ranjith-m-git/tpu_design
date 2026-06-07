//=========================================================
// Parameterized Synchronous FIFO
//=========================================================
module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 256
)(
    input  logic             clk,
    input  logic             rstn,
    
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    
    output logic             full,
    output logic             empty,
    output logic [$clog2(DEPTH):0] count
);

    localparam int ADDR_W = $clog2(DEPTH);

    logic [WIDTH-1:0] fifo_mem [0:DEPTH-1];
    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;
    logic [ADDR_W:0]   status_cnt;

    assign full  = (status_cnt == DEPTH);
    assign empty = (status_cnt == 0);
    assign count = status_cnt;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            status_cnt <= '0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    fifo_mem[wr_ptr] <= wr_data;
                    wr_ptr     <= wr_ptr + 1'b1;
                    status_cnt <= status_cnt + 1'b1;
                end
                2'b01: begin
                    rd_ptr     <= rd_ptr + 1'b1;
                    status_cnt <= status_cnt - 1'b1;
                end
                2'b11: begin
                    fifo_mem[wr_ptr] <= wr_data;
                    wr_ptr     <= wr_ptr + 1'b1;
                    rd_ptr     <= rd_ptr + 1'b1;
                end
                default: begin
                    // Do nothing
                end
            endcase
        end
    end

    // Continuous read data assignment
    assign rd_data = fifo_mem[rd_ptr];

endmodule
