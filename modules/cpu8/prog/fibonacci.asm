; fibonacci.asm — compute Fibonacci numbers F(0)..F(12) and store in DRAM.
;
; Algorithm:
;   R1 = a (previous), R2 = b (current), R3 = loop counter, R4 = DRAM pointer
;
; After execution:
;   DRAM[0..12] = 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144

        LDI  R1, 0          ; a = 0 (F0)
        LDI  R2, 1          ; b = 1 (F1)
        LDI  R3, 13         ; loop count = 13 terms
        LDI  R4, 0          ; DRAM write pointer

loop:
        ST   [R4+0], R1     ; DRAM[ptr] = a
        ADD  R5, R1, R2     ; R5 = a + b (next term)
        LDI  R1, 0          ; a_new = b (via temp)
        ADD  R1, R2, R0     ; R1 = b (R0 is always 0)
        ADD  R2, R5, R0     ; R2 = a+b
        ADD  R4, R4, R0     ; R4++ (increment pointer — use LDI trick below)
        LDI  R6, 1
        ADD  R4, R4, R6     ; R4 = R4 + 1
        LDI  R6, 1
        SUB  R3, R3, R6     ; counter--
        BR   NE, loop       ; loop while R3 != 0
        HLT
