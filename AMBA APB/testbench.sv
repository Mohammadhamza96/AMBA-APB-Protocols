`timescale 1ns/1ps

// ============================================================================
//  Testbench for the APB design (top module: tb)
//
//  Every check prints nothing when it passes and a FAIL line when it does not.
//  At the end you get one summary line.  A waveform is saved in dump.vcd
//  (EPWave opens it automatically on EDA Playground).
// ============================================================================
module tb;

    // ---- signals going into / coming out of the design
    reg         PCLK;
    reg         RESET;
    reg         VALID;
    reg         WRITE;
    reg  [7:0]  ADDR;
    reg  [31:0] WDATA;
    reg         READY1;
    reg         READY2;

    wire [7:0]  PADDR;
    wire [31:0] PWDATA;
    wire        PWRITE;
    wire        PSEL1;
    wire        PSEL2;
    wire        PENABLE;
    wire        PREADY;
    wire        SETUP;
    wire        IDLE;
    wire [31:0] RDATA_OUT;
    wire [31:0] SLAVE1_REG;
    wire [31:0] SLAVE2_REG;

    apb_top dut (
        .PCLK(PCLK),       .RESET(RESET),
        .VALID(VALID),     .WRITE(WRITE),
        .ADDR(ADDR),       .WDATA(WDATA),
        .READY1(READY1),   .READY2(READY2),
        .PADDR(PADDR),     .PWDATA(PWDATA),   .PWRITE(PWRITE),
        .PSEL1(PSEL1),     .PSEL2(PSEL2),
        .PENABLE(PENABLE), .PREADY(PREADY),
        .SETUP(SETUP),     .IDLE(IDLE),
        .RDATA_OUT(RDATA_OUT),
        .SLAVE1_REG(SLAVE1_REG), .SLAVE2_REG(SLAVE2_REG)
    );

    // ---- clock: 10 ns period
    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    // ---- score keeping
    integer errors;
    integer checks;

    // The name is stored in 64 characters (512 bits), which is plenty for every
    // message used below. (A too-small name vector is what causes the
    // "WIDTHTRUNC" warning in Verilator.)
    localparam NAME_BITS = 8 * 64;

    task check_bit(input [NAME_BITS-1:0] name, input actual, input expected);
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s is %b, expected %b", $time, name, actual, expected);
            end
        end
    endtask

    task check_word(input [NAME_BITS-1:0] name, input [31:0] actual, input [31:0] expected);
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s is 0x%08h, expected 0x%08h", $time, name, actual, expected);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    //  One complete APB transfer (a write or a read).
    //
    //  wait_cycles = how many extra ACCESS cycles the slave keeps PREADY low.
    //  We look at the signals on the falling clock edge, when they are steady.
    // ------------------------------------------------------------------------
    task do_transfer(input is_write, input [7:0] addr, input [31:0] data, input integer wait_cycles);
        integer     i;
        reg         uses_slave2;
        reg  [31:0] slave1_before;
        reg  [31:0] slave2_before;
        reg  [31:0] addr_word;
        begin
            uses_slave2   = addr[7];
            addr_word     = {24'h000000, addr};
            slave1_before = SLAVE1_REG;
            slave2_before = SLAVE2_REG;

            // 1) put the request on the inputs (we are still IDLE)
            @(negedge PCLK);
            VALID  = 1'b1;
            WRITE  = is_write;
            ADDR   = addr;
            WDATA  = data;
            READY1 = 1'b1;
            READY2 = 1'b1;
            if (wait_cycles > 0) begin
                if (uses_slave2) READY2 = 1'b0;     // chosen slave is not ready yet
                else             READY1 = 1'b0;
            end
            check_bit("master is IDLE before the request", IDLE, 1'b1);

            // 2) SETUP phase
            @(negedge PCLK);
            VALID = 1'b0;                           // the request is only one cycle long
            check_bit("state is SETUP",              SETUP,   1'b1);
            check_bit("PENABLE is low in SETUP",     PENABLE, 1'b0);
            check_bit("PSEL1 matches the address",   PSEL1,   ~uses_slave2);
            check_bit("PSEL2 matches the address",   PSEL2,   uses_slave2);
            check_bit("PWRITE matches the request",  PWRITE,  is_write);
            check_word("PADDR holds the address",    {24'h000000, PADDR}, addr_word);
            check_word("PWDATA holds the data",      PWDATA,  data);

            // 3) ACCESS phase
            @(negedge PCLK);
            check_bit("PENABLE is high in ACCESS",   PENABLE, 1'b1);
            check_bit("SETUP is low in ACCESS",      SETUP,   1'b0);

            // 3b) wait states: nothing may change while PREADY is low
            for (i = 0; i < wait_cycles; i = i + 1) begin
                check_bit("PREADY stays low while waiting",  PREADY,  1'b0);
                check_bit("still in ACCESS while waiting",   PENABLE, 1'b1);
                check_word("PADDR stable while waiting",     {24'h000000, PADDR}, addr_word);
                check_word("PWDATA stable while waiting",    PWDATA,  data);
                check_word("slave 1 untouched while waiting", SLAVE1_REG, slave1_before);
                check_word("slave 2 untouched while waiting", SLAVE2_REG, slave2_before);
                @(negedge PCLK);
            end

            // the slave finally becomes ready
            if (wait_cycles > 0) begin
                READY1 = 1'b1;
                READY2 = 1'b1;
                #1;                                 // give the logic a moment to settle
            end
            check_bit("PREADY is high, transfer finishes", PREADY, 1'b1);

            // 4) the transfer completes on the next rising edge -> back to IDLE
            @(negedge PCLK);
            check_bit("master is IDLE again",        IDLE,    1'b1);
            check_bit("PENABLE is low again",        PENABLE, 1'b0);
            check_bit("PSEL1 is low again",          PSEL1,   1'b0);
            check_bit("PSEL2 is low again",          PSEL2,   1'b0);
        end
    endtask

    // ------------------------------------------------------------------------
    //  The actual tests
    // ------------------------------------------------------------------------
    initial begin
        errors = 0;
        checks = 0;

        $dumpfile("dump.vcd");
        $dumpvars(0, tb);

        // start with everything quiet and RESET held high
        RESET  = 1'b1;
        VALID  = 1'b0;
        WRITE  = 1'b0;
        ADDR   = 8'h00;
        WDATA  = 32'h0000_0000;
        READY1 = 1'b1;
        READY2 = 1'b1;

        repeat (2) @(negedge PCLK);
        RESET = 1'b0;
        @(negedge PCLK);

        $display("TEST 0: state after reset");
        check_bit("master is IDLE after reset", IDLE, 1'b1);
        check_word("slave 1 is cleared by reset", SLAVE1_REG, 32'h0);
        check_word("slave 2 is cleared by reset", SLAVE2_REG, 32'h0);

        $display("TEST 1: write to slave 1, no wait states");
        do_transfer(1'b1, 8'h00, 32'hA5A5A5A5, 0);
        check_word("slave 1 got the data",   SLAVE1_REG, 32'hA5A5A5A5);
        check_word("slave 2 not changed",    SLAVE2_REG, 32'h0);

        $display("TEST 2: write to slave 2 with 3 wait states");
        do_transfer(1'b1, 8'h80, 32'h5A5A5A5A, 3);
        check_word("slave 2 got the data",   SLAVE2_REG, 32'h5A5A5A5A);
        check_word("slave 1 not changed",    SLAVE1_REG, 32'hA5A5A5A5);

        $display("TEST 3: read from slave 1");
        do_transfer(1'b0, 8'h00, 32'h0, 0);
        check_word("read data is slave 1's value", RDATA_OUT, 32'hA5A5A5A5);

        $display("TEST 4: read from slave 2 with 2 wait states");
        do_transfer(1'b0, 8'h80, 32'h0, 2);
        check_word("read data is slave 2's value", RDATA_OUT, 32'h5A5A5A5A);

        $display("TEST 5: write to slave 1 at another address, 2 wait states");
        do_transfer(1'b1, 8'h04, 32'h11223344, 2);
        check_word("slave 1 got the new data", SLAVE1_REG, 32'h11223344);
        check_word("slave 2 not changed",      SLAVE2_REG, 32'h5A5A5A5A);

        $display("TEST 6: a read must not change the slave");
        do_transfer(1'b0, 8'h00, 32'hFFFFFFFF, 0);
        check_word("slave 1 still has its value", SLAVE1_REG, 32'h11223344);
        check_word("read data is slave 1's value", RDATA_OUT, 32'h11223344);

        $display("TEST 7: back-to-back transfers (ACCESS goes straight to SETUP)");
        // first transfer: write 0xCAFEF00D to slave 2
        @(negedge PCLK);
        VALID = 1'b1;  WRITE = 1'b1;  ADDR = 8'h80;  WDATA = 32'hCAFEF00D;
        READY1 = 1'b1; READY2 = 1'b1;
        @(negedge PCLK);                            // SETUP of the first transfer
        VALID = 1'b0;
        check_bit("first transfer is in SETUP", SETUP, 1'b1);
        @(negedge PCLK);                            // ACCESS of the first transfer
        check_bit("first transfer is in ACCESS", PENABLE, 1'b1);
        // while the first one finishes, ask for a second one: read slave 1
        VALID = 1'b1;  WRITE = 1'b0;  ADDR = 8'h00;  WDATA = 32'h0;
        @(negedge PCLK);                            // should be SETUP of the second
        VALID = 1'b0;
        check_bit("goes straight to SETUP",       SETUP, 1'b1);
        check_bit("IDLE was skipped",             IDLE,  1'b0);
        check_word("first write reached slave 2", SLAVE2_REG, 32'hCAFEF00D);
        check_bit("second transfer is a read",    PWRITE, 1'b0);
        check_bit("second transfer picks slave 1", PSEL1, 1'b1);
        @(negedge PCLK);                            // ACCESS of the second
        @(negedge PCLK);                            // back to IDLE
        check_bit("IDLE at the end",              IDLE, 1'b1);
        check_word("second transfer read slave 1", RDATA_OUT, 32'h11223344);

        $display("TEST 8: slave not ready, so the master keeps waiting");
        @(negedge PCLK);
        VALID = 1'b1;  WRITE = 1'b1;  ADDR = 8'h00;  WDATA = 32'hBADC0DE5;
        READY1 = 1'b0; READY2 = 1'b1;
        @(negedge PCLK);                            // SETUP
        VALID = 1'b0;
        repeat (5) begin
            @(negedge PCLK);                        // ACCESS, still waiting
            check_bit("still in ACCESS (slave not ready)", PENABLE, 1'b1);
            check_word("slave 1 is not written yet",       SLAVE1_REG, 32'h11223344);
        end
        READY1 = 1'b1;                              // slave 1 is ready at last
        @(negedge PCLK);
        check_bit("back to IDLE once the slave is ready", IDLE, 1'b1);
        check_word("slave 1 written once it was ready",   SLAVE1_REG, 32'hBADC0DE5);

        $display("TEST 9: reset in the middle of a transfer");
        @(negedge PCLK);
        VALID = 1'b1;  WRITE = 1'b1;  ADDR = 8'h80;  WDATA = 32'hDEADBEEF;
        READY1 = 1'b1; READY2 = 1'b0;
        @(negedge PCLK);                            // SETUP
        VALID = 1'b0;
        @(negedge PCLK);                            // ACCESS, waiting
        check_bit("in ACCESS before the reset", PENABLE, 1'b1);
        RESET = 1'b1;
        #1;
        check_bit("reset puts us in IDLE at once", IDLE, 1'b1);
        check_word("reset clears slave 1", SLAVE1_REG, 32'h0);
        check_word("reset clears slave 2", SLAVE2_REG, 32'h0);
        @(negedge PCLK);
        RESET  = 1'b0;
        READY2 = 1'b1;
        @(negedge PCLK);
        check_bit("IDLE after the reset is released", IDLE, 1'b1);

        // ---- summary
        $display("--------------------------------------------------");
        if (errors == 0)
            $display("ALL TESTS PASSED (%0d checks)", checks);
        else
            $display("%0d of %0d checks FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
