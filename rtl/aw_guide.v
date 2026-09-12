`timescale 1ns / 1ps


// KP-10SEP2026 : Purpose
// AXI4-Lite register interface for D-STAR TX.
//
// Responsibilities:
// 1) Receive D-STAR transport words from the A53 through AXI4-Lite.
// 2) Store VALID_BITS and LAST metadata.
// 3) Convert TX_DATA writes into 39-bit asynchronous FIFO entries.
// 4) Generate START / ABORT / CLEAR_STATUS request pulses.
// 5) Return D-STAR TX status to software.
// 6) Reject invalid FIFO writes with AXI SLVERR.
//
// FIFO entry:
// [38]    LAST
// [37:32] VALID_BITS
// [31:0]  DATA
//
// IMPORTANT:
// This module operates only in the AXI clock domain.
//
// START / ABORT / CLEAR_STATUS must pass through command CDC before
// entering dstar_tx_ctrl.v.
//
// Controller status inputs must already be synchronized into the
// AXI clock domain before entering this module.


module dstar_tx_axi #(

    parameter integer        c_S_AXI_DATA_WIDTH = 32,
    parameter integer        c_S_AXI_ADDR_WIDTH = 6,
    parameter         [31:0] c_VERSION          = 32'h0001_0000

) (


    // ==============================================
    // KP-10SEP2026 : interface to AXI4-Lite bus from Zynq MPSoC PS
    // ==============================================


    // KP-10SEP2026 : connected to AXI4-Lite bus from Zynq MPSoC PS
    input wire s_axi_aclk,
    input wire s_axi_aresetn,

    // KP-10SEP2026 : AXI4-Lite write address channel
    input  wire [c_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [                   2:0] s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,

    // KP-10SEP2026 : AXI4-Lite write data channel
    input  wire [    c_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [(c_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,

    // KP-10SEP2026 : AXI4-Lite write response channel
    output wire [1:0] s_axi_bresp,
    output wire       s_axi_bvalid,
    input  wire       s_axi_bready,

    // KP-10SEP2026 : AXI4-Lite read address channel
    input  wire [c_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [                   2:0] s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,

    // KP-10SEP2026 : AXI4-Lite read data channel
    output wire [c_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [                   1:0] s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready,



    // ==============================================
    // KP-10SEP2026 : interface to DSTAR-GMSK-TX_IP
    // ==============================================


    // KP-10SEP2026 : connected to dstar_tx_async_fifo.v write side
    output wire [38:0] o_fifo_data,
    output wire        o_fifo_wr_en,
    input  wire        i_fifo_full,
    input  wire        i_fifo_overflow,

    // KP-10SEP2026 : connected to [command CDC] before dstar_tx_ctrl.v
    output wire o_start_req,
    output wire o_abort_req,
    output wire o_clear_status_req,

    // KP-10SEP2026 : connected from dstar_tx_ctrl.v through [status CDC]
    input wire i_status_busy,
    input wire i_status_done,
    input wire i_status_aborted,
    input wire i_status_error,
    input wire i_status_meta_error_sticky,
    input wire i_status_underflow_sticky

);

    // KP-10SEP2026 : AXI response definitions
    localparam [1:0] c_AXI_OKAY = 2'b00;
    localparam [1:0] c_AXI_SLVERR = 2'b10;


    // KP-10SEP2026 : Register address definitions
    localparam [5:0] c_ADDR_CTRL = 6'h00;
    localparam [5:0] c_ADDR_STATUS = 6'h04;
    localparam [5:0] c_ADDR_TX_META = 6'h08;
    localparam [5:0] c_ADDR_TX_DATA = 6'h0C;
    localparam [5:0] c_ADDR_ERROR_STATUS = 6'h10;
    localparam [5:0] c_ADDR_VERSION = 6'h14;

    // KP-10SEP2026 : AXI write-address holding register
    reg                               r_aw_hold;
    reg  [    c_S_AXI_ADDR_WIDTH-1:0] r_awaddr;

    // KP-10SEP2026 : AXI write-data holding registers
    reg                               r_w_hold;
    reg  [    c_S_AXI_DATA_WIDTH-1:0] r_wdata;
    reg  [(c_S_AXI_DATA_WIDTH/8)-1:0] r_wstrb;

    // KP-10SEP2026 : AXI write response
    reg                               r_bvalid;
    reg  [                       1:0] r_bresp;

    // KP-10SEP2026 : D-STAR metadata register
    reg  [                      31:0] r_tx_meta;

    // KP-10SEP2026 : Last successfully accepted TX_DATA word
    reg  [                      31:0] r_tx_data_shadow;

    // KP-10SEP2026 : AXI-domain command request pulses
    reg                               r_start_req;
    reg                               r_abort_req;
    reg                               r_clear_status_req;

    // KP-10SEP2026 : FIFO write interface registers
    reg  [                      38:0] r_fifo_data;
    reg                               r_fifo_wr_en;

    // KP-10SEP2026 : AXI-domain FIFO overflow sticky flag
    reg                               r_fifo_overflow_sticky;

    // KP-10SEP2026 : AXI read response registers
    reg                               r_rvalid;
    reg  [                      31:0] r_rdata;
    reg  [                       1:0] r_rresp;


    // KP-10SEP2026 : Combinational AXI transaction signals
    wire                              w_aw_accept;
    wire                              w_w_accept;

    wire                              w_have_aw;
    wire                              w_have_w;

    wire                              w_write_commit;

    wire [    c_S_AXI_ADDR_WIDTH-1:0] w_commit_awaddr;
    wire [                      31:0] w_commit_wdata;
    wire [                       3:0] w_commit_wstrb;

    wire                              w_ar_accept;


    // KP-10SEP2026 : Register-write decode
    wire                              w_write_ctrl;
    wire                              w_write_tx_meta;
    wire                              w_write_tx_data;


    // KP-10SEP2026 : Control command decode
    wire                              w_start_cmd;
    wire                              w_abort_cmd;
    wire                              w_clear_status_cmd;


    // KP-10SEP2026 : TX_DATA validation
    wire                              w_meta_valid;
    wire                              w_tx_data_full_strobe;
    wire                              w_tx_data_accept;
    wire                              w_tx_data_reject_full;


    // KP-10SEP2026 : WSTRB merged TX_META value
    wire [                      31:0] w_tx_meta_merged;


    // KP-10SEP2026 : Write response selected for current transaction
    reg  [                       1:0] w_write_resp;


    // KP-10SEP2026 : Read decode
    reg  [                      31:0] w_read_data;
    reg  [                       1:0] w_read_resp;


    // KP-10SEP2026 : Apply AXI byte write strobes
    function [31:0] f_apply_wstrb;

        input [31:0] i_old_value;
        input [31:0] i_new_value;
        input [3:0] i_wstrb;
        integer i;

        begin

            f_apply_wstrb = i_old_value;
            for (i = 0; i < 4; i = i + 1)
            if (i_wstrb[i]) f_apply_wstrb[(i*8)+:8] = i_new_value[(i*8)+:8];

        end

    endfunction


    // KP-10SEP2026 : AXI write channel handshakes. AW and W are accepted independently.
    assign s_axi_awready = !r_aw_hold && !r_bvalid;
    assign w_aw_accept = s_axi_awvalid && s_axi_awready;
    assign w_have_aw = r_aw_hold || w_aw_accept;

    assign s_axi_wready = !r_w_hold && !r_bvalid;
    assign w_w_accept = s_axi_wvalid && s_axi_wready;
    assign w_have_w = r_w_hold || w_w_accept;

    // KP-11SEP2026 : Commit write transaction after both channels are accepted. 
    // KP-11SEP2026 : Join AW and W channels to form a single write transaction. This prevents partial writes from being processed.
    assign w_write_commit = !r_bvalid && w_have_aw && w_have_w;

    // KP-10SEP2026 :Use held information if that AXI channel arrived earlier.
    assign w_commit_awaddr = r_aw_hold ? r_awaddr : s_axi_awaddr;
    assign w_commit_wdata = r_w_hold ? r_wdata : s_axi_wdata;
    assign w_commit_wstrb = r_w_hold ? r_wstrb : s_axi_wstrb;

    // KP-10SEP2026 : Register write decoding
    assign w_write_ctrl = w_write_commit && (w_commit_awaddr == c_ADDR_CTRL);
    assign w_write_tx_meta = w_write_commit && (w_commit_awaddr == c_ADDR_TX_META);
    assign w_write_tx_data = w_write_commit && (w_commit_awaddr == c_ADDR_TX_DATA);

    // KP-10SEP2026 : CTRL is write-one-to-pulse
    assign w_start_cmd = w_write_ctrl && w_commit_wstrb[0] && w_commit_wdata[0];
    assign w_abort_cmd = w_write_ctrl && w_commit_wstrb[0] && w_commit_wdata[1];
    assign w_clear_status_cmd = w_write_ctrl && w_commit_wstrb[0] && w_commit_wdata[2];

    // KP-10SEP2026 : TX_META handling
    assign w_tx_meta_merged = f_apply_wstrb(r_tx_meta, w_commit_wdata, w_commit_wstrb);

    // KP-10SEP2026 : VALID_BITS legal range is 1..32.
    assign w_meta_valid = (r_tx_meta[5:0] >= 6'd1) && (r_tx_meta[5:0] <= 6'd32);

    // KP-10SEP2026 : TX_DATA is one atomic 32-bit transport word. Partial byte writes are rejected.
    assign w_tx_data_full_strobe = (w_commit_wstrb == 4'b1111);
    assign w_tx_data_accept      = w_write_tx_data && w_tx_data_full_strobe && w_meta_valid && !i_fifo_full;
    assign w_tx_data_reject_full = w_write_tx_data && w_tx_data_full_strobe && w_meta_valid && i_fifo_full;


    // KP-10SEP2026 : Write response decoder
    always @(*) begin

        w_write_resp = c_AXI_SLVERR;


        case (w_commit_awaddr)

            c_ADDR_CTRL: begin

                w_write_resp = c_AXI_OKAY;

            end


            c_ADDR_TX_META: begin

                w_write_resp = c_AXI_OKAY;

            end


            c_ADDR_TX_DATA: begin

                if (w_tx_data_full_strobe && w_meta_valid && !i_fifo_full)
                    w_write_resp = c_AXI_OKAY;
                else w_write_resp = c_AXI_SLVERR;

            end


            default: begin

                w_write_resp = c_AXI_SLVERR;

            end

        endcase

    end

    // ============================================
    // KP-10SEP2026 : AXI write-address  register
    // ============================================


    // KP-10SEP2026 : AXI write-address holding flag
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_aw_hold <= 1'b0;
        else if (w_write_commit) r_aw_hold <= 1'b0;
        else if (w_aw_accept) r_aw_hold <= 1'b1;
        else r_aw_hold <= r_aw_hold;

    end


    // KP-10SEP2026 : AXI write-address holding register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_awaddr <= {c_S_AXI_ADDR_WIDTH{1'b0}};
        else if (w_aw_accept) r_awaddr <= s_axi_awaddr;
        else r_awaddr <= r_awaddr;

    end

    // ============================================
    // KP-10SEP2026 : AXI write-data registers
    // ============================================


    // KP-10SEP2026 : AXI write-data holding flag
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_w_hold <= 1'b0;
        else if (w_write_commit) r_w_hold <= 1'b0;
        else if (w_w_accept) r_w_hold <= 1'b1;
        else r_w_hold <= r_w_hold;

    end


    // KP-10SEP2026 : AXI write-data holding register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_wdata <= 32'd0;
        else if (w_w_accept) r_wdata <= s_axi_wdata;
        else r_wdata <= r_wdata;

    end


    // KP-10SEP2026 : AXI WSTRB holding register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_wstrb <= 4'd0;
        else if (w_w_accept) r_wstrb <= s_axi_wstrb;
        else r_wstrb <= r_wstrb;

    end


    // ============================================
    // KP-10SEP2026 : AXI write-response registers
    // ============================================


    // KP-10SEP2026 : AXI write-response VALID
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_bvalid <= 1'b0;
        else if (w_write_commit) r_bvalid <= 1'b1;
        else if (r_bvalid && s_axi_bready) r_bvalid <= 1'b0;
        else r_bvalid <= r_bvalid;

    end


    // KP-10SEP2026 : AXI write-response code
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_bresp <= c_AXI_OKAY;
        else if (w_write_commit) r_bresp <= w_write_resp;
        else r_bresp <= r_bresp;

    end


    // KP-10SEP2026 : TX_META register

    // Reset default:
    // VALID_BITS = 32
    // LAST       = 0
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_tx_meta <= 32'h0000_0020;
        else if (w_write_tx_meta) r_tx_meta <= w_tx_meta_merged & 32'h0000_013F;
        else r_tx_meta <= r_tx_meta;

    end


    // KP-10SEP2026 : Last accepted TX_DATA shadow register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_tx_data_shadow <= 32'd0;
        else if (w_tx_data_accept) r_tx_data_shadow <= w_commit_wdata;
        else r_tx_data_shadow <= r_tx_data_shadow;

    end


    // KP-10SEP2026 : START request pulse. 
    //Connected to command CDC before dstar_tx_ctrl.v i_start.
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_start_req <= 1'b0;
        else r_start_req <= w_start_cmd;

    end


    // KP-10SEP2026 : ABORT request pulse
    // Connected to command CDC before dstar_tx_ctrl.v i_abort.
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_abort_req <= 1'b0;
        else r_abort_req <= w_abort_cmd;

    end


    // KP-10SEP2026 : CLEAR_STATUS request pulse.  
    // Connected to command CDC before dstar_tx_ctrl.v i_clear_status.
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_clear_status_req <= 1'b0;
        else r_clear_status_req <= w_clear_status_cmd;

    end


    // KP-10SEP2026 : FIFO entry register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_fifo_data <= 39'd0;
        else if (w_tx_data_accept) r_fifo_data <= {r_tx_meta[8], r_tx_meta[5:0], w_commit_wdata};
        else r_fifo_data <= r_fifo_data;

    end


    // KP-10SEP2026 : FIFO write-enable pulse. 
    // Connected to dstar_tx_async_fifo.v i_w_en.
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_fifo_wr_en <= 1'b0;
        else r_fifo_wr_en <= w_tx_data_accept;

    end


    // KP-10SEP2026 : FIFO overflow sticky status
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_fifo_overflow_sticky <= 1'b0;
        else if (i_fifo_overflow || w_tx_data_reject_full) r_fifo_overflow_sticky <= 1'b1;
        else if (w_clear_status_cmd) r_fifo_overflow_sticky <= 1'b0;
        else r_fifo_overflow_sticky <= r_fifo_overflow_sticky;

    end


    // KP-10SEP2026 : AXI read decode
    always @(*) begin

        w_read_data = 32'd0;
        w_read_resp = c_AXI_SLVERR;


        case (s_axi_araddr)

            c_ADDR_CTRL: begin

                // KP-10SEP2026 :
                // CTRL is write-one-to-pulse, therefore reads return zero.
                w_read_data = 32'd0;
                w_read_resp = c_AXI_OKAY;

            end


            c_ADDR_STATUS: begin

                w_read_data = {
                    26'd0,
                    r_fifo_overflow_sticky,
                    i_fifo_full,
                    i_status_error,
                    i_status_aborted,
                    i_status_done,
                    i_status_busy
                };
                w_read_resp = c_AXI_OKAY;

            end


            c_ADDR_TX_META: begin

                w_read_data = r_tx_meta;
                w_read_resp = c_AXI_OKAY;

            end


            c_ADDR_TX_DATA: begin

                w_read_data = r_tx_data_shadow;
                w_read_resp = c_AXI_OKAY;

            end


            c_ADDR_ERROR_STATUS: begin

                w_read_data = {
                    29'd0,
                    r_fifo_overflow_sticky,
                    i_status_underflow_sticky,
                    i_status_meta_error_sticky
                };
                w_read_resp = c_AXI_OKAY;

            end


            c_ADDR_VERSION: begin

                w_read_data = c_VERSION;
                w_read_resp = c_AXI_OKAY;

            end


            default: begin

                w_read_data = 32'd0;
                w_read_resp = c_AXI_SLVERR;

            end

        endcase

    end


    // KP-10SEP2026 : AXI read-address handshake
    assign s_axi_arready = !r_rvalid;
    assign w_ar_accept   = s_axi_arvalid && s_axi_arready;


    // KP-10SEP2026 : AXI RVALID
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_rvalid <= 1'b0;
        else if (w_ar_accept) r_rvalid <= 1'b1;
        else if (r_rvalid && s_axi_rready) r_rvalid <= 1'b0;
        else r_rvalid <= r_rvalid;

    end


    // KP-10SEP2026 : AXI read-data register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_rdata <= 32'd0;
        else if (w_ar_accept) r_rdata <= w_read_data;
        else r_rdata <= r_rdata;

    end


    // KP-10SEP2026 : AXI read-response register
    always @(posedge s_axi_aclk) begin

        if (!s_axi_aresetn) r_rresp <= c_AXI_OKAY;
        else if (w_ar_accept) r_rresp <= w_read_resp;
        else r_rresp <= r_rresp;

    end


    // ----------------------------------
    // KP-10SEP2026 : AXI output assignments
    // ----------------------------------

    assign s_axi_bvalid       = r_bvalid;
    assign s_axi_bresp        = r_bresp;

    assign s_axi_rvalid       = r_rvalid;
    assign s_axi_rdata        = r_rdata;
    assign s_axi_rresp        = r_rresp;


    // KP-10SEP2026 : connected to dstar_tx_async_fifo.v
    assign o_fifo_data        = r_fifo_data;
    assign o_fifo_wr_en       = r_fifo_wr_en;


    // KP-10SEP2026 : connected to command CDC
    assign o_start_req        = r_start_req;
    assign o_abort_req        = r_abort_req;
    assign o_clear_status_req = r_clear_status_req;


endmodule
