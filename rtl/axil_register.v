module axil_register #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
) (
    input aclk,
    input aresetn,

    // Write Address
    input  [ADDR_WIDTH-1:0] s_axil_awaddr,
    input                   s_axil_awvalid,
    output                  s_axil_awready,

    // Write Data
    input  [    DATA_WIDTH-1:0] s_axil_wdata,
    input  [(DATA_WIDTH/8)-1:0] s_axil_wstrb,
    input                       s_axil_wvalid,
    output                      s_axil_wready,

    // Write Response
    output [1:0] s_axil_bresp,
    output       s_axil_bvalid,
    input        s_axil_bready,

    // Read Address
    input  [ADDR_WIDTH-1:0] s_axil_araddr,
    input                   s_axil_arvalid,
    output                  s_axil_arready,

    // Read Data
    output [DATA_WIDTH-1:0] s_axil_rdata,
    output [           1:0] s_axil_rresp,
    output                  s_axil_rvalid,
    input                   s_axil_rready
);




    localparam [ADDR_WIDTH-1:0] c_ADDR_CONTROL = 8'h00;
    localparam [ADDR_WIDTH-1:0] c_ADDR_STATUS = 8'h04;
    localparam [ADDR_WIDTH-1:0] c_ADDR_DATA_A = 8'h08;
    localparam [ADDR_WIDTH-1:0] c_ADDR_DATA_B = 8'h0C;
    localparam [ADDR_WIDTH-1:0] c_ADDR_RESULT = 8'h10;


    localparam [1:0] c_AXI_OKAY = 2'b00;
    localparam [1:0] c_AXI_SLVERR = 2'b10;


    // Write Address Register
    reg  [    ADDR_WIDTH-1:0] r_awaddr;
    reg                       r_aw_hold;  // Hold write address until write data is accepted
    wire                      w_have_aw;
    wire                      w_aw_accept;

    // Write Data Register
    reg                       r_w_hold;  // Hold write data until write address is accepted
    reg  [    DATA_WIDTH-1:0] r_wdata;
    reg  [(DATA_WIDTH/8)-1:0] r_wstrb;
    wire                      w_have_w;
    wire                      w_w_accept;

    // Write Response Register
    reg  [               1:0] r_bresp;
    reg                       r_bvalid;
    wire                      w_b_accept;


    wire                      w_write_commit;
    wire [    ADDR_WIDTH-1:0] w_write_commit_addr;
    wire [    DATA_WIDTH-1:0] w_write_commit_data;
    wire [(DATA_WIDTH/8)-1:0] w_write_commit_wstrb;


    reg  [    DATA_WIDTH-1:0] r_data_a;
    reg  [    DATA_WIDTH-1:0] r_data_b;
    reg  [    DATA_WIDTH-1:0] r_data_ctrl;


    reg  [               1:0] w_write_resp;


    wire                      w_write_ctrl;
    wire                      w_write_data_a;
    wire                      w_write_data_b;



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


    // ====================
    // Write Address flag
    // ====================
    always @(posedge aclk) begin

        if (!aresetn) r_aw_hold <= 0;
        else if (w_write_commit) r_aw_hold <= 0;
        else if (w_aw_accept) r_aw_hold <= 1;
        else r_aw_hold <= r_aw_hold;

    end


    always @(posedge aclk) begin
        if (!aresetn) r_awaddr <= 0;
        else if (w_aw_accept) r_awaddr <= s_axil_awaddr;
        else r_awaddr <= r_awaddr;
    end


    // Write Address wire assignments
    assign s_axil_awready = !r_aw_hold && !r_bvalid;
    assign w_aw_accept = s_axil_awvalid && s_axil_awready;
    assign w_have_aw = r_aw_hold || w_aw_accept;




    //=====================
    // Write Data flags and registers
    // =====================
    always @(posedge aclk) begin

        if (!aresetn) r_w_hold <= 0;
        else if (w_write_commit) r_w_hold <= 0;
        else if (w_w_accept) r_w_hold <= 1;
        else r_w_hold <= r_w_hold;

    end

    always @(posedge aclk) begin
        if (!aresetn) r_wdata <= 0;
        else if (w_w_accept) r_wdata <= s_axil_wdata;
        else r_wdata <= r_wdata;
    end



    always @(posedge aclk) begin
        if (!aresetn) r_wstrb <= 0;
        else if (w_w_accept) r_wstrb <= s_axil_wstrb;
        else r_wstrb <= r_wstrb;
    end

    assign s_axil_wready = !r_w_hold && !r_bvalid;
    assign w_w_accept = s_axil_wvalid && s_axil_wready;
    assign w_have_w = r_w_hold || w_w_accept;


    // ========================
    // Write Response flags and registers
    // ========================
    always @(posedge aclk) begin

        if (!aresetn) r_bvalid <= 0;
        else if (w_write_commit) r_bvalid <= 1;
        else if (w_b_accept) r_bvalid <= 0;
        else r_bvalid <= r_bvalid;

    end

    always @(posedge aclk) begin
        if (!aresetn) r_bresp <= 0;
        else if (w_write_commit) r_bresp <= w_write_resp;  // OKAY response
        else r_bresp <= r_bresp;
    end


    assign w_b_accept = r_bvalid && s_axil_bready;




    // Write Commit wire assignment
    assign w_write_commit = w_have_aw && w_have_w;  // Write data accepted and write address held

    assign w_write_commit_addr = r_aw_hold ? r_awaddr : s_axil_awaddr;
    assign w_write_commit_data = r_w_hold ? r_wdata : s_axil_wdata;
    assign w_write_commit_wstrb = r_w_hold ? r_wstrb : s_axil_wstrb;



    assign w_write_ctrl = w_write_commit && (w_write_commit_addr == c_ADDR_CONTROL);
    assign w_write_data_a = w_write_commit && (w_write_commit_addr == c_ADDR_DATA_A);
    assign w_write_data_b = w_write_commit && (w_write_commit_addr == c_ADDR_DATA_B);





    always @(posedge aclk) begin

        if (!aresetn) r_data_a <= 0;
        else if (w_write_data_a)
            r_data_a <= f_apply_wstrb(r_data_a, w_write_commit_data, w_write_commit_wstrb);
        else r_data_a <= r_data_a;

    end
    always @(posedge aclk) begin

        if (!aresetn) r_data_b <= 0;
        else if (w_write_data_b)
            r_data_b <= f_apply_wstrb(r_data_b, w_write_commit_data, w_write_commit_wstrb);
        else r_data_b <= r_data_b;

    end

    always @(posedge aclk) begin

        if (!aresetn) r_data_ctrl <= 0;
        else if (w_write_ctrl)
            r_data_ctrl <= f_apply_wstrb(r_data_ctrl, w_write_commit_data, w_write_commit_wstrb);
        else r_data_ctrl <= r_data_ctrl;

    end


    always @(*) begin
        w_write_resp = c_AXI_SLVERR;

        case (w_write_commit_addr)
            c_ADDR_CONTROL: w_write_resp = c_AXI_OKAY;
            c_ADDR_DATA_A:  w_write_resp = c_AXI_OKAY;
            c_ADDR_DATA_B:  w_write_resp = c_AXI_OKAY;
            default:        w_write_resp = c_AXI_SLVERR;
        endcase

    end


    //  Read Address Register
    reg                   r_rvalid;
    reg  [DATA_WIDTH-1:0] r_rdata;
    wire                  w_ar_accept;
    wire                  w_r_accept;
    always @(posedge aclk) begin

        if (!aresetn) r_rvalid <= 0;
        else if (w_ar_accept) r_rvalid <= 1;
        else if (w_r_accept) r_rvalid <= 0;
        else r_rvalid <= r_rvalid;

    end

    always @(posedge aclk) begin

        if (!aresetn) r_rdata <= 0;
        else if (w_ar_accept) r_rdata <= w_read_data;
        else r_rdata <= r_rdata;

    end

    always @(posedge aclk) begin

        if (!aresetn) r_read_resp <= 0;
        else if (w_ar_accept) r_read_resp <= w_read_resp;
        else r_read_resp <= r_read_resp;

    end


    assign s_axil_arready = !r_rvalid;
    assign w_ar_accept = s_axil_arvalid && s_axil_arready;
    assign w_r_accept = r_rvalid && s_axil_rready;





    reg [DATA_WIDTH-1:0] w_read_data;
    reg [           1:0] w_read_resp;
    reg [           1:0] r_read_resp;

    always @(*) begin

        w_read_data = {DATA_WIDTH{1'b0}};
        w_read_resp = c_AXI_SLVERR;

        case (s_axil_araddr)

            c_ADDR_CONTROL: begin
                w_read_data = r_data_ctrl;
                w_read_resp = c_AXI_OKAY;
            end

            c_ADDR_STATUS: begin
                w_read_data = {31'b0, w_have_aw && w_have_w};
                w_read_resp = c_AXI_OKAY;
            end

            c_ADDR_DATA_A: begin
                w_read_data = r_data_a;
                w_read_resp = c_AXI_OKAY;
            end

            c_ADDR_DATA_B: begin
                w_read_data = r_data_b;
                w_read_resp = c_AXI_OKAY;
            end

            c_ADDR_RESULT: begin
                w_read_data = r_data_a + r_data_b;
                w_read_resp = c_AXI_OKAY;
            end



            default: begin
                w_read_data = {DATA_WIDTH{1'b0}};
                w_read_resp = c_AXI_SLVERR;
            end

        endcase

    end

    // =========================
    // Output assignments
    //=========================
    assign s_axil_bresp  = r_bresp;
    assign s_axil_bvalid = r_bvalid;

    assign s_axil_rdata  = r_rdata;
    assign s_axil_rresp  = r_read_resp;
    assign s_axil_rvalid = r_rvalid;




endmodule
