`default_nettype none

module playback_ctrl #(parameter LINE_SIZE=16) (
    input  wire        clk,
    input  wire        rst_n,

    // Interface to QSPI Controller
    input  wire [(LINE_SIZE*8)-1:0]  data_i,    // Data from Flash (assuming LINE_SIZE=1)
    input  wire        rd_en_i,   // 'done' signal from QSPI
    input  wire [1:0]  speed_ctl_i, 
    output reg  [23:0] addr_o,    // Current read address
    output reg         rd_o,      // Trigger a new read

    // PWM Output
    output reg         pwm_o
);

`define PTR_W $clog2(LINE_SIZE)-1:0;
localparam ADDR_PAD = 24 - $clog2(LINE_SIZE) - 1;
logic [LINE_SIZE*8-1:0] data_buf_q;
logic [$clog2(LINE_SIZE):0] addr_offset;

logic [1:0] speed_ctl_q;
logic [1:0] sample_ptr_increment;
logic sample_toggle_q;
logic [23:0] addr_q, addr_nxt;
logic [7:0] count_q, count_nxt;
logic [$clog2(LINE_SIZE)-1:0] sample_ptr_q;
logic [$clog2(LINE_SIZE)-1:0] sample_ptr_nxt;
logic pwm_d, pwm_q;
logic [7:0] pwm_data;
logic next_sample;
logic gen_read_req;
logic rd_req_q, rd_req_nxt;
logic rd_req_pulse_q, rd_req_pulse_next;
logic start_count_q;
logic rd_en_q;

always_ff @(posedge clk) begin
    if (~rst_n) begin
        rd_en_q <= '0;
    end else begin
        rd_en_q <= rd_en_i;
    end
end

always_ff @( posedge clk ) begin
    if (~rst_n) begin
        data_buf_q <= '0;
        start_count_q <= '0;
    end else if (rd_en_q) begin
        data_buf_q <= data_i;
        start_count_q <= '1;
    end
end

// Speed control
// 00 | 0.5x speed  (same sample played twice)
// 01 | 1x   speed  (sample move as normal)
// 10 | 1.5  speed  (move by 1 sample, followed by 2 sample)
// 11 | 2x   speed  (skip every other sample)
// |count[5:0] is so that speed_ctl_en to avoid jitter in latching speed_ctl_i
logic speed_ctl_en;
assign speed_ctl_en = |count_q[5:0] & ~|sample_ptr_q;
always_ff @( posedge clk ) begin
    if (~rst_n) begin
        speed_ctl_q <= '0;
    end else if (speed_ctl_en) begin
        speed_ctl_q <= speed_ctl_i;
    end
end 

// audio playback management
// count up to 255 cycles
always_ff @(posedge clk) begin
    if (~rst_n) begin
        count_q <= '0;
        sample_ptr_q <= '0;
    end else if (start_count_q) begin
        count_q <= count_nxt;
        sample_ptr_q <= sample_ptr_nxt;
    end
end

always_ff @(posedge clk) begin
    if (~rst_n) begin
        sample_toggle_q <= '0;
    end else if (next_sample) begin
        sample_toggle_q <= ~sample_toggle_q;
    end
end

assign next_sample      = (count_q == 8'hfe);
assign count_nxt        = next_sample ? '0 : count_q + 1'b1;

always_comb begin
    casez ({speed_ctl_q, sample_toggle_q})
      3'b000 : sample_ptr_increment = 2'b00;
      3'b001 : sample_ptr_increment = 2'b01;
      3'b01? : sample_ptr_increment = 2'b01;
      3'b100 : sample_ptr_increment = 2'b01;
      3'b101 : sample_ptr_increment = 2'b10;
      3'b11? : sample_ptr_increment = 2'b10;
     default : sample_ptr_increment = 'x;
    endcase
end

assign sample_ptr_nxt   = next_sample ? sample_ptr_q + { {2{1'b0}}, sample_ptr_increment }
                                      : sample_ptr_q;
//TODO: align gen_read_req with QSPI cycles to make sure PWM output stays the same until 255
//TODO: remove magic number 162 that aligns read request assert to QSPI controller to data coming in
assign gen_read_req = ((speed_ctl_q == 2'b00) &   sample_toggle_q & (&sample_ptr_q) // 0.5x speed, when last ptr is played twice
                    |  (speed_ctl_q == 2'b01) &  (&sample_ptr_q)                    // 1x   speed, when ptr is last
                    |  (speed_ctl_q == 2'b10) &  (sample_ptr_q == 3'd6)             // 1.5x speed, when ptr is 6
                    |  (speed_ctl_q == 2'b11) &  (sample_ptr_q == 3'd6) )           // 2x speed, when ptr is at 6
                       & (count_q == 8'd162); 


// Binary coded mux to select sample data for PWM
assign pwm_data = {8{sample_ptr_q == 3'd0}}  & data_buf_q[0   +: 8]
                | {8{sample_ptr_q == 3'd1}}  & data_buf_q[8   +: 8]
                | {8{sample_ptr_q == 3'd2}}  & data_buf_q[16  +: 8]
                | {8{sample_ptr_q == 3'd3}}  & data_buf_q[24  +: 8]
                | {8{sample_ptr_q == 3'd4}}  & data_buf_q[32  +: 8]
                | {8{sample_ptr_q == 3'd5}}  & data_buf_q[40  +: 8]
                | {8{sample_ptr_q == 3'd6}}  & data_buf_q[48  +: 8]
                | {8{sample_ptr_q == 3'd7}}  & data_buf_q[56  +: 8];

assign pwm_d = count_nxt < pwm_data;

always_ff @( posedge clk ) begin
    if (!rst_n) begin
        pwm_q   <= '0;
    end else if (start_count_q) begin
        pwm_q   <= pwm_d;
    end    
end

always_ff @(posedge clk) begin
    if (~rst_n) begin
        rd_req_q    <= '1;
        addr_q      <= '0;
        rd_req_pulse_q  <= '0;
    end else begin
        rd_req_q    <= start_count_q & gen_read_req;
        addr_q      <= addr_nxt;
        rd_req_pulse_q <= rd_req_q & ~rd_req_pulse_q;
    end
end

assign addr_offset[$clog2(LINE_SIZE)]       = 1'b1;
assign addr_offset[$clog2(LINE_SIZE)-1:0]   = 4'b0000;
assign addr_nxt = rd_en_q ? addr_q + { {ADDR_PAD{1'b0}}, addr_offset }
                          : addr_q;

assign rd_o     = rd_req_pulse_q;
assign addr_o   = addr_q;
assign pwm_o    = pwm_q;

`ifdef FORMAL
    reg f_past_valid = 0;
    // start in reset
    initial assume(reset);
    always @(posedge clk) begin

        f_past_valid <=1;

        _counter_ptr_assert_: assert property (@(posedge clk) gen_read_req  |=> ~|sample_ptr_q);
    end


`endif

endmodule
