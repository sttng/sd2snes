;------------------------------------------------------------------------
;-  Written by: Neviksti
;-     If you use my code, please share your creations with me
;-     as I am always curious :)
;------------------------------------------------------------------------

;=== Include MemoryMap, VectorTable, HeaderInfo ===
.INCLUDE "t7110.inc"

;=== Include Library Routines & Macros ===
.INCLUDE "InitSNES.asm"
.INCLUDE "LoadGraphics.asm"
.INCLUDE "QuickSetup.16bit.asm"

;=== Global Variables ===

.DEFINE TestBuffer   $1E00

.DEFINE FIFOwrite  $805000
.DEFINE SRAM       $700000

;==============================================================================
; RAM code
;   code and routines to be ran in $0100-$0FFF
;   fault check made automatically at $1000 (will see error at linking)
;==============================================================================

.BANK 0 SLOT 1
.ORG $0100
.SECTION "RAMcode" FORCE

ramcode_start:
	.INCLUDE "Input.RAM.asm"
	.INCLUDE "Strings.RAM.asm"

ram_mainentry:	


	;init SPC7110 access
	lda #$02
	sta $4834
	lda #$80

	sta $4830
	stz $4830
	sta $4830
	sta $4830

	stz $4830
	sta $4830
	stz $4830
	sta $4830

	stz $4830
	sta $4830
	stz $4830
	sta $4830

	sta $4830
	stz $4830
	sta $4830
	stz $4830

	;clear FIFO
	stz $4818	;command
	ldx #$0000
	stx $4811	;address
	lda #$00
	sta $4813	;bank
	stz $4816	;pointer increment
	stz $4817	; "
	stz $4814	;pointer adjust
	stz $4815	; "

	ldx #$0000
-	lda $4810
	dex
	bne -


	SetCursorPos 0,0
	;              123456789012345678901234567890 123456789012345678901234567890
	PrintString "Test SPC7110                    "
	PrintString "--------------------------------"

	PrintString "\nTesting for SPC7110... "
	ldx Cursor
	phx
	jsr VBlankUpdate

	;Check first 8 and last 8 bytes of DataROM
	;0102040810204080
	;FEFDFBF7EFDFBF7F

	stz $4818	;command
	ldx #$0000
	stx $4811	;address
	lda #$00
	sta $4813	;bank
	stz $4816	;pointer increment
	stz $4817	; "
	stz $4814	;pointer adjust
	stz $4815	; "

	PrintString "\n START:"
	stz $01 ;fail flag

	;stuff values into FIFO
	ldx #$0000
	lda #$01 ;compare val
	sta $00
-	lda $00
	sta FIFOwrite
	asl $00
	inx
	cpx #$0008
	bne -
	lda $4810

	;lda $7F0000		;no effect
	;sta $7F0000		;no effect
	;lda $7E0000		;no effect
	;sta $7E0000		;no effect
	;lda $008000		;no effect
	;sta $008000		;no effect
	;lda $700000		;no effect
	;sta $700000		;no effect
	;lda $708000		;no effect
	;sta $708000		;no effect
	;stz $420B			;no effect
	;jsr VBlankUpdate		;the $420B write here does affect readout


	ldx #$0000
	lda #$01 ;compare val
	sta $00
-	lda $4810
	cmp $00
	beq +
	inc $01
+	sta TestBuffer,x
	asl $00
	inx
	cpx #$0008
	bne -

	ldx #$0000
-	lda TestBuffer,x
	jsr PrintHex8_noload
	inx
	cpx #$0008
	bne -

	stz $4818	;command
	ldx #$FFF8
	stx $4811	;address
	lda #$3F
	sta $4813	;bank
	stz $4816	;pointer increment
	stz $4817	; "
	stz $4814	;pointer adjust
	stz $4815	; "

	PrintString "\n   END:"

	;stuff values into FIFO
	ldx #$0000
	lda #$FE ;compare val
	sta $00
-	lda $00
	sta FIFOwrite
	sec
	rol $00
	inx
	cpx #$0008
	bne -
	lda $4810

	ldx #$0000
	lda #$FE ;compare val
	sta $00
-	lda $4810
	cmp $00
	beq +
	inc $01
+	jsr PrintHex8_noload
	sec
	rol $00
	inx
	cpx #$0008
	bne -

	plx
	stx Cursor
	lda #$00
	cmp $01
	beq +
	SetTextColor TxtRed
	PrintString "FAIL"
	bra ++
+	SetTextColor TxtGreen
	PrintString "PASS"
++	
	SetTextColor TxtWhite
	jsr VBlankUpdate

	; Print cartridge name
	PrintString "\n\n\n Cart=["
	
	ldx #$0000
-	lda $80FFC0,X
	jsr Print
	inx
	cpx #$0015
	bne -	

	PrintString "] \n\n"
	jsr VBlankUpdate

	
	PrintString " Trying decomp 000008-5F..."
	jsr VBlankUpdate

	;stuff values into FIFO
	;dummy table
	lda #$00
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	;actual compressed data
	ldx #$0000
