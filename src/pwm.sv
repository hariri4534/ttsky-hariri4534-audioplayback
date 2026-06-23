`default_nettype none

// PWM audio output.
// The output is high for sample clocks out of every 255 clocks.
// This means a sample of 0 is always off, a sample of 255 is always on.
module pwm (
    input wire logic clk,
    input wire logic rst_n,

    input wire logic [7:0] sample_i,
    input wire logic [7:0] count_d_i,
    input wire logic sample_valid_i,

    output wire logic pwm_o
);

  logic [7:0] count_q;
  logic [7:0] count_d;
  logic pwm_q, pwm_d;

  always_ff @( posedge clk ) begin
    if (!rst_n) begin
      count_q <= '0;
      pwm_q   <= '0;
    end else if (sample_valid_i) begin
      count_q <= count_d;
      pwm_q   <= pwm_d;
    end    
  end

  assign count_d = (count_q == 8'hfe) ? {8{1'b0}} : count_q + 1'b1;
  assign pwm_d   = (count_d < sample_i);

  assign pwm_o = pwm_q;

endmodule
