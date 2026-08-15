; blink.asm — chasing LED pattern for iCEstick (5 LEDs).
;
; The top-level Verilog reads DRAM[0x00] and drives the 5 onboard LEDs
; from bits [4:0] of that byte.
;
; This program shifts a single lit LED left through positions 0..4,
; wrapping back to 0 when it reaches position 4.  A software delay loop
; between each shift slows the pattern to ~1 Hz at 12 MHz.
;
; Registers:
;   R1 = LED pattern (1 bit set)
;   R2 = delay counter
;   R3 = limit (constant 5 — number of LED positions)
;   R4 = constant 1
;   R5 = mask (0x1F = 5-bit mask to prevent wrap onto unused bits)

        LDI  R1, 1          ; start with LED 0 lit
        LDI  R3, 5          ; number of LED positions
        LDI  R4, 1          ; constant 1
        LDI  R5, 31         ; mask 0x1F

main:
        ST   [R0+0], R1     ; DRAM[0] = LED pattern → drives hardware LEDs

        ; Software delay: count down from 0xFFFF-ish using nested loops
        ; Outer delay counter in R2 (255 iterations)
        LDI  R2, 255
delay_outer:
        ; Inner delay (255 iterations per outer step)
        ; We reuse R6 for inner counter — load 255 each outer iter
        LDI  R6, 255
delay_inner:
        SUB  R6, R6, R4     ; R6--
        BR   NE, delay_inner
        SUB  R2, R2, R4     ; R2--
        BR   NE, delay_outer

        ; Shift the LED pattern left by 1
        SHF  R1, R1, SHL
        AND  R1, R1, R5     ; mask to 5 bits

        ; If pattern became 0 (shifted off the top), reset to 1
        CMP  R1, R0         ; compare with 0 (R0 always = 0)
        BR   NE, main
        LDI  R1, 1          ; reset to LED 0
        JMP  main
