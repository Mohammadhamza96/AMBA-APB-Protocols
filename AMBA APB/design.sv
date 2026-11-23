`timescale 1ns/1ps

// ============================================================================
//  AMBA APB : one Requester (master) talking to two Completers (slaves)
//
//  Same circuit as the Logisim project:
//     apb_slave   -> SLAVE   (a 32-bit register)
//     apb_master  -> MASTER  (FSM, address decoder, latches, read path)
//     apb_top     -> main    (master + slave 1 + slave 2)
//
//  FSM states :  IDLE = 00,  SETUP = 01,  ACCESS = 10
//  Reset      :  asynchronous and active-HIGH (the spec's PRESETn is the opposite)
// ============================================================================


// ----------------------------------------------------------------------------
//  Slave: just one 32-bit register.
//  It only stores data at the end of the ACCESS phase, and only if it is ready.
// ----------------------------------------------------------------------------
module apb_slave #(parameter DW = 32) (
    input               PCLK,
    input               RESET,
    input               PSEL,       // this slave is selected
    input               PENABLE,    // we are in the ACCESS phase
    input               PWRITE,     // 1 = write, 0 = read
    input  [DW-1:0]     PWDATA,
    input               READY,      // "I am ready" switch (this is PREADY)
    output [DW-1:0]     PRDATA
);
    reg [DW-1:0] slave_reg;

    // write only when selected + ACCESS phase + write + ready
    wire write_enable = PSEL & PENABLE & PWRITE & READY;

    always @(posedge PCLK or posedge RESET) begin
        if (RESET)
            slave_reg <= {DW{1'b0}};
        else if (write_enable)
            slave_reg <= PWDATA;
    end

    assign PRDATA = slave_reg;      // a read just shows what is stored
endmodule


// ----------------------------------------------------------------------------
//  Master: runs the IDLE -> SETUP -> ACCESS state machine.
// ----------------------------------------------------------------------------
module apb_master (
    input               PCLK,
    input               RESET,

    // our own "please start a transfer" interface (not part of the APB spec)
    input               VALID,
    input               WRITE,
    input  [7:0]        ADDR,
    input  [31:0]       WDATA,

    // coming back from the two slaves
    input               READY1,
    input               READY2,
    input  [31:0]       RDATA1,
    input  [31:0]       RDATA2,

    // the APB bus
    output [7:0]        PADDR,
    output [31:0]       PWDATA,
    output              PWRITE,
    output              PSEL1,
    output              PSEL2,
    output              PENABLE,
    output              PREADY,

    // handy extras for the LEDs / waveform
    output              SETUP,
    output              IDLE,
    output [31:0]       RDATA_OUT
);
    // ---- the three states
    localparam [1:0] S_IDLE   = 2'b00;
    localparam [1:0] S_SETUP  = 2'b01;
    localparam [1:0] S_ACCESS = 2'b10;

    reg [1:0] state;
    reg [1:0] next_state;

    // ---- the request is stored when a transfer starts, so the address and
    //      data stay steady through both SETUP and ACCESS (APB requires this)
    reg [7:0]  addr_reg;
    reg [31:0] wdata_reg;
    reg        write_reg;

    assign PADDR  = addr_reg;
    assign PWDATA = wdata_reg;
    assign PWRITE = write_reg;

    // ---- what each state looks like on the bus
    wire selected = (state == S_SETUP) | (state == S_ACCESS);   // PSEL (any slave)

    assign PENABLE = (state == S_ACCESS);
    assign SETUP   = (state == S_SETUP);
    assign IDLE    = (state == S_IDLE);

    // ---- address decoder: bit 7 of the address picks the slave
    wire addr7 = addr_reg[7];
    assign PSEL1 = selected & ~addr7;       // 0x00 - 0x7F -> slave 1
    assign PSEL2 = selected &  addr7;       // 0x80 - 0xFF -> slave 2

    // only the slave that is actually selected can say "ready"
    assign PREADY = (PSEL1 & READY1) | (PSEL2 & READY2);

    // ---- next-state logic
    always @(*) begin
        next_state = S_IDLE;
        case (state)
            S_IDLE: begin
                if (VALID) next_state = S_SETUP;
                else       next_state = S_IDLE;
            end

            S_SETUP: begin
                next_state = S_ACCESS;          // SETUP always lasts one cycle
            end

            S_ACCESS: begin
                if (!PREADY)    next_state = S_ACCESS;  // slave not ready: wait
                else if (VALID) next_state = S_SETUP;   // another transfer follows
                else            next_state = S_IDLE;    // all done
            end

            default: next_state = S_IDLE;       // state 11 is never used
        endcase
    end

    // store the new request on the clock edge that moves us into SETUP
    wire load_request = (next_state == S_SETUP);

    // ---- state register and request registers
    always @(posedge PCLK or posedge RESET) begin
        if (RESET) begin
            state     <= S_IDLE;
            addr_reg  <= 8'h00;
            wdata_reg <= 32'h0000_0000;
            write_reg <= 1'b0;
        end else begin
            state <= next_state;
            if (load_request) begin
                addr_reg  <= ADDR;
                wdata_reg <= WDATA;
                write_reg <= WRITE;
            end
        end
    end

    // ---- read path: keep the data from whichever slave was read
    wire        read_done = selected & PENABLE & PREADY & ~PWRITE;
    wire [31:0] read_data = addr7 ? RDATA2 : RDATA1;

    reg [31:0] rdata_reg;

    always @(posedge PCLK or posedge RESET) begin
        if (RESET)
            rdata_reg <= 32'h0000_0000;
        else if (read_done)
            rdata_reg <= read_data;
    end

    assign RDATA_OUT = rdata_reg;
endmodule


// ----------------------------------------------------------------------------
//  Top level: master + two slaves
// ----------------------------------------------------------------------------
module apb_top (
    input               PCLK,
    input               RESET,
    input               VALID,
    input               WRITE,
    input  [7:0]        ADDR,
    input  [31:0]       WDATA,
    input               READY1,
    input               READY2,

    output [7:0]        PADDR,
    output [31:0]       PWDATA,
    output              PWRITE,
    output              PSEL1,
    output              PSEL2,
    output              PENABLE,
    output              PREADY,
    output              SETUP,
    output              IDLE,
    output [31:0]       RDATA_OUT,
    output [31:0]       SLAVE1_REG,
    output [31:0]       SLAVE2_REG
);
    wire [31:0] rdata1;
    wire [31:0] rdata2;

    apb_master u_master (
        .PCLK(PCLK),       .RESET(RESET),
        .VALID(VALID),     .WRITE(WRITE),
        .ADDR(ADDR),       .WDATA(WDATA),
        .READY1(READY1),   .READY2(READY2),
        .RDATA1(rdata1),   .RDATA2(rdata2),
        .PADDR(PADDR),     .PWDATA(PWDATA),   .PWRITE(PWRITE),
        .PSEL1(PSEL1),     .PSEL2(PSEL2),
        .PENABLE(PENABLE), .PREADY(PREADY),
        .SETUP(SETUP),     .IDLE(IDLE),
        .RDATA_OUT(RDATA_OUT)
    );

    apb_slave #(.DW(32)) u_slave1 (
        .PCLK(PCLK),       .RESET(RESET),
        .PSEL(PSEL1),      .PENABLE(PENABLE),
        .PWRITE(PWRITE),   .PWDATA(PWDATA),
        .READY(READY1),    .PRDATA(rdata1)
    );

    apb_slave #(.DW(32)) u_slave2 (
        .PCLK(PCLK),       .RESET(RESET),
        .PSEL(PSEL2),      .PENABLE(PENABLE),
        .PWRITE(PWRITE),   .PWDATA(PWDATA),
        .READY(READY2),    .PRDATA(rdata2)
    );

    assign SLAVE1_REG = rdata1;
    assign SLAVE2_REG = rdata2;
endmodule
