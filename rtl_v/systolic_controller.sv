//=========================================================
// Synthesizable TPU Systolic Controller
//=========================================================
module systolic_controller #(
    parameter int N = 256
)(
    input  logic        clk,
    input  logic        rstn,

    // Control Handshake
    input  logic        start_i,
    output logic        done_o,

    // FIFO Status
    input  logic        weight_fifo_empty,
    input  logic        data_fifo_empty,
    input  logic        result_fifo_full,

    // FIFO Control Signals
    output logic        weight_fifo_rd_en,
    output logic        data_fifo_rd_en,
    output logic        result_fifo_wr_en,

    // Internal Buffer Selection Signals
    output logic [$clog2(N)-1:0] wr_row_sel,
    output logic [$clog2(N)-1:0] wr_col_sel,
    output logic                 buffer_wr_en,

    // Systolic Array Feed Selection Signals
    output logic [$clog2(N)-1:0] feed_idx,

    // Result Serialization Signals
    output logic [$clog2(N)-1:0] result_row_sel,
    output logic [$clog2(N)-1:0] result_col_sel,

    // Systolic Array Control Signals
    output logic        sys_en,
    output logic        clear_acc_o
);

    //---------------------------------------------------------
    // FSM State Definitions
    //---------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE         = 3'b000,
        ST_LOAD_BUFFERS = 3'b001,  // Pop N^2 elements from FIFOs to buffers
        ST_FEED         = 3'b010,  // Feed data from buffers to array (N cycles)
        ST_WAIT         = 3'b011,  // Wait for array propagation (2N cycles)
        ST_READOUT      = 3'b100,  // Serialized readout of results (N^2 cycles)
        ST_DONE         = 3'b101   // Assert done handshake
    } state_t;

    state_t state, next_state;

    //---------------------------------------------------------
    // Counters
    //---------------------------------------------------------
    localparam int K = $clog2(N);
    localparam int CNT_W = 2 * K + 1;

    logic [CNT_W-1:0] cycle_cnt;
    logic [CNT_W-1:0] cycle_cnt_next;

    //---------------------------------------------------------
    // Sequential Logic
    //---------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state     <= ST_IDLE;
            cycle_cnt <= '0;
        end else begin
            state     <= next_state;
            cycle_cnt <= cycle_cnt_next;
        end
    end

    //---------------------------------------------------------
    // FSM Next-State & Counter Logic
    //---------------------------------------------------------
    always_comb begin
        next_state     = state;
        cycle_cnt_next = cycle_cnt;

        case (state)
            ST_IDLE: begin
                cycle_cnt_next = '0;
                if (start_i) begin
                    next_state = ST_LOAD_BUFFERS;
                end
            end

            ST_LOAD_BUFFERS: begin
                // Pop N^2 elements. Check if both input FIFOs have data.
                // We only increment count when data is actually read (handshake).
                if (!weight_fifo_empty && !data_fifo_empty) begin
                    if (cycle_cnt == N*N - 1) begin
                        cycle_cnt_next = '0;
                        next_state     = ST_FEED;
                    end else begin
                        cycle_cnt_next = cycle_cnt + 1'b1;
                    end
                end
            end

            ST_FEED: begin
                // Feed parallel vectors for N cycles
                if (cycle_cnt == N - 1) begin
                    cycle_cnt_next = '0;
                    next_state     = ST_WAIT;
                end else begin
                    cycle_cnt_next = cycle_cnt + 1'b1;
                end
            end

            ST_WAIT: begin
                // Wait for propagation (2N cycles)
                if (cycle_cnt == 2*N - 1) begin
                    cycle_cnt_next = '0;
                    next_state     = ST_READOUT;
                end else begin
                    cycle_cnt_next = cycle_cnt + 1'b1;
                end
            end

            ST_READOUT: begin
                // Serialized readout of N^2 results into 32-bit FIFO.
                // We only increment if the result FIFO is not full.
                if (!result_fifo_full) begin
                    if (cycle_cnt == N*N - 1) begin
                        cycle_cnt_next = '0;
                        next_state     = ST_DONE;
                    end else begin
                        cycle_cnt_next = cycle_cnt + 1'b1;
                    end
                end
            end

            ST_DONE: begin
                next_state = ST_IDLE;
            end

            default: begin
                next_state = ST_IDLE;
            end
        endcase
    end

    //---------------------------------------------------------
    // FSM Output Control Generation
    //---------------------------------------------------------
    always_comb begin
        // Default Outputs
        weight_fifo_rd_en = 1'b0;
        data_fifo_rd_en   = 1'b0;
        result_fifo_wr_en = 1'b0;
        
        wr_row_sel     = '0;
        wr_col_sel     = '0;
        buffer_wr_en   = 1'b0;
        
        feed_idx       = '0;
        
        result_row_sel = '0;
        result_col_sel = '0;
        
        sys_en         = 1'b0;
        clear_acc_o    = 1'b0;
        done_o         = 1'b0;

        case (state)
            ST_IDLE: begin
                // No operations
            end

            ST_LOAD_BUFFERS: begin
                // Read from scalar input FIFOs one-by-one
                if (!weight_fifo_empty && !data_fifo_empty) begin
                    weight_fifo_rd_en = 1'b1;
                    data_fifo_rd_en   = 1'b1;
                    
                    // Write to internal buffers at index (row, col)
                    wr_row_sel   = cycle_cnt[2*K-1 : K];
                    wr_col_sel   = cycle_cnt[K-1 : 0];
                    buffer_wr_en = 1'b1;
                end
            end

            ST_FEED: begin
                sys_en   = 1'b1;
                feed_idx = cycle_cnt[K-1 : 0];
                
                // Pulsed clear on cycle 0
                if (cycle_cnt == 0) begin
                    clear_acc_o = 1'b1;
                end
            end

            ST_WAIT: begin
                // Keep the array running to propagate wavefronts
                sys_en = 1'b1;
            end

            ST_READOUT: begin
                // Readout results element-by-element
                if (!result_fifo_full) begin
                    result_fifo_wr_en = 1'b1;
                    result_row_sel    = cycle_cnt[2*K-1 : K];
                    result_col_sel    = cycle_cnt[K-1 : 0];
                end
                sys_en = 1'b0; // Keep the array frozen during readout
            end

            ST_DONE: begin
                done_o = 1'b1;
            end
        endcase
    end

endmodule
