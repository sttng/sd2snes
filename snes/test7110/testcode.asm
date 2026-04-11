;Enable this to pause and show status after each decomp
;.DEFINE SHOWSTATUS 1

;=== Global Variables ===
; available direct page memory $00-$DF
; available lower WRAM $1000-$1EFF (leaving $100 for stack)
; available upper WRAM $7E:2000-FFFF, $7F:0800-FFFF

.DEFINE InputBuffer    $1000
.DEFINE InputBufferLen $0400

;direct page variables
.ENUM $20
	OutputOffset        DW	;offset in decompressed output
	InputOffset         DW	;offset in input
	LowestProbBit       DB  ;bit mask for lowest prob bit in input byte

	Span                DB  ;current distance between TOP and BOT (lower bits implied 1's)
      Prob                DB  ;test probability
	Result              DB  ;result to save
	SavedBit            DB  ;saved output bit

	tempL               DB  ; temp values for shifting
	tempH               DB  ;

	OutputByte          DB  ;place to save the one output byte we're interested in
	OutputBitMask       DB  ;mask for current bit we're focussing on
	
	SramOffset          DW  ;offset for next location in SRAM

	BitCount            DW  ;how many prob/mps calculations already done
	SaveCursor          DW  ;save text cursor position

	EndOffset           DW  ;how many bytes in the test sequence
.ENDE


;=== Test code ===

	SetTextColor TxtBlue
	PrintString " Starting decomp run...\n"
	PrintString "   decomp $"
	jsr VBlankUpdate

	;Setup
	ldx Cursor
	stx SaveCursor

	ldx #$0000
	stx OutputOffset
	stx InputOffset
	stx SramOffset
	stx BitCount

	ldx #sequence_end-sequence
	stx EndOffset

	lda #$FF
	sta Span

	lda #$01
	sta LowestProbBit

	lda #$FF
	ldx #InputBufferLen-1
-	sta InputBuffer,x
	dex
	bpl -

	lda #$80
	sta OutputBitMask

next_bit:
	stz Prob	
	stz Result
	stz SavedBit

	;first decomp to check mps
	jsr do_decomp

	;check results
	lda OutputByte
	and OutputBitMask
	sta SavedBit
	bne +
	lda #$80	; MPS = 1
	sta Result
+

next_prob_test:
	inc Prob

	;check for prob "overflow"
	lda Prob
	cmp #$80
	bne +
	PrintString "\n ERROR: Prob overflow"
	jmp decomp_done 
+

	;lower input stream one lowest prob bit
	ldx InputOffset
	lda InputBuffer,x
	sec
	sbc LowestProbBit
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

	jsr do_decomp

	;did output bit change?
	lda OutputByte
	and OutputBitMask
	cmp SavedBit
	beq next_prob_test


	;save result
	ldx SramOffset
	lda Result
	ora Prob
	sta SRAM,x
	inx
	stx SramOffset	

	;adjust input stream, if the sequence we're following is supposed to be a LPS
	ldx OutputOffset
	lda.w sequence,x
	and OutputBitMask
	cmp SavedBit
	bne adjust_for_mps

adjust_for_lps:
	lda Prob
	sta tempL
	stz tempH

	lda LowestProbBit
	sta SavedBit
-	lsr SavedBit
	beq +
	asl tempL
	rol tempH
	bra -
+

	ldx InputOffset
	lda InputBuffer,x
	clc
	adc tempL
	sta InputBuffer,x
	lda InputBuffer-1,x
	adc tempH
	sta InputBuffer-1,x
	bcc +
	dex
-	dex
	lda InputBuffer,x
	clc
	adc #$01
	sta InputBuffer,x
	bcs -
+
	
	lda Prob
	dec A
	sta Span
	jmp shift_span

adjust_for_mps:
	lda Span
	sec
	sbc Prob
	sta Span

shift_span:
	lda Span
	cmp #$7F		; strange border case
	beq finish_bit	;
	lda Span
	bmi finish_bit

-	lsr LowestProbBit
	bne +
	ldx InputOffset
	inx
	stx InputOffset
	lda #$80
	sta LowestProbBit
+	
	sec
	rol Span
	bmi finish_bit
	lda Span
	cmp #$7F		; strange border case
	bne -

finish_bit:
	lsr OutputBitMask
	bne +
	ldx OutputOffset
	inx
	stx OutputOffset
	lda #$80
	sta OutputBitMask
+	

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

	ldx OutputOffset
	cpx EndOffset
	beq decomp_done

	ldx InputOffset
	cpx #InputBufferLen
	bne +
	PrintString "\n ERROR: InputBuffer too small"
	jmp decomp_done 
+
	jmp next_bit	


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


;-----------------------------------------

do_decomp:
	;purge fifo
	stz $4818	;command
	ldx #$0000
	stx $4811	;address
	lda #$00
	sta $4813	;bank
	stz $4816	;pointer increment
	stz $4817	; "
	stz $4814	;pointer adjust
	stz $4815	; "
	ldx #InputBufferLen
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
	cpx #InputBufferLen
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

	ldx OutputOffset
-	lda $4800
	dex
	bpl -
	sta OutputByte

.IFDEF SHOWSTATUS
	;show status
	ldx Cursor
	phx

	PrintString "\n In:"
	ldx #$0000
-	lda InputBuffer,x
	jsr PrintHex8_noload
	inx 
	cpx #$0008
	bne -	
	PrintString "\n Out:"
	lda OutputByte
	jsr PrintHex8_noload

	PrintString "\n Span:"
	lda Span
	jsr PrintHex8_noload

	PrintString "\n Prob:"
	lda Prob
	jsr PrintHex8_noload

	plx
	stx Cursor
	ldx #$0000
	stx Joy1Press
-	jsr VBlankUpdate
	lda Joy1
	and #$10	; let R button skip even if just held down
	bne +
	ldx Joy1Press
	beq -
+
.ENDIF

	rts

;-----------------------------------------
sequence:
	.incbin "input_7030_an1.bin"
	;.incbin "inputFFFF.bin"
	;.incbin "input0000.bin"
sequence_end:
