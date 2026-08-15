/*
 * alu.v — C8 arithmetic/logic unit.
 *
 * Inputs:
 *   op      4-bit opcode (determines which operation to perform)
 *   fn      3-bit function code (used by SHF; 0 for all others)
 *   a, b    8-bit operands
 * Outputs:
 *   result  8-bit result
 *   flags   4-bit {V, N, C, Z} updated flags
 *
 * Flag behaviour:
 *   ADD/SUB/CMP: all four flags updated from 9-bit intermediate
 *   AND/OR/XOR:  Z and N set; C=0, V=0
 *   SHF:         Z and N set from result; C = shifted-out bit; V=0
 *   LDI/LD:      Z and N set; C=0, V=0
 *   All others:  flags unchanged (passed through unchanged)
 */

module alu (
    input  wire [3:0] op,
    input  wire [2:0] fn,
    input  wire [7:0] a,
    input  wire [7:0] b,
    input  wire [3:0] flags_in,
    output reg  [7:0] result,
    output reg  [3:0] flags_out   /* {V, N, C, Z} */
);

    /* Expanded 9-bit intermediate for carry detection */
    reg [8:0] wide;

    always @(*) begin
        wide       = 9'b0;
        result     = 8'b0;
        flags_out  = flags_in;

        case (op)
            4'h1: begin /* ADD */
                wide      = {1'b0, a} + {1'b0, b};
                result    = wide[7:0];
                flags_out[0] = (result == 8'h00);                 /* Z */
                flags_out[1] = result[7];                          /* N */
                flags_out[2] = wide[8];                            /* C */
                flags_out[3] = (~a[7] & ~b[7] & result[7]) |      /* V */
                                ( a[7] &  b[7] & ~result[7]);
            end

            4'h2: begin /* SUB */
                wide      = {1'b0, a} - {1'b0, b};
                result    = wide[7:0];
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = wide[8];                            /* borrow */
                flags_out[3] = ( a[7] & ~b[7] & ~result[7]) |
                                (~a[7] &  b[7] &  result[7]);
            end

            4'h3: begin /* AND */
                result       = a & b;
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = 1'b0;
                flags_out[3] = 1'b0;
            end

            4'h4: begin /* OR */
                result       = a | b;
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = 1'b0;
                flags_out[3] = 1'b0;
            end

            4'h5: begin /* XOR */
                result       = a ^ b;
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = 1'b0;
                flags_out[3] = 1'b0;
            end

            4'h6: begin /* SHF */
                case (fn[1:0])
                    2'd0: begin /* SHL */
                        result       = a << 1;
                        flags_out[2] = a[7];   /* MSB shifted out */
                    end
                    2'd1: begin /* SHR */
                        result       = a >> 1;
                        flags_out[2] = a[0];   /* LSB shifted out */
                    end
                    2'd2: begin /* ROR */
                        result       = {a[0], a[7:1]};
                        flags_out[2] = a[0];
                    end
                    default: result = a;
                endcase
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[3] = 1'b0;
            end

            4'h7: begin /* CMP — identical to SUB but result discarded */
                wide      = {1'b0, a} - {1'b0, b};
                result    = wide[7:0];          /* not written to rd */
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = wide[8];
                flags_out[3] = ( a[7] & ~b[7] & ~result[7]) |
                                (~a[7] &  b[7] &  result[7]);
            end

            4'h8: begin /* LDI — pass b (immediate) through */
                result       = b;
                flags_out[0] = (result == 8'h00);
                flags_out[1] = result[7];
                flags_out[2] = 1'b0;
                flags_out[3] = 1'b0;
            end

            default: begin
                result    = a;
                flags_out = flags_in;
            end
        endcase
    end

endmodule
