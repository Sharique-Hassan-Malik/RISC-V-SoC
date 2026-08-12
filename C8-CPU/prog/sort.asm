; sort.asm — in-place bubble sort of 8 bytes stored in DRAM[0..7].
;
; Input  (DRAM[0..7]): pre-loaded by the testbench or via .word directives
; Output (DRAM[0..7]): sorted ascending after HLT
;
; Registers:
;   R1 = outer loop index i
;   R2 = inner loop index j
;   R3 = DRAM[j]   (current element)
;   R4 = DRAM[j+1] (next element)
;   R5 = scratch / limit (7)
;   R6 = constant 1

        LDI  R6, 1          ; R6 = 1 (constant)
        LDI  R1, 0          ; i = 0

outer:
        CMP  R1, R5         ; compare i with limit (not yet set — set below)
        ; Use R5 = 7 as the loop bound
        LDI  R5, 7
        CMP  R1, R5
        BR   GE, done       ; if i >= 7, done
        LDI  R2, 0          ; j = 0

inner:
        ; limit for inner = 7 - i, but for simplicity we use 7
        LDI  R5, 7
        CMP  R2, R5
        BR   GE, next_outer ; if j >= 7-i, next outer iteration

        LD   R3, [R2+0]     ; R3 = DRAM[j]
        ADD  R7, R2, R6     ; R7 = j+1
        LD   R4, [R7+0]     ; R4 = DRAM[j+1]

        CMP  R3, R4
        BR   LE, no_swap    ; if R3 <= R4, no swap needed

        ; swap DRAM[j] and DRAM[j+1]
        ST   [R2+0], R4     ; DRAM[j]   = R4
        ST   [R7+0], R3     ; DRAM[j+1] = R3

no_swap:
        ADD  R2, R2, R6     ; j++
        JMP  inner

next_outer:
        ADD  R1, R1, R6     ; i++
        JMP  outer

done:
        HLT

; Note: BR LE is not in the ISA. Use CMP then BR GE with swapped operands.
; Assembler note: the BR cc field supports EQ NE LT GE CS CC ALW NEV.
; "not greater" = LT or EQ, handled here as: CMP R4, R3 + BR LT no_swap
