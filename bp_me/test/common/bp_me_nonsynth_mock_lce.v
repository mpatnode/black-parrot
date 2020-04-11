/**
 * bp_me_nonsynth_mock_lce.v
 *
 * This mock LCE behaves like a mock D$. It connects to a trace replay module and to the BP ME.
 * The trace replay format is defined in bp_me_nonsynth_pkg.vh.
 *
 * Allowable startup sequences:
 * 1. while freeze is high, sync command arrives, LCE transitions to normal mode
 * 2. freeze goes low without any sync commands arriving, LCE will operate in uncached only mode
 *
 *
 */

module tag_lookup
  import bp_common_pkg::*;
  import bp_cce_pkg::*;
  #(parameter assoc_p="inv"
    , parameter ptag_width_p="inv"
    , localparam tag_s_width_lp=($bits(bp_coh_states_e)+ptag_width_p)
    , localparam lg_assoc_lp=`BSG_SAFE_CLOG2(assoc_p)
   )
  (input [assoc_p-1:0][tag_s_width_lp-1:0] tag_set_i
   , input [ptag_width_p-1:0] ptag_i
   , input [lg_assoc_lp-1:0] lru_way_i
   , input [assoc_p-1:0] dirty_bits_i
   , output logic hit_o
   , output logic dirty_o
   , output logic [lg_assoc_lp-1:0] way_o
   , output bp_coh_states_e state_o
  );

  `declare_bp_cce_dir_entry_s(ptag_width_p);
  dir_entry_s [assoc_p-1:0] tags;
  assign tags = tag_set_i;

  logic [assoc_p-1:0] hits;
  genvar i;
  generate
  for (i = 0; i < assoc_p; i=i+1) begin
    assign hits[i] = ((tags[i].tag == ptag_i) && (tags[i].state != e_COH_I));
  end
  endgenerate

  logic hit_lo;
  logic [lg_assoc_lp-1:0] way_lo;
  bsg_encode_one_hot
    #(.width_p(assoc_p))
  hits_to_way_id
    (.i(hits)
     ,.addr_o(way_lo)
     ,.v_o(hit_lo)
    );

  // hit_o is set if tag matched and coherence state was any valid state
  assign hit_o = |hits;
  assign way_o = way_lo;
  assign dirty_o = (tags[way_o].state == e_COH_M) | (tags[way_o].state == e_COH_O);
  assign state_o = tags[way_o].state;

endmodule

