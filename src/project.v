/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_hariri4534_audioplayback (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

localparam LINE_SIZE = 8;
// bidir pinouts
//    uio_in            | uio_out
// [7] -                | [7] - audio_out
// [6] -                | [6] - VAL:rd_req
// [5] - SD3            | [5] - SD3
// [4] - SD2            | [4] - SD2
// [3] - unused         | [3] - SCK
// [2] - SD1            | [2] - SD1
// [1] - SD0            | [1] - SD0
// [0] - unused         | [0] - CS

// ui_in
// [1] playback_speed
// [0] playback_speed
`ifdef VAL
`define VAL_OR_GL_TEST
`elsif GL_TEST
`define VAL_OR_GL_TEST
`endif

  wire pwm_out;
  wire sample_valid;

  wire [3:0] qspi_din   = {uio_in[5],   uio_in[4],  uio_in[2], uio_in[1]};
  wire [3:0] qspi_dout;

  wire [23:0] addr;
  wire        rd;
  wire        done;
  wire [(LINE_SIZE*8)-1:0]  line;
  wire [7:0]  sample;

  wire        qspi_sck;
  wire        qspi_ce_n;
  wire        qspi_douten;
  wire        done_w_sck;

  // QSPI Output Assignments
  assign uio_out[0] = qspi_ce_n;
  assign uio_out[1] = qspi_dout[0];
  assign uio_out[2] = qspi_dout[1];
  assign uio_out[3] = qspi_sck;
  assign uio_out[4] = qspi_dout[2];
  assign uio_out[5] = qspi_dout[3];
`ifdef VAL_OR_GL_TEST
  assign uio_out[6] = done_w_sck;
`else
  assign uio_out[6] = 1'b0;
`endif
  assign uio_out[7]   = pwm_out;
  // assign uio_out[7] is not set here, it's used for something else?
  // Comment says [7] - audio_out. Let's check uo_out[7] vs uio_out[7].
  // line 47: assign uo_out[7] = pwm_out;
  // line 22: // [7] - start_prog | [7] - audio_out
  
  // QSPI Output Enable Assignments
  assign uio_oe[0] = 1'b1; // CS is output
  assign uio_oe[1] = qspi_douten;
  assign uio_oe[2] = qspi_douten;
  assign uio_oe[3] = 1'b1; // SCK is output
  assign uio_oe[4] = qspi_douten;
  assign uio_oe[5] = qspi_douten;
  assign uio_oe[6] = 1'b0;
  assign uio_oe[7] = 1'b1;

  // All other output pins assigned to 0 (overriding line 43-45)
  assign uo_out[6:0] = 7'b0;
  assign uo_out[7]   = pwm_out;
/*
  pwm u_pwm (
    .clk            (clk),
    .rst_n          (rst_n),
    .sample_i       (sample),
    .sample_valid_i (sample_valid),
    .pwm_o          (pwm_out)
  );
*/
  assign done_w_sck = done & qspi_sck;

  playback_ctrl 
  #(
    .LINE_SIZE(LINE_SIZE)
  ) u_playback (
    .clk            (clk),
    .rst_n          (rst_n),
    .data_i         (line),
    .speed_ctl_i    ({ui_in[1], ui_in[0]}),
    .rd_en_i        (done_w_sck),

    .addr_o         (addr),
    .rd_o           (rd),
    .pwm_o          (pwm_out)

  );

  EF_QSPI_XIP_CTRL 
  #(
      .NUM_LINES      ( 1  ), 
      .LINE_SIZE      ( LINE_SIZE ), 
      .RESET_CYCLES   ( 999 ) 
  )
  u_EF_QSPI_XIP_CTRL
  (

    .clk     (clk),
    .rst_n   (rst_n),
    .addr    (addr),
    .rd      (rd),
    .done    (done),
    .line    (line), /* 8-bit PCM data of NUM_LINES size */
    // External Interface to Quad I/O
    .sck     ( qspi_sck    ),
    .ce_n    ( qspi_ce_n   ),
    .din     ( qspi_din    ),
    .dout    ( qspi_dout   ),
    .douten  ( qspi_douten )
);


  // List all unused inputs to prevent warnings
  wire _unused = &{ena, 1'b0};

endmodule