-	lda.w comp_data,x
	sta FIFOwrite
	inx
	cpx #comp_data_end-comp_data
	bne -
	;lda $4810	;not needed here, apparrently one of the reg writes below trips a U2 ROM access

	;do decompression
	stz $480B
	ldx #$0008	;table address
	stx $4801
	lda #$00	;table bank
	sta $4803
	lda #$5F	;index
	sta $4804

	stz $4805
	stz $4806

	jsr DecompWait

	ldx #$0000
	stz $00
-
	lda $4800
	;sta $700000,x
	;jsr PrintHex8_noload
	;lda $700000,x
	cmp.w decomp_data,x
	beq +
	lda #$01
	sta $00
+ 
	inx
	cpx #decomp_data_end-decomp_data
	bne -

	lda #$00
	cmp $00
	beq +
	SetTextColor TxtRed
	PrintString "FAIL"
	bra ++
+	SetTextColor TxtGreen
	PrintString "PASS"
++	
	SetTextColor TxtWhite
	jsr VBlankUpdate



	PrintString "\n\n Trying decomp 000184-00..."
	jsr VBlankUpdate

	;stuff values into FIFO
	;dummy table
	lda #$00
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	;actual compressed data
	ldx #$0000
-	lda.w comp_data,x
	sta FIFOwrite
	inx
	cpx #comp_data_end-comp_data
	bne -
	;lda $4810	;not needed here, apparrently one of the reg writes below trips a U2 ROM access

	;do decompression
	stz $480B
	ldx #$0184	;table address
	stx $4801
	lda #$00	;table bank
	sta $4803
	lda #$00	;index
	sta $4804

	stz $4805
	stz $4806

	jsr DecompWait

	ldx #$0000
	stz $00
-
	lda $4800
	;sta $701000,x
	;jsr PrintHex8_noload
	;lda $701000,x
	cmp.w decomp_data,x
	beq +
	lda #$01
	sta $00
+ 
	inx
	cpx #decomp_data_end-decomp_data
	bne -

	lda #$00
	cmp $00
	beq +
	SetTextColor TxtRed
	PrintString "FAIL"
	bra ++
+	SetTextColor TxtGreen
	PrintString "PASS"
++	
	SetTextColor TxtWhite
	jsr VBlankUpdate

	PrintString "\n Tests done.\n\n"
	jsr VBlankUpdate

	.include "testcode.asm"

;--------------------------------
comp_data:
	.incbin "000008-5F.compressed"
comp_data_end:

decomp_data:
	.incbin "000008-5F.uncompressed"
decomp_data_end:

;--------------------------------
DecompWait:
	phx
	
	; try $4000 times before allowing exit do to pressing A
	ldx #$4000
-	lda $480C
	bmi end_decompwait	;When Bit 7 of 00:480C is set, Decompression is done, and
	dex				;data is ready to be read.
	bne -

	stz Joy1Press
-	jsr VBlankUpdate
	lda Joy1Press	;allow pressing A to escape loop
	bmi +
	lda $480C
	bpl -			;When Bit 7 of 00:480C is set, Decompression is done, and
+				;data is ready to be read.

end_decompwait:
	plx
	rts

;--------------------------------

transferBG3:
	;*********transfer BG3 data
	LDA #$80
	STA $2115		;set up VRAM write to "word write"

	LDX #$0400
	STX $2116		;set VRAM address to BG3 tile map

	LDY #$1801
	STY $4300		; CPU -> PPU, auto increment, write 2 regs, $2118
	LDY #(TextBuffer & $FFFF)
	STY $4302		; source offset
	LDY #$0800
	STY $4305		; number of bytes to transfer
	LDA #(TextBuffer >> 16)
	STA $4304		; bank address = $7F  (work RAM)
	LDA #$01
	STA $420B		;start DMA transfer

;	rep #$30
;	ldx #$0000
;-	lda TextBuffer, x
;	sta $2118
;	inx
;	inx
;	cpx #$0800
;	bne -
;	sep #$20

	rts

;--------------------------------

VBlankUpdate:
	php
	rep #$30
	pha
	phx
	phy
	sep #$20		; mem/A = 8 bit, X/Y = 16 bit
	
wait_till_out:
	lda $4212
	asl A
	bcs wait_till_out		;wait for out of v-blank

wait_till_start:
	lda $4212
	asl A
	bcc wait_till_start	;wait for start of v-blank

	jsr transferBG3

	;update the joypad data
	jsr GetInput

	rep #$30		;A/Mem=16bits, X/Y=16bits
	inc FrameNum
	ply
	plx
	pla
	plp
	rts

	sep #$20	;to help WLA out

;--------------------------------
ramcode_end: 

.ENDS

.BANK 0 SLOT 1
.ORG $1000
.SECTION "FaultCheck" FORCE
	.db $00
.ENDS

;==============================================================================
; main
;==============================================================================

.BANK 0 SLOT 0
.ORG 0
.SECTION "MainCode"

Main:
	InitializeSNES	

	jsr QuickSetup	; set VRAM, the video mode, background and character pointers, 
				; and turn on the screen

	;For easy reading, clear SRAM to all FF
	ldx #$7FFF
	lda #$FF
-	sta SRAM,X
	dex
	bpl -	

	;Copy RAMcode section to RAM
	ldx #$0100
-	lda.w $8000,x
	sta.w $0000,x
	inx
	cpx #ramcode_end
	bne -

	;Jump to ram code
	jmp ram_mainentry

.ENDS