module bp_me_nonsynth_mock_lce
  import bp_common_pkg::*;
  import bp_common_aviary_pkg::*;
  import bp_cce_pkg::*;
  import bp_me_nonsynth_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_half_core_cfg
    `declare_bp_proc_params(bp_params_p)

    , parameter axe_trace_p = 0
    , parameter skip_init_p = 0

    , localparam block_size_in_bytes_lp=(cce_block_width_p / 8)

    , localparam lce_opcode_width_lp=$bits(bp_me_nonsynth_lce_opcode_e)
    , localparam tr_ring_width_lp=`bp_me_nonsynth_lce_tr_pkt_width(paddr_width_p, dword_width_p)

    , localparam block_offset_bits_lp=`BSG_SAFE_CLOG2(block_size_in_bytes_lp)

    , localparam sets_p = icache_sets_p
    , localparam assoc_p = icache_assoc_p

    , localparam lg_sets_lp=`BSG_SAFE_CLOG2(sets_p)
    , localparam lg_assoc_lp=`BSG_SAFE_CLOG2(assoc_p)

    , localparam ptag_width_lp=(paddr_width_p-lg_sets_lp-block_offset_bits_lp)

    , localparam lg_num_cce_lp=`BSG_SAFE_CLOG2(num_cce_p)

    `declare_bp_lce_cce_if_header_widths(cce_id_width_p, lce_id_width_p, paddr_width_p, assoc_p)
    `declare_bp_lce_cce_if_widths(cce_id_width_p, lce_id_width_p, paddr_width_p, assoc_p, dword_width_p, cce_block_width_p)

  )
  (
    input                                                   clk_i
    ,input                                                  reset_i
    ,input                                                  freeze_i

    ,input [lce_id_width_p-1:0]                             lce_id_i

    ,input [tr_ring_width_lp-1:0]                           tr_pkt_i
    ,input                                                  tr_pkt_v_i
    ,output logic                                           tr_pkt_yumi_o

    ,output logic [tr_ring_width_lp-1:0]                    tr_pkt_o
    ,output logic                                           tr_pkt_v_o
    ,input                                                  tr_pkt_ready_i

    // LCE-CCE Interface
    // input: valid & ready (command in goes to bsg_two_fifo)
    // output: valid & ready
    ,output logic [lce_cce_req_width_lp-1:0]                lce_req_o
    ,output logic                                           lce_req_v_o
    ,input                                                  lce_req_ready_i

    ,output logic [lce_cce_resp_width_lp-1:0]               lce_resp_o
    ,output logic                                           lce_resp_v_o
    ,input                                                  lce_resp_ready_i

    ,input [lce_cmd_width_lp-1:0]                           lce_cmd_i
    ,input                                                  lce_cmd_v_i
    ,output logic                                           lce_cmd_ready_o

    ,output logic [lce_cmd_width_lp-1:0]                    lce_cmd_o
    ,output logic                                           lce_cmd_v_o
    ,input                                                  lce_cmd_ready_i
  );

  initial begin
    assert(dword_width_p == 64) else
      $error("dword_width_p must be 64");
    assert(cce_block_width_p % 8 == 0) else
      $error("cce_block_width_p must be evenly divisible by 8");
  end

  // LCE-CCE interface structs
  `declare_bp_lce_cce_if(cce_id_width_p, lce_id_width_p, paddr_width_p, assoc_p, dword_width_p, cce_block_width_p);

  // Tag+State struct
  `declare_bp_cce_dir_entry_s(ptag_width_lp);

  // Structs for output messages
  bp_lce_cce_req_s lce_req;
  bp_lce_cce_resp_s lce_resp;
  bp_lce_cmd_s lce_cmd_lo;
  assign lce_req_o = lce_req;
  assign lce_resp_o = lce_resp;
  assign lce_cmd_o = lce_cmd_lo;

  // FIFO to buffer LCE commands from ME
  logic lce_cmd_v, lce_cmd_yumi;
  bp_lce_cmd_s lce_cmd, lce_cmd_r, lce_cmd_n;

  bsg_two_fifo
    #(.width_p(lce_cmd_width_lp))
  lce_cmd_fifo
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     // command from ME
     ,.ready_o(lce_cmd_ready_o)
     ,.data_i(lce_cmd_i)
     ,.v_i(lce_cmd_v_i)
     // command to mock LCE
     ,.v_o(lce_cmd_v)
     ,.data_o(lce_cmd)
     ,.yumi_i(lce_cmd_yumi)
    );

  // Current set and way for tag, dirty bits, and data array operations
  logic [lg_sets_lp-1:0] cur_set_r, cur_set_n;
  logic [lg_assoc_lp-1:0] cur_way_r, cur_way_n;

  // Tags
  dir_entry_s [sets_p-1:0][assoc_p-1:0] tags, tag_next, tag_next_n;
  logic [sets_p-1:0][assoc_p-1:0] tag_w, tag_w_n;

  // Dirty bits
  logic [sets_p-1:0][assoc_p-1:0] dirty_w, dirty_w_n;
  logic [sets_p-1:0][assoc_p-1:0] dirty_bits, dirty_bits_next, dirty_bits_n;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      cur_set_r <= '0;
      cur_way_r <= '0;
      tag_w <= '0;
      tag_next <= '0;
      tags <= '0;
      dirty_w <= '0;
      dirty_bits <= '0;
      dirty_bits_next <= '0;
    end else begin
      cur_set_r <= cur_set_n;
      cur_way_r <= cur_way_n;
      tag_w <= tag_w_n;
      tag_next <= tag_next_n;
      dirty_w <= dirty_w_n;
      dirty_bits_next <= dirty_bits_n;
      for (integer i = 0; i < sets_p; i=i+1) begin
        for (integer j = 0; j < assoc_p; j=j+1) begin
          if (tag_w[i][j]) begin
            tags[i][j] <= tag_next[i][j];
          end
          if (dirty_w[i][j]) begin
            dirty_bits[i][j] <= dirty_bits_next[i][j];
          end
        end
      end
    end
  end

  // async read of tags at specified set and way
  dir_entry_s tag_cur;
  assign tag_cur = tags[cur_set_r][cur_way_r];

  // Data
  logic [sets_p-1:0][assoc_p-1:0][cce_block_width_p-1:0] data;
  logic [sets_p-1:0][assoc_p-1:0] data_w, data_w_n;
  logic [cce_block_width_p-1:0] data_next, data_next_n, data_mask, data_mask_n;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      data_w <= '0;
      data_mask <= '0;
      data_next <= '0;
      data <= '0;
    end else begin
      data_w <= data_w_n;
      data_mask <= data_mask_n;
      data_next <= data_next_n;
      for (integer i = 0; i < sets_p; i=i+1) begin
        for (integer j = 0; j < assoc_p; j=j+1) begin
          if (data_w[i][j]) begin
            for (integer k = 0; k < cce_block_width_p; k=k+1) begin
              if (data_mask[k]) begin
                data[i][j][k] <= data_next[k];
              end else begin
                data[i][j][k] <= data[i][j][k];
              end
            end
          end
        end
      end
    end
  end

  // async read of data at specified set and way
  logic [cce_block_width_p-1:0] data_cur;
  assign data_cur = data[cur_set_r][cur_way_r];

  `declare_bp_me_nonsynth_lce_tr_pkt_s(paddr_width_p, dword_width_p);

  // miss status handling register definition for current trace replay command
  typedef struct packed {
    logic miss;
    logic [cce_id_width_p-1:0] cce;
    logic [paddr_width_p-1:0] paddr;
    logic uncached;
    logic dirty;
    logic store_op;
    logic upgrade;
    logic [lg_assoc_lp-1:0] lru_way;
    logic tag_received;
    logic data_received;
    logic transfer_received;
  } mshr_s;

  `define mshr_width $bits(mshr_s)

  // miss status handling register
  mshr_s mshr_r, mshr_n;

  // current command being processed
  bp_me_nonsynth_lce_tr_pkt_s cmd, cmd_n, tr_cmd_pkt, tr_pkt_lo;
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      cmd <= '0;
      mshr_r <= '0;
    end else begin
      cmd <= cmd_n;
      mshr_r <= mshr_n;
    end
  end
  assign tr_cmd_pkt = tr_pkt_i;
  assign tr_pkt_o = tr_pkt_lo;

  // some useful signals from the current trace replay command
  logic store_op, load_op, signed_op, byte_op, word_op, double_op, half_op;
  logic [1:0] op_size;
  logic [2:0] dword_offset;
  logic [2:0] byte_offset;
  assign store_op = cmd.cmd[3];
  assign load_op = ~cmd.cmd[3];
  assign signed_op = ~cmd.cmd[2];
  assign op_size = cmd.cmd[1:0];
  assign double_op = (cmd.cmd[1:0] == 2'b11);
  assign word_op = (cmd.cmd[1:0] == 2'b10);
  assign half_op = (cmd.cmd[1:0] == 2'b01);
  assign byte_op = (cmd.cmd[1:0] == 2'b00);
  assign dword_offset = cmd.paddr[5:3];
  assign byte_offset = cmd.paddr[2:0];

  // Data word (64-bit) targeted by current trace replay command
  logic [dword_width_p-1:0] load_data;
  assign load_data = data_cur[dword_width_p*dword_offset +: dword_width_p];
  logic word_sigext, half_sigext, byte_sigext;
  logic [31:0] load_word;
  logic [15:0] load_half;
  logic [7:0] load_byte;

  bsg_mux #(
    .width_p(32)
    ,.els_p(2)
  ) word_mux (
    .data_i(load_data)
    ,.sel_i(byte_offset[2])
    ,.data_o(load_word)
  );
  
  bsg_mux #(
    .width_p(16)
    ,.els_p(4)
  ) half_mux (
    .data_i(load_data)
    ,.sel_i(byte_offset[2:1])
    ,.data_o(load_half)
  );

  bsg_mux #(
    .width_p(8)
    ,.els_p(8)
  ) byte_mux (
    .data_i(load_data)
    ,.sel_i(byte_offset[2:0])
    ,.data_o(load_byte)
  );

  assign word_sigext = signed_op & load_word[31]; 
  assign half_sigext = signed_op & load_half[15]; 
  assign byte_sigext = signed_op & load_byte[7]; 

  // Tag lookup
  // inputs
  dir_entry_s [assoc_p-1:0] tag_set_li;
  logic [ptag_width_lp-1:0] ptag_li;
  // LRU way tracking
  // current policy is Round-Robin per set, because it is simple.
  logic [sets_p-1:0][lg_assoc_lp-1:0] lru_way_r, lru_way_n;
  logic [lg_assoc_lp-1:0] lru_way_li;
  logic [assoc_p-1:0] dirty_bits_li;
  // set up tag lookup inputs
  assign tag_set_li = tags[cmd.paddr[block_offset_bits_lp +: lg_sets_lp]];
  assign ptag_li = cmd.paddr[paddr_width_p-1 -: ptag_width_lp];
  assign lru_way_li = lru_way_r[cmd.paddr[block_offset_bits_lp +: lg_sets_lp]];
  assign dirty_bits_li = dirty_bits[cmd.paddr[block_offset_bits_lp +: lg_sets_lp]];

  // outputs
  logic tag_hit_lo;
  logic tag_dirty_lo;
  logic [lg_assoc_lp-1:0] tag_hit_way_r, tag_hit_way_n, tag_hit_way_lo;
  bp_coh_states_e tag_hit_state_r, tag_hit_state_n, tag_hit_state_lo;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      lru_way_r <= '0;
      tag_hit_way_r <= '0;
      tag_hit_state_r <= e_COH_I;
    end else begin
      lru_way_r <= lru_way_n;
      tag_hit_way_r <= tag_hit_way_n;
      tag_hit_state_r <= tag_hit_state_n;
    end
  end

  tag_lookup
    #(.assoc_p(assoc_p)
      ,.ptag_width_p(ptag_width_lp)
      )
  lce_tag_lookup
    (.tag_set_i(tag_set_li)
     ,.ptag_i(ptag_li)
     ,.lru_way_i(lru_way_li)
     ,.dirty_bits_i(dirty_bits_li)
     ,.hit_o(tag_hit_lo)
     ,.dirty_o(tag_dirty_lo)
     ,.way_o(tag_hit_way_lo)
     ,.state_o(tag_hit_state_lo)
     );

  typedef enum logic [7:0] {
    e_state_reset
    ,e_state_uncached_only
    ,e_state_init
    ,e_state_send_sync
    ,e_state_ready
    ,e_state_tr_cmd
    ,e_state_tr_cmd_switch
    ,e_state_tr_cmd_tag
    ,e_state_tr_cmd_ld_hit
    ,e_state_tr_cmd_ld_hit_resp
    ,e_state_tr_cmd_ld_miss
    ,e_state_tr_cmd_st_hit
    ,e_state_tr_cmd_st_hit_wr_tag
    ,e_state_tr_cmd_st_hit_resp
    ,e_state_tr_cmd_st_miss
    ,e_state_uncached_tr_cmd
    ,e_state_uncached_send_req
    ,e_state_uncached_send_tr_resp
    ,e_state_lce_cmd
    ,e_state_lce_cmd_inv
    ,e_state_lce_cmd_inv_resp
    ,e_state_lce_cmd_st
    ,e_state_lce_cmd_data
    ,e_state_lce_send_coh_ack
    ,e_state_lce_cmd_stw
    ,e_state_lce_cmd_stw_resp
    ,e_state_lce_cmd_wb_rd
    ,e_state_lce_cmd_wb
    ,e_state_lce_cmd_tr_rd
    ,e_state_lce_cmd_tr
    ,e_state_finish_miss
    ,e_state_finish_miss_send
  } lce_state_e;

  lce_state_e lce_state_r, lce_state_n;

  // counter
  logic cnt_rst;
  logic cnt_inc, cnt_dec;
  logic [`BSG_WIDTH(num_cce_p+1)-1:0] cnt;
  bsg_counter_up_down
    #(.max_val_p(num_cce_p+1)
      ,.init_val_p(0)
      ,.max_step_p(1)
      )
    counter
    (.clk_i(clk_i)
     ,.reset_i(reset_i | cnt_rst)
     ,.up_i(cnt_inc)
     ,.down_i(cnt_dec)
     ,.count_o(cnt)
     );

  logic lce_init_r, lce_init_n;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      lce_state_r <= e_state_reset;
      lce_init_r <= '0;
      lce_cmd_r <= '0;

    end else begin
      lce_state_r <= lce_state_n;
      lce_init_r <= lce_init_n;
      lce_cmd_r <= lce_cmd_n;

    end
  end

  // convert miss address (excluding block offset bits) into CCE ID
  // For now, assume all CCE's have ID [0,num_core_p-1] and addresses are striped
  // at the cache block granularity
  logic [lg_sets_lp-1:0] hash_addr_li;
  logic [lg_num_cce_lp-1:0] cce_dst_id_lo;
  assign hash_addr_li = {<< {cmd.paddr[block_offset_bits_lp+:lg_sets_lp]}};
  bsg_hash_bank
    #(.banks_p(num_cce_p) // number of CCE's to spread way groups over
      ,.width_p(lg_sets_lp) // width of address input
      )
    addr_to_cce_id
     (.i(hash_addr_li)
      ,.bank_o(cce_dst_id_lo)
      ,.index_o()
      );

  always_comb begin
    lce_state_n = lce_state_r;
    lce_init_n = lce_init_r;

    cnt_inc = '0;
    cnt_dec = '0;
    cnt_rst = '0;

    // trace replay command inbound
    cmd_n = cmd;
    tr_pkt_yumi_o = '0;

    // trace replay response out
    tr_pkt_lo = '0;
    tr_pkt_v_o = '0;

    // outbound queues
    lce_req_v_o = '0;
    lce_req = '0;
    lce_resp_v_o = '0;
    lce_resp = '0;
    lce_cmd_v_o = '0;
    lce_cmd_lo = '0;

    // inbound queues
    lce_cmd_n = lce_cmd_r;
    lce_cmd_yumi = '0;

    // miss handling
    mshr_n = mshr_r;
    lru_way_n = lru_way_r;

    // tag, data, and dirty bit arrays
    tag_next_n = '0;
    tag_w_n = '0;
    data_next_n = '0;
    data_w_n = '0;
    data_mask_n = '0;
    dirty_w_n = '0;
    dirty_bits_n = '0;

    // tag lookup module
    tag_hit_way_n = tag_hit_way_r;
    tag_hit_state_n = tag_hit_state_r;

    // tag and data select
    cur_set_n = cur_set_r;
    cur_way_n = cur_way_r;

    unique case (lce_state_r)
      e_state_reset: begin
        // If the CCE will skip initialization and operate in uncached only
        // mode, go to UNCACHED_ONLY. If the CCE will run in normal mode, go
        // to INIT to wait for the SYNC command.
        lce_state_n = (skip_init_p) ? e_state_uncached_only : e_state_init;
      end

      /*
       * Uncached Only Mode
       */

      // Until all syncs occur, all requests will be uncached
      e_state_uncached_only: begin
        if (freeze_i & lce_cmd_v & lce_cmd.header.msg_type == e_lce_cmd_sync) begin
          // CCE will be used in normal mode, wait for all syncs, then transition to normal mode.
          lce_state_n = e_state_init;
        end else if (~freeze_i & tr_pkt_v_i & ~mshr_r.miss) begin
          // Freeze went low without receiving any syncs. Operate in uncached only mode.
          assert(tr_cmd_pkt.uncached) else $error("LCE in uncached only mode but received cached TR request.");
          tr_pkt_yumi_o = tr_pkt_v_i;
          cmd_n = tr_cmd_pkt;
          lce_state_n = e_state_uncached_tr_cmd;
          // new trace replay command, clear the mshr
          mshr_n = '0;
        end
      end

      /*
       * Initialization and Sync Routine
       */

      e_state_init: begin
        // by default, stay in INIT, waiting for all sync commands to arrive.
        lce_state_n = (cnt == num_cce_p) ? e_state_ready : e_state_init;
        cnt_rst = (cnt == num_cce_p);
        // register that LCE is initialized after sending all sync acks
        lce_init_n = (cnt == num_cce_p) ? 1'b1 : 1'b0;

        if (lce_cmd_v & lce_cmd.header.msg_type == e_lce_cmd_sync) begin
          // dequeue the command, go to SEND_SYNC
          lce_cmd_yumi = lce_cmd_v;
          lce_cmd_n = lce_cmd;
          lce_state_n = e_state_send_sync;
          cnt_inc = 1'b1;
        end
      end
      e_state_send_sync: begin
        // create the LCE response and make it valid for output

        // Common LCE Resp fields
        lce_resp.header.dst_id = lce_cmd_r.header.src_id;
        lce_resp.header.src_id = lce_id_i;
        lce_resp.header.msg_type = e_lce_cce_sync_ack;

        lce_resp_v_o = 1'b1;

        // response goes out if inbound ready signal is high (ready&valid)
        lce_state_n = (lce_resp_ready_i) ? e_state_init : e_state_send_sync;
      end

      /*
       * Ready for new access requests or external commands
       */

      e_state_ready: begin
        if (lce_cmd_v) begin
          // dequeue the command and save
          lce_cmd_yumi = lce_cmd_v;
          lce_cmd_n = lce_cmd;

          assert(lce_cmd.header.dst_id == lce_id_i) else $error("[%0d]: command delivered to wrong LCE", lce_id_i);

          // For commands involving set state, setting the state is always the last action
          // e.g., e_lce_cmd_st_tr_wb does transfer then writeback then set state
          unique case (lce_cmd.header.msg_type)
            e_lce_cmd_inv: begin
              lce_state_n = e_state_lce_cmd_inv;
            end
            e_lce_cmd_st: begin
              lce_state_n = e_state_lce_cmd_st;
            end
            e_lce_cmd_data: begin
              lce_state_n = e_state_lce_cmd_data;
            end
            e_lce_cmd_st_wakeup: begin
              lce_state_n = e_state_lce_cmd_stw;
            end
            e_lce_cmd_wb
            ,e_lce_cmd_st_wb: begin
              lce_state_n = e_state_lce_cmd_wb_rd;
            end
            e_lce_cmd_tr
            ,e_lce_cmd_st_tr
            ,e_lce_cmd_st_tr_wb: begin
              lce_state_n = e_state_lce_cmd_tr_rd;
            end
            e_lce_cmd_uc_data: begin
              // uncached data only arrives when LCE is explicitly waiting for it after uncached
              // load request was issued
              $error("Uncached Data Command received in ready state");
            end
            e_lce_cmd_uc_st_done: begin
              // e_lce_cmd_uc_st_done should only be received explicitly after uncached store
              // and the LCE waits for it
              $error("Uncached Store Done Command received in ready state");
            end
            default: begin
              // default does nothing
              // for now, e_lce_cmd_set_clear has no effect
              // e_lce_cmd_sync is also ignored after entering ready state
            end
          endcase

        end else if (tr_pkt_v_i & ~mshr_r.miss) begin
          // only process a new trace replay request if not already missing
          tr_pkt_yumi_o = tr_pkt_v_i;
          cmd_n = tr_cmd_pkt;
          lce_state_n = e_state_tr_cmd;
          // new trace replay command, clear the mshr
          mshr_n = '0;
        end

      end

      /*
       * Trace Replace Command Processing
       */

      e_state_tr_cmd: begin
        // set up tag lookup
        cur_set_n = cmd.paddr[block_offset_bits_lp +: lg_sets_lp];

        // cur_way depends on if there was a hit or not when it is a store
        cur_way_n = (tag_hit_lo) ? tag_hit_way_lo : '0;

        // capture tag lookup outputs
        tag_hit_way_n = tag_hit_way_lo;
        tag_hit_state_n = tag_hit_state_lo;

        // setup miss handling information
        mshr_n.miss = ~tag_hit_lo;
        mshr_n.cce = {'0, cce_dst_id_lo};
        mshr_n.paddr = cmd.paddr;
        mshr_n.uncached = cmd.uncached;
        mshr_n.dirty = tag_dirty_lo;
        mshr_n.store_op = store_op;
        mshr_n.upgrade = '0;
        mshr_n.lru_way = lru_way_li;
        mshr_n.tag_received = '0;
        mshr_n.data_received = '0;
        mshr_n.transfer_received = '0;

        lce_state_n = e_state_tr_cmd_switch;
      end
      e_state_tr_cmd_switch: begin
        // process the trace replay command
        if (mshr_r.uncached) begin
            lce_state_n = e_state_uncached_tr_cmd;
        end else if (~mshr_r.store_op) begin
          if (mshr_r.miss) begin
            lce_state_n = e_state_tr_cmd_ld_miss;
          end else begin
            lce_state_n = e_state_tr_cmd_ld_hit;
          end
        end else begin
          if (mshr_r.miss) begin
            lce_state_n = e_state_tr_cmd_st_miss;
          end else if (~mshr_r.miss && ((tag_hit_state_r == e_COH_M) || (tag_hit_state_r == e_COH_E))) begin
            lce_state_n = e_state_tr_cmd_st_hit;
          end else if (~mshr_r.miss && ((tag_hit_state_r == e_COH_S)
                                        | (tag_hit_state_r == e_COH_O)
                                        | (tag_hit_state_r == e_COH_F)
                                       )
                      ) begin
            // upgrade counts as a miss - update the mshr
            mshr_n.miss = 1'b1;
            mshr_n.upgrade = 1'b1;
            // use the tag hit way found during tag lookup as the LRU way since this is an upgrade
            mshr_n.lru_way = tag_hit_way_r;
            lce_state_n = e_state_tr_cmd_st_miss;
          end else begin
            lce_state_n = e_state_reset;
          end
        end
      end
      e_state_tr_cmd_ld_hit: begin
        // load hit
        cur_set_n = cmd.paddr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = tag_hit_way_r;

        // reset some state
        tag_hit_way_n = '0;
        tag_hit_state_n = e_COH_I;

        lce_state_n = e_state_tr_cmd_ld_hit_resp;

      end
      e_state_tr_cmd_ld_hit_resp: begin
        tr_pkt_v_o = 1'b1;
        tr_pkt_lo.paddr = mshr_r.paddr;
        // select data to return
        tr_pkt_lo.data = double_op
          ? load_data
          : (word_op
            ? {{32{word_sigext}}, load_word}
            : (half_op
              ? {{48{half_sigext}}, load_half}
              : {{56{byte_sigext}}, load_byte}));

        lce_state_n = (tr_pkt_ready_i) ? e_state_ready : e_state_tr_cmd_ld_hit_resp;
        mshr_n = (tr_pkt_ready_i) ? '0 : mshr_r;
      end
      e_state_tr_cmd_ld_miss: begin
        // load miss, send lce request
        lce_req_v_o = 1'b1;

        lce_req.header.dst_id = mshr_r.cce;
        lce_req.header.msg_type = e_lce_req_type_rd;
        lce_req.header.src_id = lce_id_i;
        lce_req.header.addr = mshr_r.paddr;
        lce_req.header.non_exclusive = e_lce_req_excl;
        lce_req.header.lru_way_id[0+:lg_assoc_lp] = mshr_r.lru_way;

        // wait for LCE req outbound to be ready (r&v), then wait for responses
        lce_state_n = (lce_req_ready_i) ? e_state_ready : e_state_tr_cmd_ld_miss;

      end
      e_state_tr_cmd_st_hit: begin
        // set up tag lookup
        cur_set_n = cmd.paddr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = tag_hit_way_r;
        // do the store
        data_w_n[cur_set_n][cur_way_n] = 1'b1;
        data_mask_n = double_op
          ? {{(cce_block_width_p-64){1'b0}}, {64{1'b1}}} << (dword_offset*64)
          : word_op
            ? {{(cce_block_width_p-32){1'b0}}, {32{1'b1}}} << (dword_offset*64 + 32*byte_offset[2])
            : half_op
              ? {{(cce_block_width_p-16){1'b0}}, {16{1'b1}}} << (dword_offset*64 + 16*byte_offset[2:1])
              : {{(cce_block_width_p-8){1'b0}}, {8{1'b1}}} << (dword_offset*64 + 8*byte_offset[2:0]);

        data_next_n = double_op
          ? {{(cce_block_width_p-64){1'b0}}, cmd.data} << (dword_offset*64)
          : word_op
            ? {{(cce_block_width_p-32){1'b0}}, cmd.data[0+:32]} << (dword_offset*64 + 32*byte_offset[2])
            : half_op
              ? {{(cce_block_width_p-16){1'b0}}, cmd.data[0+:16]} << (dword_offset*64 + 16*byte_offset[2:1])
              : {{(cce_block_width_p-8){1'b0}}, cmd.data[0+:8]} << (dword_offset*64 + 8*byte_offset[2:0]);

        lce_state_n = e_state_tr_cmd_st_hit_wr_tag;
      end
      e_state_tr_cmd_st_hit_wr_tag: begin
        // store hit on Exclusive forces upgrade to Modified
        if (tag_cur.state == e_COH_E) begin
          tag_w_n[cur_set_r][cur_way_r] = 1'b1;
          tag_next_n[cur_set_r][cur_way_r].state = e_COH_M;
          tag_next_n[cur_set_r][cur_way_r].tag = cmd.paddr[paddr_width_p-1 -: ptag_width_lp];
          // set the dirty bit when writing to a block in Exclusive (first write)
          dirty_w_n[cur_set_r][cur_way_r] = 1'b1;
          dirty_bits_n[cur_set_r][cur_way_r] = 1'b1;
        end
        lce_state_n = e_state_tr_cmd_st_hit_resp;
      end
      e_state_tr_cmd_st_hit_resp: begin
        // reset some state
        tag_hit_way_n = '0;
        tag_hit_state_n = e_COH_I;

        // reset the mshr since this is the ack to the transaction
        mshr_n = '0;

        // output valid trace replay return packet
        tr_pkt_v_o = 1'b1;
        tr_pkt_lo.paddr = mshr_r.paddr;
        // wait until packet consumed, then go to ready
        lce_state_n = (tr_pkt_ready_i) ? e_state_ready : e_state_tr_cmd_st_hit_resp;

      end
      e_state_tr_cmd_st_miss: begin
        // store miss - block present, not writable
        lce_req_v_o = 1'b1;

        lce_req.header.dst_id = mshr_r.cce;
        lce_req.header.msg_type = e_lce_req_type_wr;
        lce_req.header.src_id = lce_id_i;
        lce_req.header.addr = mshr_r.paddr;
        lce_req.header.non_exclusive = e_lce_req_excl;
        lce_req.header.lru_way_id[0+:lg_assoc_lp] = mshr_r.lru_way;

        lce_state_n = (lce_req_ready_i) ? e_state_ready : e_state_tr_cmd_st_miss;

      end
      e_state_uncached_tr_cmd: begin
        // uncached access - treat as miss
        mshr_n.miss = 1'b1;
        mshr_n.uncached = cmd.uncached;
        mshr_n.cce = {'0, cce_dst_id_lo};
        mshr_n.paddr = cmd.paddr;
        mshr_n.dirty = '0;
        mshr_n.store_op = store_op;
        mshr_n.upgrade = '0;
        mshr_n.lru_way = '0;
        mshr_n.tag_received = '0;
        mshr_n.data_received = '0;
        mshr_n.transfer_received = '0;

        lce_state_n = e_state_uncached_send_req;
      end
      e_state_uncached_send_req: begin
        // uncached access - send LCE request
        lce_req_v_o = 1'b1;

        lce_req.header.dst_id = mshr_r.cce;
        lce_req.header.msg_type = (mshr_r.store_op) ? e_lce_req_type_uc_wr : e_lce_req_type_uc_rd;
        lce_req.header.src_id = lce_id_i;
        lce_req.header.addr = mshr_r.paddr;

        lce_req.header.uc_size =
          (double_op)
          ? e_lce_uc_req_8
          : (word_op)
            ? e_lce_uc_req_4
            : (half_op)
              ? e_lce_uc_req_2
              : e_lce_uc_req_1;

        lce_req.data = (mshr_r.store_op) ? cmd.data : '0;

        // wait for LCE req outbound to be ready (r&v), then wait for responses
        lce_state_n = (lce_req_ready_i)
                      ? e_state_uncached_send_tr_resp
                      : e_state_uncached_send_req; // not accepted, try again next cycle

      end
      e_state_uncached_send_tr_resp: begin
        // wait for LCE Command in response to uncached request

        // send return packet to TR
        if (lce_cmd_v & lce_cmd.header.msg_type == e_lce_cmd_uc_st_done) begin
          assert(mshr_r.store_op) else $error("LCE received UC Store Done, but not missing on store");
          // store sends back null packet when it receives lce_cmd back
          tr_pkt_v_o = 1'b1;
          tr_pkt_lo.paddr = lce_cmd.header.addr;
          tr_pkt_lo.uncached = 1'b1;
          lce_state_n = (tr_pkt_ready_i)
                        ? (lce_init_r)
                          ? e_state_ready
                          : e_state_uncached_only
                        : e_state_uncached_send_tr_resp;

          lce_cmd_yumi = lce_cmd_v & tr_pkt_ready_i;

          // clear miss handling state
          mshr_n = (tr_pkt_ready_i) ? '0 : mshr_r;
        end else if (lce_cmd_v & lce_cmd.header.msg_type == e_lce_cmd_uc_data) begin
          assert(!mshr_r.store_op) else $error("LCE received UC Store Done, but not missing on store");
          // load returns the data, and must wait for lce_data_cmd to return
          tr_pkt_v_o = 1'b1;
          // Extract the desired bits from the returned 64-bit dword
          tr_pkt_lo.paddr = lce_cmd.header.addr;
          tr_pkt_lo.uncached = 1'b1;
          tr_pkt_lo.data =
            double_op
              ? lce_cmd.data[0 +: 64]
              : word_op
                ? {32'('0), lce_cmd.data[8*byte_offset +: 32]}
                : half_op
                  ? {48'('0), lce_cmd.data[8*byte_offset +: 16]}
                  : {56'('0), lce_cmd.data[8*byte_offset +: 8]};

          lce_state_n = (tr_pkt_ready_i)
                        ? (lce_init_r)
                          ? e_state_ready
                          : e_state_uncached_only
                        : e_state_uncached_send_tr_resp;

          // dequeue data cmd if TR accepts the outbound packet
          lce_cmd_yumi = lce_cmd_v & tr_pkt_ready_i;

          // clear miss handling state
          mshr_n = (tr_pkt_ready_i) ? '0 : mshr_r;

        end
      end

      /*
       * LCE Command Processing
       */

      e_state_lce_cmd_inv: begin
        // invalidate cmd received - update tags
        // lce_cmd contains all the necessary information to update tags
        cur_set_n = lce_cmd_r.header.addr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = lce_cmd_r.header.way_id;
        tag_w_n[cur_set_n][cur_way_n] = 1'b1;
        tag_next_n[cur_set_n][cur_way_n].state = e_COH_I;
        tag_next_n[cur_set_n][cur_way_n].tag = lce_cmd_r.header.addr[paddr_width_p-1 -: ptag_width_lp];

        // send inv_ack next
        lce_state_n = e_state_lce_cmd_inv_resp;

      end
      e_state_lce_cmd_inv_resp: begin

        // Common LCE Resp fields
        lce_resp.header.dst_id = lce_cmd_r.header.src_id;
        lce_resp.header.src_id = lce_id_i;
        lce_resp.header.msg_type = e_lce_cce_inv_ack;
        lce_resp.header.addr = lce_cmd_r.header.addr;

        // make the LCE response valid
        lce_resp_v_o = 1'b1;

        // wait until response accepted (r&v) then go to READY
        lce_state_n = (lce_resp_ready_i) ? e_state_ready : e_state_lce_cmd_inv_resp;

      end
      e_state_lce_cmd_st: begin
        // Set State command - only update the state
        cur_set_n = lce_cmd_r.header.addr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = lce_cmd_r.header.way_id;
        tag_w_n[cur_set_n][cur_way_n] = 1'b1;
        tag_next_n[cur_set_n][cur_way_n].state = lce_cmd_r.header.state;
        tag_next_n[cur_set_n][cur_way_n].tag = tags[cur_set_n][cur_way_n].tag;

        lce_state_n = e_state_ready;

      end
      e_state_lce_cmd_data: begin
        // data only arrives in response to an outstanding miss

        // write the full cache block to data array
        data_mask_n = '1;
        // use the address stored in the mshr
        cur_set_n = mshr_r.paddr[block_offset_bits_lp +: lg_sets_lp];
        // way comes from the data command
        cur_way_n = lce_cmd_r.header.way_id;
        data_w_n[cur_set_n][cur_way_n] = '1;
        // data comes from the data command
        data_next_n = lce_cmd_r.data;

        tag_w_n[cur_set_n][cur_way_n] = 1'b1;
        tag_next_n[cur_set_n][cur_way_n].state = lce_cmd_r.header.state;
        tag_next_n[cur_set_n][cur_way_n].tag = lce_cmd_r.header.addr[paddr_width_p-1 -: ptag_width_lp];

        assert (mshr_r.paddr[paddr_width_p-1 -: ptag_width_lp] == lce_cmd_r.header.addr[paddr_width_p-1 -: ptag_width_lp]) else
          $error("[%0d]: DT_CMD address mismatch [%H] != [%H]", lce_id_i, mshr_r.paddr, lce_cmd_r.header.addr);

        // update mshr
        mshr_n.data_received = 1'b1;
        mshr_n.tag_received = 1'b1;

        lce_state_n = e_state_lce_send_coh_ack;

      end
      e_state_lce_send_coh_ack: begin
        // respond to the miss - tag and data both received
        // all information needed to respond is stored in mshr

        // Common LCE Resp fields
        lce_resp.header.dst_id = mshr_r.cce;
        lce_resp.header.src_id = lce_id_i;
        lce_resp.header.msg_type = e_lce_cce_coh_ack;
        lce_resp.header.addr = mshr_r.paddr;

        // make the LCE response valid
        lce_resp_v_o = 1'b1;

        // send ack in response to tag and data both received
        // then, send response back to trace replay
        lce_state_n = (lce_resp_ready_i) ? e_state_finish_miss : e_state_lce_send_coh_ack;

      end
      e_state_lce_cmd_stw: begin
        // set tag and wakeup command - response to a miss

        // update tag array
        cur_set_n = lce_cmd_r.header.addr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = lce_cmd_r.header.way_id;

        tag_w_n[cur_set_n][cur_way_n] = 1'b1;
        tag_next_n[cur_set_n][cur_way_n].state = lce_cmd_r.header.state;
        tag_next_n[cur_set_n][cur_way_n].tag = lce_cmd_r.header.addr[paddr_width_p-1 -: ptag_width_lp];

        // send coh_ack next cycle
        lce_state_n = e_state_lce_cmd_stw_resp;

      end
      e_state_lce_cmd_stw_resp: begin
        // Send coherence ack in response to set tag and wakeup

        // Common LCE Resp fields
        lce_resp.header.dst_id = lce_cmd_r.header.src_id;
        lce_resp.header.src_id = lce_id_i;
        lce_resp.header.msg_type = e_lce_cce_coh_ack;
        lce_resp.header.addr = lce_cmd_r.header.addr;

        // make the LCE response valid
        lce_resp_v_o = 1'b1;

        // wait until response accepted (r&v), then finish the miss
        lce_state_n = (lce_resp_ready_i) ? e_state_finish_miss : e_state_lce_cmd_stw_resp;

      end
      e_state_lce_cmd_wb_rd: begin
        // handle e_lce_cmd_wb and e_lce_cmd_st_wb

        // tag and data select
        cur_set_n = lce_cmd_r.header.addr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = lce_cmd_r.header.way_id;

        lce_state_n = e_state_lce_cmd_wb;

      end
      e_state_lce_cmd_wb: begin
        // handle e_lce_cmd_wb and e_lce_cmd_st_wb

        lce_resp.header.dst_id = lce_cmd_r.header.src_id;
        lce_resp.header.src_id = lce_id_i;
        lce_resp.header.addr = lce_cmd_r.header.addr;

        if (dirty_bits[cur_set_r][cur_way_r]) begin
          lce_resp.data = data_cur;
          lce_resp.header.msg_type = e_lce_cce_resp_wb;

          // clear the dirty bit - but only do the write if the data response is accepted
          // (this prevents the dirty bit from being cleared before the response is sent, which
          //  could result in a null_wb being sent when an actual wb should have been)
          dirty_w_n[cur_set_r][cur_way_r] = (lce_resp_ready_i) ? 1'b1 : 1'b0;
          dirty_bits_n[cur_set_r][cur_way_r] = 1'b0;

        end else begin
          lce_resp.data = '0;
          lce_resp.header.msg_type = e_lce_cce_resp_null_wb;

        end

        lce_resp_v_o = 1'b1;

        // next state
        // wait until data response accepted (r&v)
        if (lce_resp_ready_i) begin
          // by default, assume next state is ready and writeback is done
          lce_state_n = e_state_ready;
          // if the message type indicates set state is needed, do that before ready
          // also update the msg_type field to reflect remaining work
          if (lce_cmd_r.header.msg_type == e_lce_cmd_st_wb) begin
            lce_cmd_n.header.msg_type = e_lce_cmd_st;
            lce_state_n = e_state_lce_cmd_st;
          end
        end

      end
      e_state_lce_cmd_tr_rd: begin
        // data select
        cur_set_n = lce_cmd_r.header.addr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = lce_cmd_r.header.way_id;

        lce_state_n = e_state_lce_cmd_tr;

      end
      e_state_lce_cmd_tr: begin
        // handle e_lce_cmd_tr, e_lce_cmd_st_tr, and e_lce_cmd_st_tr_wb
        lce_cmd_v_o = 1'b1;

        lce_cmd_lo.header.dst_id = lce_cmd_r.header.target;
        lce_cmd_lo.header.msg_type = e_lce_cmd_data;
        lce_cmd_lo.header.way_id = lce_cmd_r.header.target_way_id;

        // Assign data command to msg field of LCE Cmd
        lce_cmd_lo.data = data_cur;
        lce_cmd_lo.header.state = lce_cmd_r.header.target_state;
        lce_cmd_lo.header.addr = lce_cmd_r.header.addr;

        // make the command valid

        // wait until data commmand out accepted (r&v), then go to next state
        if (lce_cmd_ready_i) begin
          lce_state_n = e_state_ready;
          if (lce_cmd_r.header.msg_type == e_lce_cmd_st_tr_wb) begin
            lce_state_n = e_state_lce_cmd_wb_rd;
            lce_cmd_n.header.msg_type = e_lce_cmd_st_wb;
          end else if (lce_cmd_r.header.msg_type == e_lce_cmd_st_tr) begin
            lce_state_n = e_state_lce_cmd_st;
            lce_cmd_n.header.msg_type = e_lce_cmd_st;
          end
        end

      end
      e_state_finish_miss: begin
        // select data to return
        cur_set_n = mshr_r.paddr[block_offset_bits_lp +: lg_sets_lp];
        cur_way_n = mshr_r.lru_way;

        if (mshr_r.store_op) begin
          // do the store
          data_w_n[cur_set_n][cur_way_n] = 1'b1;
          data_mask_n = double_op
            ? {{(cce_block_width_p-64){1'b0}}, {64{1'b1}}} << (dword_offset*64)
            : word_op
              ? {{(cce_block_width_p-32){1'b0}}, {32{1'b1}}} << (dword_offset*64 + 32*byte_offset[2])
              : half_op
                ? {{(cce_block_width_p-16){1'b0}}, {16{1'b1}}} << (dword_offset*64 + 16*byte_offset[2:1])
                : {{(cce_block_width_p-8){1'b0}}, {8{1'b1}}} << (dword_offset*64 + 8*byte_offset[2:0]);

          data_next_n = double_op
            ? {{(cce_block_width_p-64){1'b0}}, cmd.data} << (dword_offset*64)
            : word_op
              ? {{(cce_block_width_p-32){1'b0}}, cmd.data[0+:32]} << (dword_offset*64 + 32*byte_offset[2])
              : half_op
                ? {{(cce_block_width_p-16){1'b0}}, cmd.data[0+:16]} << (dword_offset*64 + 16*byte_offset[2:1])
                : {{(cce_block_width_p-8){1'b0}}, cmd.data[0+:8]} << (dword_offset*64 + 8*byte_offset[2:0]);

          // this is a store, so set the dirty bit for the block
          dirty_w_n[cur_set_n][cur_way_n] = 1'b1;
          dirty_bits_n[cur_set_n][cur_way_n] = 1'b1;
        end else begin
          // this is a load, so clear the dirty bit for the block
          dirty_w_n[cur_set_n][cur_way_n] = 1'b1;
          dirty_bits_n[cur_set_n][cur_way_n] = 1'b0;
        end

        lce_state_n = e_state_finish_miss_send;

      end
      e_state_finish_miss_send: begin
        // send return packet back to TR after CCE handles the LCE miss request
        tr_pkt_v_o = 1'b1;

        if (mshr_r.store_op && tag_cur.state == e_COH_E) begin
          tag_w_n[cur_set_r][cur_way_r] = 1'b1;
          tag_next_n[cur_set_r][cur_way_r].state = e_COH_M;
          tag_next_n[cur_set_r][cur_way_r].tag = mshr_r.paddr[paddr_width_p-1 -: ptag_width_lp];
        end

        tr_pkt_lo.paddr = mshr_r.paddr;
        tr_pkt_lo.data = '0;
        if (load_op) begin
          tr_pkt_lo.data = double_op
            ? load_data
            : (word_op
              ? {{32{word_sigext}}, load_word}
              : (half_op
                ? {{48{half_sigext}}, load_half}
                : {{56{byte_sigext}}, load_byte}));
        end

        // wait until TR accepts packet (r&v), then go to READY
        lce_state_n = (tr_pkt_ready_i) ? e_state_ready : e_state_finish_miss_send;

        // clear miss handling state, only if TR packet accepted
        mshr_n = (tr_pkt_ready_i) ? '0 : mshr_r;

        // update lru_way - round robin, only if TR packet accepted
        // do not update for an upgrade
        lru_way_n[cur_set_r] = (tr_pkt_ready_i & ~mshr_r.upgrade)
                             ? (lru_way_r[cur_set_r] + 'd1)
                             : lru_way_r[cur_set_r];

      end
      default: begin
        lce_state_n = e_state_reset;
      end
    endcase
  end



  /*
   * LCE AXE / Memory Consistency Tracing
   */

  localparam lg_dword_bytes_lp=`BSG_SAFE_CLOG2(dword_width_p/8);

  always_ff @(posedge clk_i) begin
    if (axe_trace_p) begin
    case (lce_state_r)
      e_state_tr_cmd_ld_hit_resp: begin
        if (tr_pkt_ready_i) begin
          $display("#AXE %0d: M[%0d] == %0d", lce_id_i, (cmd.paddr >> lg_dword_bytes_lp), load_data);
        end
      end
      e_state_tr_cmd_st_hit_wr_tag: begin
        $display("#AXE %0d: M[%0d] := %0d", lce_id_i, (cmd.paddr >> lg_dword_bytes_lp), cmd.data);
      end
      e_state_finish_miss_send: begin
        if (tr_pkt_ready_i) begin
          if (mshr_r.store_op) begin
            $display("#AXE %0d: M[%0d] := %0d", lce_id_i, (cmd.paddr >> lg_dword_bytes_lp), cmd.data);
          end else begin
            $display("#AXE %0d: M[%0d] == %0d", lce_id_i, (cmd.paddr >> lg_dword_bytes_lp), load_data);
          end
        end
      end
    endcase
    end // axe_trace

  end


endmodule


