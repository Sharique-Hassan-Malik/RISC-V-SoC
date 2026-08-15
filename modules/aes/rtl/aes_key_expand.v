// AES-128 Key Schedule — FIPS 197 Section 5.2
//
// Combinational circuit that derives all 11 round keys from a 128-bit key.
// Output: 1408-bit bus, round_keys[1407:1280] = RK0 ... round_keys[127:0] = RK10.
//
// RotWord: 32-bit left rotate by 8  {b0,b1,b2,b3} -> {b1,b2,b3,b0}
// SubWord: S-box applied to each byte of a 32-bit word
// Rcon[i]: {rc_i, 0x00, 0x00, 0x00}  where rc values xtime-iterate from 0x01

module aes_key_expand (
    input  [127:0]    key,
    output [1407:0]   round_keys  // [1407:1280]=RK0 ... [127:0]=RK10
);
    // Round constants
    localparam [31:0] RC1  = 32'h01000000;
    localparam [31:0] RC2  = 32'h02000000;
    localparam [31:0] RC3  = 32'h04000000;
    localparam [31:0] RC4  = 32'h08000000;
    localparam [31:0] RC5  = 32'h10000000;
    localparam [31:0] RC6  = 32'h20000000;
    localparam [31:0] RC7  = 32'h40000000;
    localparam [31:0] RC8  = 32'h80000000;
    localparam [31:0] RC9  = 32'h1b000000;
    localparam [31:0] RC10 = 32'h36000000;

    // S-box function (inline — avoids per-byte submodule instantiation for key path)
    function [7:0] sb;
        input [7:0] x;
        reg [7:0] v;
        begin
            case (x)
                8'h00:v=8'h63; 8'h01:v=8'h7c; 8'h02:v=8'h77; 8'h03:v=8'h7b;
                8'h04:v=8'hf2; 8'h05:v=8'h6b; 8'h06:v=8'h6f; 8'h07:v=8'hc5;
                8'h08:v=8'h30; 8'h09:v=8'h01; 8'h0a:v=8'h67; 8'h0b:v=8'h2b;
                8'h0c:v=8'hfe; 8'h0d:v=8'hd7; 8'h0e:v=8'hab; 8'h0f:v=8'h76;
                8'h10:v=8'hca; 8'h11:v=8'h82; 8'h12:v=8'hc9; 8'h13:v=8'h7d;
                8'h14:v=8'hfa; 8'h15:v=8'h59; 8'h16:v=8'h47; 8'h17:v=8'hf0;
                8'h18:v=8'had; 8'h19:v=8'hd4; 8'h1a:v=8'ha2; 8'h1b:v=8'haf;
                8'h1c:v=8'h9c; 8'h1d:v=8'ha4; 8'h1e:v=8'h72; 8'h1f:v=8'hc0;
                8'h20:v=8'hb7; 8'h21:v=8'hfd; 8'h22:v=8'h93; 8'h23:v=8'h26;
                8'h24:v=8'h36; 8'h25:v=8'h3f; 8'h26:v=8'hf7; 8'h27:v=8'hcc;
                8'h28:v=8'h34; 8'h29:v=8'ha5; 8'h2a:v=8'he5; 8'h2b:v=8'hf1;
                8'h2c:v=8'h71; 8'h2d:v=8'hd8; 8'h2e:v=8'h31; 8'h2f:v=8'h15;
                8'h30:v=8'h04; 8'h31:v=8'hc7; 8'h32:v=8'h23; 8'h33:v=8'hc3;
                8'h34:v=8'h18; 8'h35:v=8'h96; 8'h36:v=8'h05; 8'h37:v=8'h9a;
                8'h38:v=8'h07; 8'h39:v=8'h12; 8'h3a:v=8'h80; 8'h3b:v=8'he2;
                8'h3c:v=8'heb; 8'h3d:v=8'h27; 8'h3e:v=8'hb2; 8'h3f:v=8'h75;
                8'h40:v=8'h09; 8'h41:v=8'h83; 8'h42:v=8'h2c; 8'h43:v=8'h1a;
                8'h44:v=8'h1b; 8'h45:v=8'h6e; 8'h46:v=8'h5a; 8'h47:v=8'ha0;
                8'h48:v=8'h52; 8'h49:v=8'h3b; 8'h4a:v=8'hd6; 8'h4b:v=8'hb3;
                8'h4c:v=8'h29; 8'h4d:v=8'he3; 8'h4e:v=8'h2f; 8'h4f:v=8'h84;
                8'h50:v=8'h53; 8'h51:v=8'hd1; 8'h52:v=8'h00; 8'h53:v=8'hed;
                8'h54:v=8'h20; 8'h55:v=8'hfc; 8'h56:v=8'hb1; 8'h57:v=8'h5b;
                8'h58:v=8'h6a; 8'h59:v=8'hcb; 8'h5a:v=8'hbe; 8'h5b:v=8'h39;
                8'h5c:v=8'h4a; 8'h5d:v=8'h4c; 8'h5e:v=8'h58; 8'h5f:v=8'hcf;
                8'h60:v=8'hd0; 8'h61:v=8'hef; 8'h62:v=8'haa; 8'h63:v=8'hfb;
                8'h64:v=8'h43; 8'h65:v=8'h4d; 8'h66:v=8'h33; 8'h67:v=8'h85;
                8'h68:v=8'h45; 8'h69:v=8'hf9; 8'h6a:v=8'h02; 8'h6b:v=8'h7f;
                8'h6c:v=8'h50; 8'h6d:v=8'h3c; 8'h6e:v=8'h9f; 8'h6f:v=8'ha8;
                8'h70:v=8'h51; 8'h71:v=8'ha3; 8'h72:v=8'h40; 8'h73:v=8'h8f;
                8'h74:v=8'h92; 8'h75:v=8'h9d; 8'h76:v=8'h38; 8'h77:v=8'hf5;
                8'h78:v=8'hbc; 8'h79:v=8'hb6; 8'h7a:v=8'hda; 8'h7b:v=8'h21;
                8'h7c:v=8'h10; 8'h7d:v=8'hff; 8'h7e:v=8'hf3; 8'h7f:v=8'hd2;
                8'h80:v=8'hcd; 8'h81:v=8'h0c; 8'h82:v=8'h13; 8'h83:v=8'hec;
                8'h84:v=8'h5f; 8'h85:v=8'h97; 8'h86:v=8'h44; 8'h87:v=8'h17;
                8'h88:v=8'hc4; 8'h89:v=8'ha7; 8'h8a:v=8'h7e; 8'h8b:v=8'h3d;
                8'h8c:v=8'h64; 8'h8d:v=8'h5d; 8'h8e:v=8'h19; 8'h8f:v=8'h73;
                8'h90:v=8'h60; 8'h91:v=8'h81; 8'h92:v=8'h4f; 8'h93:v=8'hdc;
                8'h94:v=8'h22; 8'h95:v=8'h2a; 8'h96:v=8'h90; 8'h97:v=8'h88;
                8'h98:v=8'h46; 8'h99:v=8'hee; 8'h9a:v=8'hb8; 8'h9b:v=8'h14;
                8'h9c:v=8'hde; 8'h9d:v=8'h5e; 8'h9e:v=8'h0b; 8'h9f:v=8'hdb;
                8'ha0:v=8'he0; 8'ha1:v=8'h32; 8'ha2:v=8'h3a; 8'ha3:v=8'h0a;
                8'ha4:v=8'h49; 8'ha5:v=8'h06; 8'ha6:v=8'h24; 8'ha7:v=8'h5c;
                8'ha8:v=8'hc2; 8'ha9:v=8'hd3; 8'haa:v=8'hac; 8'hab:v=8'h62;
                8'hac:v=8'h91; 8'had:v=8'h95; 8'hae:v=8'he4; 8'haf:v=8'h79;
                8'hb0:v=8'he7; 8'hb1:v=8'hc8; 8'hb2:v=8'h37; 8'hb3:v=8'h6d;
                8'hb4:v=8'h8d; 8'hb5:v=8'hd5; 8'hb6:v=8'h4e; 8'hb7:v=8'ha9;
                8'hb8:v=8'h6c; 8'hb9:v=8'h56; 8'hba:v=8'hf4; 8'hbb:v=8'hea;
                8'hbc:v=8'h65; 8'hbd:v=8'h7a; 8'hbe:v=8'hae; 8'hbf:v=8'h08;
                8'hc0:v=8'hba; 8'hc1:v=8'h78; 8'hc2:v=8'h25; 8'hc3:v=8'h2e;
                8'hc4:v=8'h1c; 8'hc5:v=8'ha6; 8'hc6:v=8'hb4; 8'hc7:v=8'hc6;
                8'hc8:v=8'he8; 8'hc9:v=8'hdd; 8'hca:v=8'h74; 8'hcb:v=8'h1f;
                8'hcc:v=8'h4b; 8'hcd:v=8'hbd; 8'hce:v=8'h8b; 8'hcf:v=8'h8a;
                8'hd0:v=8'h70; 8'hd1:v=8'h3e; 8'hd2:v=8'hb5; 8'hd3:v=8'h66;
                8'hd4:v=8'h48; 8'hd5:v=8'h03; 8'hd6:v=8'hf6; 8'hd7:v=8'h0e;
                8'hd8:v=8'h61; 8'hd9:v=8'h35; 8'hda:v=8'h57; 8'hdb:v=8'hb9;
                8'hdc:v=8'h86; 8'hdd:v=8'hc1; 8'hde:v=8'h1d; 8'hdf:v=8'h9e;
                8'he0:v=8'he1; 8'he1:v=8'hf8; 8'he2:v=8'h98; 8'he3:v=8'h11;
                8'he4:v=8'h69; 8'he5:v=8'hd9; 8'he6:v=8'h8e; 8'he7:v=8'h94;
                8'he8:v=8'h9b; 8'he9:v=8'h1e; 8'hea:v=8'h87; 8'heb:v=8'he9;
                8'hec:v=8'hce; 8'hed:v=8'h55; 8'hee:v=8'h28; 8'hef:v=8'hdf;
                8'hf0:v=8'h8c; 8'hf1:v=8'ha1; 8'hf2:v=8'h89; 8'hf3:v=8'h0d;
                8'hf4:v=8'hbf; 8'hf5:v=8'he6; 8'hf6:v=8'h42; 8'hf7:v=8'h68;
                8'hf8:v=8'h41; 8'hf9:v=8'h99; 8'hfa:v=8'h2d; 8'hfb:v=8'h0f;
                8'hfc:v=8'hb0; 8'hfd:v=8'h54; 8'hfe:v=8'hbb; 8'hff:v=8'h16;
                default: v = 8'h00;
            endcase
            sb = v;
        end
    endfunction

    // SubWord: S-box each byte of a 32-bit word
    function [31:0] subword;
        input [31:0] w;
        subword = {sb(w[31:24]), sb(w[23:16]), sb(w[15:8]), sb(w[7:0])};
    endfunction

    // RotWord: left-rotate 32-bit word by one byte
    function [31:0] rotword;
        input [31:0] w;
        rotword = {w[23:0], w[31:24]};
    endfunction

    // Key words w[0..43]
    wire [31:0] w0  = key[127:96];
    wire [31:0] w1  = key[95:64];
    wire [31:0] w2  = key[63:32];
    wire [31:0] w3  = key[31:0];

    wire [31:0] w4  = w0  ^ subword(rotword(w3))  ^ RC1;
    wire [31:0] w5  = w1  ^ w4;
    wire [31:0] w6  = w2  ^ w5;
    wire [31:0] w7  = w3  ^ w6;

    wire [31:0] w8  = w4  ^ subword(rotword(w7))  ^ RC2;
    wire [31:0] w9  = w5  ^ w8;
    wire [31:0] w10 = w6  ^ w9;
    wire [31:0] w11 = w7  ^ w10;

    wire [31:0] w12 = w8  ^ subword(rotword(w11)) ^ RC3;
    wire [31:0] w13 = w9  ^ w12;
    wire [31:0] w14 = w10 ^ w13;
    wire [31:0] w15 = w11 ^ w14;

    wire [31:0] w16 = w12 ^ subword(rotword(w15)) ^ RC4;
    wire [31:0] w17 = w13 ^ w16;
    wire [31:0] w18 = w14 ^ w17;
    wire [31:0] w19 = w15 ^ w18;

    wire [31:0] w20 = w16 ^ subword(rotword(w19)) ^ RC5;
    wire [31:0] w21 = w17 ^ w20;
    wire [31:0] w22 = w18 ^ w21;
    wire [31:0] w23 = w19 ^ w22;

    wire [31:0] w24 = w20 ^ subword(rotword(w23)) ^ RC6;
    wire [31:0] w25 = w21 ^ w24;
    wire [31:0] w26 = w22 ^ w25;
    wire [31:0] w27 = w23 ^ w26;

    wire [31:0] w28 = w24 ^ subword(rotword(w27)) ^ RC7;
    wire [31:0] w29 = w25 ^ w28;
    wire [31:0] w30 = w26 ^ w29;
    wire [31:0] w31 = w27 ^ w30;

    wire [31:0] w32 = w28 ^ subword(rotword(w31)) ^ RC8;
    wire [31:0] w33 = w29 ^ w32;
    wire [31:0] w34 = w30 ^ w33;
    wire [31:0] w35 = w31 ^ w34;

    wire [31:0] w36 = w32 ^ subword(rotword(w35)) ^ RC9;
    wire [31:0] w37 = w33 ^ w36;
    wire [31:0] w38 = w34 ^ w37;
    wire [31:0] w39 = w35 ^ w38;

    wire [31:0] w40 = w36 ^ subword(rotword(w39)) ^ RC10;
    wire [31:0] w41 = w37 ^ w40;
    wire [31:0] w42 = w38 ^ w41;
    wire [31:0] w43 = w39 ^ w42;

    // Pack 11 round keys into output bus (RK0 at MSB end)
    assign round_keys[1407:1280] = {w0,  w1,  w2,  w3};
    assign round_keys[1279:1152] = {w4,  w5,  w6,  w7};
    assign round_keys[1151:1024] = {w8,  w9,  w10, w11};
    assign round_keys[1023:896]  = {w12, w13, w14, w15};
    assign round_keys[895:768]   = {w16, w17, w18, w19};
    assign round_keys[767:640]   = {w20, w21, w22, w23};
    assign round_keys[639:512]   = {w24, w25, w26, w27};
    assign round_keys[511:384]   = {w28, w29, w30, w31};
    assign round_keys[383:256]   = {w32, w33, w34, w35};
    assign round_keys[255:128]   = {w36, w37, w38, w39};
    assign round_keys[127:0]     = {w40, w41, w42, w43};

endmodule
