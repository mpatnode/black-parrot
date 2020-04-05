
module bp_be_hardfloat_fpu_long
 import bp_common_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_be_pkg::*;
 import bp_be_hardfloat_pkg::*;
 import bp_common_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_be_pkg::*;
  (input clk_i
   , input reset_i

   , input [long_width_gp-1:0]     a_i
   , input [long_width_gp-1:0]     b_i
   , input bp_be_fp_fu_op_e        op_i
   , input                         v_i
   , output logic                  ready_o

   // Input/output precision of results. Applies to both integer and 
   //   floating point operands and results
   , input bp_be_fp_pr_e          ipr_i
   , input bp_be_fp_pr_e          opr_i
   // The IEEE rounding mode to use
   , input rv64_frm_e             rm_i

   , output [long_width_gp-1:0]   data_o
   , output rv64_fflags_s         fflags_o
   , output logic                 v_o
   , input                        yumi_i
   );

  // The control bits control tininess, which is fixed in RISC-V
  wire [`floatControlWidth-1:0] control_li = `flControl_default;

  bp_be_hardfloat_fpu_recode_in
   #(.els_p(2))
   recode_in
    (.fp_i({b_i, a_i})

     ,.ipr_i(ipr_i)

     ,.fp_o()
     ,.rec_o({b_rec_li, a_rec_li})
     ,.nan_o()
     ,.snan_o()
     ,.sub_o()
     );

  wire

  logic [dp_rec_width_gp-1:0] rec_result_lo;
  logic rec_result_v_lo;
  rv64_fflags_s rec_result_fflags_lo;
  divSqrtRecFn_small
   #(.expWidth(dp_exp_width_gp)
     ,.sigWidth(dp_sig_width_gp)
     )
   divSqrt
    (.clock(clk_i)
     ,.nReset(~reset_i)
     ,.control(control_li)

     ,.a()
     ,.b()
     ,.roundingMode()
     ,.sqrtOp()
     ,.inReady(ready_o)
     ,.inValid(v_i)

     ,.out(rec_result_lo)
     ,.outValid(rec_result_v_lo)
     ,.exceptionFlags(rec_result_fflags_lo)

     // Whether the incoming op was square root or not, unused
     ,.sqrtOpOut()
     );

  // Recoded result selection
  //
  logic [long_width_gp-1:0] result_lo;
  rv64_fflags_s result_fflags_lo;
  bp_be_hardfloat_fpu_recode_out
   recode_out
    (.rec_i()
     ,.rec_eflags_i()
     ,.opr_i(opr_i)
     ,.rm_i(rm_i)

     ,.result_o(result_lo)
     ,.result_eflags_o(result_fflags_lo)
     );

  bsg_dff_reset_en
   #(.width_p(1))
   pending_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(v_o & ~yumi_i);

     ,.data_i()
     ,.data_o()
     );

  bsg_one_fifo
   #(.width_p(long_width_gp+$bits(rv64_fflags_s)))
   out_fifo
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.data_i(result_lo)
     ,.v_i(result_)
     ,.ready_o()

     ,.data_o({data_o, fflags_o})
     ,.v_o(v_o)
     ,.yumi_i(yumi_i)
     );

endmodule

