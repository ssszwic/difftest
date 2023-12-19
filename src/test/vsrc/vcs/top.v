/***************************************************************************************
* Copyright (c) 2020-2023 Institute of Computing Technology, Chinese Academy of Sciences
* Copyright (c) 2020-2021 Peng Cheng Laboratory
*
* DiffTest is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

`define STEP_WIDTH 8

`ifdef NANHUV3_FUNCOV
	`include "./../../dcov/focv_include.sv"
`endif

module tb_top();

import "DPI-C" function void set_bin_file(string bin);
import "DPI-C" function void set_flash_bin(string bin);
import "DPI-C" function void set_diff_ref_so(string diff_so);
import "DPI-C" function void set_no_diff();
import "DPI-C" function void simv_init();
`ifndef PALLADIUM
import "DPI-C" function int simv_nstep(int step);
`endif // PALLADIUM

reg         clock;
reg         reset;
reg  [63:0] io_logCtrl_log_begin;
reg  [63:0] io_logCtrl_log_end;
wire [63:0] io_logCtrl_log_level;
wire        io_perfInfo_clean;
wire        io_perfInfo_dump;
wire        io_uart_out_valid;
wire [ 7:0] io_uart_out_ch;
wire        io_uart_in_valid;
wire [ 7:0] io_uart_in_ch;
wire [`STEP_WIDTH - 1:0] difftest_step;

string bin_file;
string flash_bin_file;
string wave_type;
string diff_ref_so;
reg [63:0] max_cycles;

initial begin
  clock = 0;
  reset = 1;
  // enable waveform
  if ($test$plusargs("dump-wave")) begin
    $value$plusargs("dump-wave=%s", wave_type);
    if (wave_type == "vpd") begin
      $vcdplusfile("simv.vpd");
      $vcdpluson;
    end
`ifdef CONSIDER_FSDB
    else if (wave_type == "fsdb") begin
      $display("Dumping FSDB Waveform for DEBUG is active !!!");
      $fsdbAutoSwitchDumpfile(10000,"tb_top.fsdb",60);
      $fsdbDumpfile("tb_top.fsdb");
      if ($test$plusargs("mda"))
        $fsdbDumpMDA();
      $fsdbDumpvars(0,tb_top.sim);
    end
`endif
    else begin
      $display("unknown wave file format, want [vpd, fsdb] but:%s\n", wave_type);
      $finish();
    end
  end
  // log begin
  if ($test$plusargs("b")) begin
    $value$plusargs("b=%d", io_logCtrl_log_begin);
  end
  else begin
    io_logCtrl_log_begin = 0;
  end
  // log end
  if ($test$plusargs("e")) begin
    $value$plusargs("e=%d", io_logCtrl_log_end);
  end
  else begin
    io_logCtrl_log_end = 0;
  end
  // workload: bin file
  if ($test$plusargs("workload")) begin
    $value$plusargs("workload=%s", bin_file);
    set_bin_file(bin_file);
  end
  // boot flash image: bin file
  if ($test$plusargs("flash")) begin
    $value$plusargs("flash=%s", flash_bin_file);
    set_flash_bin(flash_bin_file);
  end
  // diff-test golden model: nemu-so
  if ($test$plusargs("diff")) begin
    $value$plusargs("diff=%s", diff_ref_so);
    set_diff_ref_so(diff_ref_so);
  end
  // disable diff-test
  if ($test$plusargs("no-diff")) begin
    set_no_diff();
  end
  // max cycles to execute, no limit for default
  max_cycles = 0;
  if ($test$plusargs("max-cycles")) begin
    $value$plusargs("max-cycles=%d", max_cycles);
    $display("set max cycles: %d", max_cycles);
  end

  // Note: reset delay #100 should be larger than RANDOMIZE_DELAY
  #100 reset = 0;
end
always #1 clock <= ~clock;

SimTop sim(
  .clock(clock),
  .reset(reset),
  .io_logCtrl_log_begin(io_logCtrl_log_begin),
  .io_logCtrl_log_end(io_logCtrl_log_end),
  .io_logCtrl_log_level(io_logCtrl_log_level),
  .io_perfInfo_clean(io_perfInfo_clean),
  .io_perfInfo_dump(io_perfInfo_dump),
  .io_uart_out_valid(io_uart_out_valid),
  .io_uart_out_ch(io_uart_out_ch),
  .io_uart_in_valid(io_uart_in_valid),
  .io_uart_in_ch(io_uart_in_ch),
  .difftest_step(difftest_step)
);

assign io_logCtrl_log_level = 0;
assign io_perfInfo_clean = 0;
assign io_perfInfo_dump = 0;
assign io_uart_in_ch = 8'hff;

`ifdef NANHUV3_FUNCOV
	`include "./../../fcov/fcov_connect.sv"
`endif


always @(posedge clock) begin
  if (!reset && io_uart_out_valid) begin
    if(io_uart_out_ch[7] == 0) begin
      $fwrite(32'h8000_0001, "%c", io_uart_out_ch);
      $fflush();
    end
    else begin
      $display("\033[32mHIT GOOD TRAP!\033[0m");
      $finish;
    end
  end
end

reg [`STEP_WIDTH - 1:0] difftest_step_delay;
always @(posedge clock) begin
  if (reset) begin
    difftest_step_delay <= 0;
  end
  else begin
    difftest_step_delay <= difftest_step;
  end
end

`ifdef PALLADIUM
wire simv_result;
GfifoControl gfifo(
  .clock(clock),
  .reset(reset),
  .step(difftest_step_delay),
  .simv_result(simv_result)
);
`endif

reg [63:0] n_cycles;
always @(posedge clock) begin
  if (reset) begin
    n_cycles <= 64'h0;
  end
  else begin
    n_cycles <= n_cycles + 64'h1;

    // max cycles
    if (max_cycles > 0 && n_cycles >= max_cycles) begin
      $display("EXCEEDED MAX CYCLE: %d", max_cycles);
      $finish();
    end

    // difftest
    if (!n_cycles) begin
      simv_init();
    end
`ifdef PALLADIUM
    else if (simv_result) begin
      $display("DIFFTEST FAILED at cycle %d", n_cycles);
      $finish();
    end
`else
    else if (|difftest_step_delay) begin
      // check errors
      if (simv_nstep(difftest_step_delay)) begin
        $display("DIFFTEST FAILED at cycle %d", n_cycles);
        $finish();
      end
    end
`endif // PALLADIUM
  end
end

endmodule
