;=== Global Variables ===
; available direct page memory $00-$DF
; available lower WRAM $1000-$1EFF (leaving $100 for stack)
; available upper WRAM $7E:2000-FFFF, $7F:0800-FFFF

.DEFINE OutputBuffer   $1000

;direct page variables
.ENUM $20
	OutputOffset        DW	;offset in decompressed output
	InputMaskOffset     DW	;offset in input for bit mask
	InputSubOffset      DW  ;offset in input for subtraction
	OutputBitMask       DB  ;mask for current bit we're focussing on
	InputBitMask        DB  ;mask for top non-zero bit 
	InputSubtract       DB  ;step size for searching for transitions
	
	SramOffset          DW  ;offset for next location in SRAM

	InputBuffer     DSB $10 ; $10 byte buffer

	BitCount            DW
	SaveCursor          DW 
.ENDE


;=== Test code ===

	SetTextColor TxtBlue
	PrintString " Starting decomp run...\n"
	PrintString "   decomp $"
	jsr VBlankUpdate

	;Setup
	ldx #$0000
	stx OutputOffset
	stx InputMaskOffset
	stx SramOffset
	ldx #$0001
	stx InputSubOffset

	ldx #$0000
	stz BitCount
	ldx Cursor
	stx SaveCursor

	ldx #$000F
	lda #$FF
-	sta InputBuffer,x
	dex
	bpl -

	lda #$80
	sta OutputBitMask
	lda #$80
	sta InputBitMask
	lda #$80
	sta InputSubtract

next_decomp:
	;purge fifo
	ldx #$0020
-	lda $4810
	dex
	bne -

	;stuff fifo
	;dummy table
	lda #$00
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	sta FIFOwrite
	;actual compressed data
	ldx #$0000
-	lda InputBuffer,x
	sta FIFOwrite
	inx
	cpx #$0010
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
	ldy OutputOffset
-	lda $4800
	sta OutputBuffer,x
	inx
	dey
	bpl -

;	;show status
;	ldx Cursor
;	phx
;
;	PrintString "\n In:"
;	ldx #$0000
;-	lda InputBuffer,x
;	jsr PrintHex8_noload
;	inx 
;	cpx #$0010
;	bne -	
;	PrintString "\n Out:"
;	ldx #$0000
;-	lda OutputBuffer,x
;	jsr PrintHex8_noload
;	inx 
;	cpx #$0010
;	bne -	
;
;	plx
;	stx Cursor
;	ldx #$0000
;	stx Joy1Press
;-	jsr VBlankUpdate
;	ldx Joy1Press
;	beq -

	;check results
	ldx OutputOffset
	lda OutputBuffer,x
	and OutputBitMask
	beq FoundCutoff

	;continue search
	ldx InputSubOffset
	lda InputBuffer,x
	sec
	sbc InputSubtract
	sta InputBuffer,x
	cmp #$FF
	bne +
-	dex
	lda InputBuffer,x
	dec a
	sta InputBuffer,x
	cmp #$FF
	beq -
+

	ldx InputMaskOffset
	lda InputBuffer,x
	and InputBitMask
	beq +
	jmp next_decomp
+
	
	lsr InputSubtract
	bne +
	ldx InputSubOffset
	inx
	stx InputSubOffset
	lda #$80
	sta InputSubtract
+

	lsr InputBitMask
	bne +
	ldx InputMaskOffset
	inx
	stx InputMaskOffset
	lda #$80
	sta InputBitMask
+
	jmp next_decomp

FoundCutoff:
	ldx BitCount
	inx
	stx BitCount
	ldx SaveCursor
	stx Cursor
	lda BitCount+1
	jsr PrintHex8_noload
	lda BitCount
	jsr PrintHex8_noload
	jsr VBlankUpdate

	;save results
	ldy #$0000
	ldx SramOffset
-	lda InputBuffer,y
	sta.l SRAM,x
	inx
	iny
	cpy #$0010
	bne -
	
	rep #$30
	lda SramOffset
	clc
	adc #$0010
	sta SramOffset
	sep #$20	

	;goto next bit
	lsr OutputBitMask
	bne +
	ldx OutputOffset
	inx
	stx OutputOffset
	lda #$80
	sta OutputBitMask
+	

	ldx OutputOffset
	cpx #$0080
	beq decomp_done
	jmp next_decomp

decomp_done:
	PrintString "\n   Decomp done!"
	jsr VBlankUpdate

forever:
	;do whatever you feel like here	

	;let's print the current frame number
	SetCursorPos 26, 4
	ldy #FrameNum
	PrintString "Frame num = %d    "
	jsr VBlankUpdate

	jmp forever
