;------------------------------------------------------------------------
;-  Written by: Neviksti
;-     If you use my code, please share your creations with me
;-     as I am always curious :)
;------------------------------------------------------------------------

;JoyPad variables = $F4 to $FF

.ENUM $F4
TempJoy1 	DW	; Used for reading in serial data
TempJoy2	DW	;

Joy1 		DW	; Current button state of joypad1, bit0=0 if it is a valid joypad
Joy2		DW	;same thing for all pads...

Joy1Press	DW	; Holds joypad1 keys that are pressed and have been pressed since
			;   clearing this mem location
Joy2Press	DW	;same thing for all pads...

.ENDE


.DEFINE HVBJOY	$4212
.DEFINE JOY0	$4218
.DEFINE JOY1	$421A
.DEFINE JOY2	$421C
.DEFINE JOY3	$421E
.DEFINE JOYSER0	$4016
.DEFINE JOYSER1	$4017
.DEFINE WRIO	$4201


GetInput:
	php
	rep #$30
	pha
	phx
	sep 	#$20	;8 bit mem/A

	lda #$C0		;tell any multitaps to use the first pair of joypads
	sta WRIO

	stz JOYSER0		;
	lda #$01		; toggle JoySer0... latches joypad states
	sta JOYSER0		;
	stz JOYSER0		;

	ldx #$0008
-	lda JOYSER0		; rotate JoySer0, bit0 into TempJoy1
	lsr A
	rol TempJoy1+1
	lda JOYSER1		; rotate JoySer1, bit0 into TempJoy2
	lsr A
	rol TempJoy2+1
	dex
	bne -			; do this 8 times

	ldx #$0008
-	lda JOYSER0		; rotate JoySer0, bit0 into TempJoy1
	lsr A
	rol TempJoy1
	lda JOYSER1		; rotate JoySer1, bit0 into TempJoy2
	lsr A
	rol TempJoy2
	dex
	bne -			; do this 8 times


	rep	#$30	;16 bit mem/A, 16 bit X/Y

	lda TempJoy1	;get JoyPad1
	tax 			
	eor Joy1		;A = A xor JoyState = (changes in joy state)
	stx Joy1		;update JoyState
	ora Joy1Press	;A = (joy changes) or (buttons pressed)
	and Joy1		;A = ((joy changes) or (buttons pressed)) and (current joy state)  
	sta Joy1Press	;store A 
		; A = (buttons pressed since last clearing reg) and (button is still down)

	lda TempJoy2	;get JoyPad2
	tax 			
	eor Joy2		;A = A xor JoyState = (changes in joy state)
	stx Joy2		;update JoyState
	ora Joy2Press	;A = (joy changes) or (buttons pressed)
	and Joy2		;A = ((joy changes) or (buttons pressed)) and (current joy state)  
	sta Joy2Press	;store A 
		; A = (buttons pressed since last clearing reg) and (button is still down)

	; ********** Make sure Joypads 1,2 are valid

	sep #$30		;A/mem = 8bit, X/Y = 8bit

	lda JOYSER0
	eor #$01
	and #$01		; A = -bit0 of JoySer0
	ora Joy1		
	sta Joy1		; joy state = (joy state) or A.... 
				; so bit0 of Joy1State = 0 only if it is a valid joypad

	lda JOYSER1
	eor #$01
	tax
	and #$01		; A = -bit0 of JoySer1
	ora Joy2		
	sta Joy2		; joy state = (joy state) or A.... 
				;so bit0 of Joy1State = 0 only if it is a valid joypad

	; ********** Change all invalid joypads to have a state of no button presses

	rep #$30		;A/mem = 16bit, X/Y = 16bit

	ldx #$0001
	lda #$000F

	bit Joy1		; A = joy state, if any of the bottom 4 bits are on... 
	beq _joy2		; either nothing is plugged into the joy port, or it is not a joypad
	stx Joy1		; if it is not a valid joypad put $0001 into the 2 joy state variables
	stx Joy1Press

_joy2:
	bit Joy2		; A = joy state, if any of the bottom 4 bits are on...
	beq _done		; either nothing is plugged into the joy port, or it is not a joypad
	stx Joy2		; if it is not a valid joypad put $0001 into the 2 joy state variables
	stx Joy2Press

_done:
	rep #$30
	plx
	pla
	plp
	rts

	sep #$20 ;to help WLA out