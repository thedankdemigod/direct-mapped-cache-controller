// -----------------------------------------------------------------------------
// cache_controller.sv
//
// Direct-mapped, write-through, write-allocate cache controller.
//   8-bit address : tag[7:5] | index[4:2] | offset[1:0]
//   8 lines x 4 bytes, 256-byte main memory behind a byte-at-a-time interface.
//
// Behavior is specified in docs/architecture.md, docs/fsm_design.md and
// docs/datapath_design.md. Section order in this file is fixed:
//   1. State encoding
//   2. Declarations
//   3. Derived fields
//   4. Next-state logic and array write controls (combinational)
//   5. Moore output decode
//   6. Sequential block: state, request registers, counter, buffer, response
//   7. Array block
//   8. Simulation-only assertions
//
// Rule: the array block (section 7) never references `state`.
// -----------------------------------------------------------------------------
module cache_controller (
    input  logic       clk,
    input  logic       rst,            // synchronous, active high

    // CPU -> cache
    input  logic       cpu_req,
    input  logic [7:0] cpu_addr,
    input  logic       cpu_read,
    input  logic       cpu_write,
    input  logic [7:0] cpu_wdata,

    // cache -> CPU
    output logic       cache_ready,
    output logic       cache_valid,
    output logic [7:0] cache_rdata,

    // cache -> memory
    output logic       cache_m_req,
    output logic       cache_m_read,
    output logic       cache_m_write,
    output logic [7:0] cache_m_addr,
    output logic [7:0] cache_m_wdata,

    // memory -> cache
    input  logic       mem_valid,
    input  logic [7:0] mem_rdata
);

    // -------------------------------------------------------------------------
    // 1. State encoding
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        LOOKUP    = 3'd1,
        FETCH     = 3'd2,
        COMMIT    = 3'd3,
        WRITE_MEM = 3'd4
    } state_t;

    // -------------------------------------------------------------------------
    // 2. Declarations
    // -------------------------------------------------------------------------
    state_t       state, next_state;

    // Retained request (loaded on IDLE -> LOOKUP)
    logic [7:0]   req_addr;
    logic         req_is_write;
    logic [7:0]   req_wdata;

    // Burst counter and line buffer
    logic [1:0]   cnt;
    logic [7:0]   temp_buffer [0:3];

    // Registered response
    logic         cache_valid_r;
    logic [7:0]   cache_rdata_r;

    // Storage arrays
    logic         valid_arr [0:7];
    logic [2:0]   tag_arr   [0:7];
    logic [7:0]   data_arr  [0:7][0:3];

    // Array write controls
    logic         array_byte_we;
    logic         array_line_we;

    // -------------------------------------------------------------------------
    // 3. Derived fields
    // -------------------------------------------------------------------------
    logic [2:0]   tag;
    logic [2:0]   index;
    logic [1:0]   offset;
    logic [7:0]   block_base;
    logic         hit;

    assign tag        = req_addr[7:5];
    assign index      = req_addr[4:2];
    assign offset     = req_addr[1:0];
    assign block_base = {req_addr[7:2], 2'b00};
    assign hit        = valid_arr[index] && (tag_arr[index] == tag);

    // -------------------------------------------------------------------------
    // 4. Next-state logic and array write controls
    // -------------------------------------------------------------------------
    always_comb begin
        next_state    = state;
        array_byte_we = 1'b0;
        array_line_we = 1'b0;

        case (state)
            IDLE: begin
                if (cpu_req) next_state = LOOKUP;
            end

            LOOKUP: begin
                if (hit) begin
                    if (req_is_write) begin
                        array_byte_we = 1'b1;       // exactly once per write hit
                        next_state    = WRITE_MEM;
                    end else begin
                        next_state    = IDLE;
                    end
                end else begin
                    next_state = FETCH;
                end
            end

            FETCH: begin
                if (mem_valid && cnt == 2'd3) next_state = COMMIT;
            end

            COMMIT: begin
                array_line_we = 1'b1;
                next_state    = req_is_write ? WRITE_MEM : IDLE;
            end

            WRITE_MEM: begin
                if (mem_valid) next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // 5. Moore output decode (state only)
    //    "Don't care" outputs are driven to 0 to keep waveforms free of X.
    // -------------------------------------------------------------------------
    assign cache_ready   = (state == IDLE);
    assign cache_m_req   = (state == FETCH) || (state == WRITE_MEM);
    assign cache_m_read  = (state == FETCH);
    assign cache_m_write = (state == WRITE_MEM);

    always_comb begin
        case (state)
            FETCH:     cache_m_addr = block_base | {6'b0, cnt};
            WRITE_MEM: cache_m_addr = req_addr;
            default:   cache_m_addr = 8'h00;
        endcase
    end

    assign cache_m_wdata = (state == WRITE_MEM) ? req_wdata : 8'h00;

    // Registered response
    assign cache_valid = cache_valid_r;
    assign cache_rdata = cache_rdata_r;

    // -------------------------------------------------------------------------
    // 6. Sequential block
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= IDLE;
            cnt           <= 2'd0;
            cache_valid_r <= 1'b0;
        end else begin
            state         <= next_state;
            cache_valid_r <= 1'b0;                  // default: clears the pulse

            case (state)
                IDLE: begin
                    if (cpu_req) begin
                        req_addr     <= cpu_addr;
                        req_is_write <= cpu_write;  // write wins if both set;
                        req_wdata    <= cpu_wdata;  // neither set -> read
                    end
                end

                LOOKUP: begin
                    if (hit) begin
                        if (!req_is_write) begin
                            cache_rdata_r <= data_arr[index][offset];
                            cache_valid_r <= 1'b1;
                        end
                    end else begin
                        cnt <= 2'd0;
                    end
                end

                FETCH: begin
                    if (mem_valid) begin
                        // Capture mux: merges the CPU byte on a write miss
                        temp_buffer[cnt] <= (req_is_write && cnt == offset)
                                            ? req_wdata : mem_rdata;
                        if (cnt != 2'd3) cnt <= cnt + 2'd1;
                    end
                end

                COMMIT: begin
                    if (!req_is_write) begin
                        cache_rdata_r <= temp_buffer[offset];
                        cache_valid_r <= 1'b1;
                    end
                end

                WRITE_MEM: begin
                    if (mem_valid) cache_valid_r <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 7. Array block (does not reference `state`)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) begin
                valid_arr[i] <= 1'b0;
                tag_arr[i]   <= 3'd0;
                for (int j = 0; j < 4; j++) data_arr[i][j] <= 8'h00;
            end
        end else begin
            if (array_byte_we)
                data_arr[index][offset] <= req_wdata;

            if (array_line_we) begin
                valid_arr[index] <= 1'b1;
                tag_arr[index]   <= tag;
                for (int j = 0; j < 4; j++) data_arr[index][j] <= temp_buffer[j];
            end
        end
    end

    // -------------------------------------------------------------------------
    // 8. Simulation-only assertions
    // -------------------------------------------------------------------------
    // synthesis translate_off
    logic seen_reset = 1'b0;
    logic valid_prev = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) seen_reset <= 1'b1;
        valid_prev <= cache_valid;
    end

    always @(posedge clk) begin
        if (seen_reset && !rst) begin
            assert (!(cache_m_read && cache_m_write))
                else $error("cache_m_read and cache_m_write both high");

            assert (!(array_byte_we && array_line_we))
                else $error("both array write controls asserted");

            assert (!(array_byte_we || array_line_we) ||
                    state == LOOKUP || state == COMMIT)
                else $error("array written outside LOOKUP/COMMIT");

            assert (!(cache_valid && valid_prev))
                else $error("cache_valid high for more than one cycle");

            assert (!mem_valid || cache_m_req)
                else $error("mem_valid asserted while cache_m_req is low");
        end
    end
    // synthesis translate_on

endmodule
