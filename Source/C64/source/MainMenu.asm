; MIT License
; 
; Copyright (c) 2023 Travis Smith
; 
; Permission is hereby granted, free of charge, to any person obtaining a copy of this software 
; and associated documentation files (the "Software"), to deal in the Software without 
; restriction, including without limitation the rights to use, copy, modify, merge, publish, 
; distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom 
; the Software is furnished to do so, subject to the following conditions:
; 
; The above copyright notice and this permission notice shall be included in all copies or 
; substantial portions of the Software.
; 
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING 
; BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND 
; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, 
; DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


; ********************************   Symbols   ********************************   
   ;!set Debug = 1 ;if defined, skips HW checks/waits 
   !convtab pet   ;key in and text out conv to PetSCII throughout
   !src "source\c64defs.i"  ;C64 colors, mem loctions, etc.
   !src "source\Menu_Regs.i"  ;IO space registers matching Teensy code

   ;color scheme:
   BorderColor      = PokePurple
   BackgndColor     = PokeBlack
   TimeColor        = ChrOrange
   MenuMiscColor    = ChrGreen
   ROMNumColor      = ChrDrkGrey
   AssignedIOHColor = ChrCyan
   OptionColor      = ChrYellow
   SourcesColor     = ChrLtBlue
   TypeColor        = ChrBlue
   NameColor        = ChrLtGreen
   M2SDataColumn    = 14

   GreyOutColor     = PokeDrkGrey
   UpIndicColorLoc  = ScreenColorMemStart+20*40+18
   DnIndicColorLoc  = ScreenColorMemStart+20*40+21

   ;Zero page RAM Registers:
   PtrAddrLo   = $fb
   PtrAddrHi   = $fc
   Ptr2AddrLo  = $fd
   Ptr2AddrHi  = $fe
   ;other RAM Registers/code space
   ;$0334-033b is "free space"
   MusicPlaying     = $0335 ;is the music playing?
   SIDVoicCont      = $0338 ;midi2sid polyphonic voice/envelope controls
   SIDAttDec        = $0339
   SIDSusRel        = $033a
   SIDDutyHi        = $033b
   
   ;$033c-03fb is the tape buffer (192 bytes)
   PRGLoadStartReloc= $033c 
   
   ;RAM coppies:
   MainCodeRAM = $2400    ;this file
   SIDCodeRAM = $1000 

;******************************* Main Code Start ************************************   

* = MainCodeRAM
Start:

;screen setup:     
   lda #BorderColor
   sta BorderColorReg
   lda #BackgndColor
   sta BackgndColorReg
   
!ifndef Debug {
;check for HW:
   lda rRegPresence1+IO1Port
   cmp #$55
   bne NoHW
   lda rRegPresence2+IO1Port
   cmp #$AA
   beq +
NoHW:
   lda #<MsgNoHW
   ldy #>MsgNoHW
   jsr PrintString  
   ;jmp (BasicWarmStartVect)
-  jmp -
}

+  lda #rCtlVanishROM ;Deassert Game & ExROM
   sta wRegControl+IO1Port

   lda #$00
   jsr SIDCodeRAM ;Initialize music
   
   jsr ListMenuItems

   ;check default registers for music & time settings
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudMusicMask
   sta MusicPlaying
   beq +
   jsr SIDMusicOn

+  lda rwRegPwrUpDefaults+IO1Port
   and #rpudNetTimeMask
   beq +
   jsr SynchEthernetTime
   jmp WaitForKey
   
+  lda #0  ;set clock to midnight if not synching
   sta TODHoursBCD  ;stop TOD regs incrementing
   sta TODMinBCD
   sta TODSecBCD
   sta TODTenthSecBCD ;have to write 10ths to release latch, start incrementing


WaitForKey:     
   jsr DisplayTime
   jsr GetIn    
   beq WaitForKey

   cmp #'a'  
   bmi +   ;skip if below 'a'
   cmp #'a'+ MaxItemsPerPage + 1  
   bpl +   ;skip if above MaxItemsPerPage
   sec       ;set to subtract without carry
   sbc #'a'  ;convert to Item Number on page, now 0-?
   cmp rRegNumItemsOnPage+IO1Port 
   bpl WaitForKey   ;skip if above num of items on page
   sta rwRegSelItemOnPage+IO1Port ;select Item from page
   jsr SelectMenuItem
   jmp WaitForKey

+  cmp #ChrCSRSDn  ;Next Page
   bne +
   lda rwRegPageNumber+IO1Port
   cmp rRegNumPages+IO1Port
   beq WaitForKey ;already on last page
   inc rwRegPageNumber+IO1Port ;Tell TR to Page Down
   jsr ListMenuItems
   jmp WaitForKey

+  cmp #ChrCSRSUp  ;Prev Page
   bne +

   lda rwRegPageNumber+IO1Port
   cmp #1
   beq WaitForKey ;already on first page
   dec rwRegPageNumber+IO1Port ;Tell TR to Page Up
   jsr ListMenuItems
   jmp WaitForKey  

+  cmp #ChrF1  ;Teensy mem Menu
   bne +
   lda #rmtTeensy
   jsr ListMenuItemsChangeInit
   jmp WaitForKey  

+  cmp #ChrF2  ;Exit to BASIC
   bne +
   lda #rCtlBasicReset ;reset to BASIC
   sta wRegControl+IO1Port
-  jmp -  ;should be resetting to BASIC

+  cmp #ChrF3  ;SD Card Menu
   bne +
   lda #rmtSD
   jsr ListMenuItemsChangeInit
   jmp WaitForKey  

+  cmp #ChrF4  ;toggle music
   bne +
   jsr ToggleSIDMusic
   jmp WaitForKey  

+  cmp #ChrF5  ;USB Drive Menu
   bne +
   lda #rmtUSBDrive
   jsr ListMenuItemsChangeInit
   jmp WaitForKey  

+  cmp #ChrF6  ;Settings Menu
   bne +
   jsr SettingsMenu
   jsr ListMenuItems
   jmp WaitForKey  

+  cmp #ChrF7  ;Exe USB Host file
   bne +
   lda #rmtUSBHost
   jsr ListMenuItemsChangeInit
   jmp WaitForKey

+  cmp #ChrF8  ;MIDI to SID
   bne +
   jsr MIDI2SID
   jsr ListMenuItems
   jmp WaitForKey


+  jmp WaitForKey

   
; ******************************* Subroutines ******************************* 

___Subroutines________________________________:


;                           list out item number, type, & names
ListMenuItemsChangeInit:  ;changing menu source.  Prep: Load acc with menu to change to
   sta rWRegCurrMenuWAIT+IO1Port  ;must wait on a write (load dir)
   jsr WaitForTR
ListMenuItems:
   jsr PrintBanner 
   
   ldx #20 ;row   Print the select message now so we can grey out the up/dn soon if needed
   ldy #0  ;col
   clc
   jsr SetCursor
   lda #<MsgSelect1
   ldy #>MsgSelect1
   jsr PrintString
   
   lda rwRegPageNumber+IO1Port
   jsr PrintHexByte
   lda #'/'
   jsr SendChar   
   lda rRegNumPages+IO1Port
   jsr PrintHexByte
   
   lda #<MsgSelect2
   ldy #>MsgSelect2
   jsr PrintString
   
   ldx #2  ;row
   ldy #0  ;col
   ;clc
   jsr SetCursor
   lda #<MsgSource
   ldy #>MsgSource
   jsr PrintString 
   ;print menu source from table:
   lda rWRegCurrMenuWAIT+IO1Port ;don't have to wait on a read
   asl ;double it to point to word
   tax
   lda TblMsgMenuName,x
   ldy TblMsgMenuName+1,x
   jsr PrintString
   
   lda rRegNumItemsOnPage+IO1Port
   bne +
   jsr GreyOutUp  ;no items, no up/dn
   jsr GreyOutDn  ;no items, no up/dn
   lda #<MsgNoItems
   ldy #>MsgNoItems
   jsr PrintString
   rts ;early exit
   
+  ldx rwRegPageNumber+IO1Port
   cpx #1
   bne +
   jsr GreyOutUp  ;we're at the first page,no up
+  cpx rRegNumPages+IO1Port
   bne +
   jsr GreyOutDn  ;we're at the last page,no down

+  lda #0       ;initialize to first Item on Page
   sta rwRegSelItemOnPage+IO1Port
nextLine
   lda #ChrReturn
   jsr SendChar
   
;print option letter
   lda #OptionColor
   jsr SendChar
   lda #ChrSpace
   jsr SendChar
   lda #ChrRvsOn
   jsr SendChar
   lda rwRegSelItemOnPage+IO1Port
   clc
   adc #'A'
   jsr SendChar
   lda #ChrRvsOff
   jsr SendChar
   lda #'-'
   jsr SendChar
; print name
   lda #NameColor
   jsr SendChar
   lda #rsstItemName
   jsr PrintSerialString
;align to col
   sec
   jsr SetCursor ;read current to load x (row)
   ldy #MaxItemNameLength + 2  ;set y = col
   clc
   jsr SetCursor
; print type
   lda #TypeColor
   jsr SendChar
   ldx #<TblItemType
   ldy #>TblItemType
   lda rRegItemTypePlusIOH+IO1Port 
   and #$7f  ;bit 7 indicates an assigned IOHandler, don't care yet
   jsr Print4CharTable
; Assigned IO Handler? '+' if so
   lda rRegItemTypePlusIOH+IO1Port 
   and #$80  ;bit 7 indicates an assigned IOHandler, now we care!   bne +
   beq MenuLineDone
   lda #AssignedIOHColor
   jsr SendChar
   lda #'+'
   jsr SendChar
   
;line is done printing, check for next...
MenuLineDone
   inc rwRegSelItemOnPage+IO1Port
   ldx rwRegSelItemOnPage+IO1Port
   cpx rRegNumItemsOnPage+IO1Port
   bne nextLine
   ;all items listed
   rts

GreyOutUp:
   lda #GreyOutColor
   sta UpIndicColorLoc
   sta UpIndicColorLoc+1
   rts
   
GreyOutDn:
   lda #GreyOutColor
   sta DnIndicColorLoc
   sta DnIndicColorLoc+1
   rts
   
;Execute/select an item from the list
; Dir, ROM, copy PRG to RAM and run, etc
;Pre-Load rwRegSelItemOnPage+IO1Port with Item # to execute/select
SelectMenuItem:
   lda rRegItemTypePlusIOH+IO1Port ;Read Item type selected
   and #$7f  ;bit 7 indicates an assigned IOHandler, we don't care here
   cmp #rtFileHex  ;check for .hex file selected and prep for FW update
   beq FWUpdate  

   lda #rCtlStartSelItemWAIT
   sta wRegControl+IO1Port
   jsr WaitForTR ;if it's a ROM/crt image, it won't return from this

   lda rRegStrAvailable+IO1Port 
   bne XferCopyRun       ; if it's a program (x-fer ready), x-fer it and launch
   jsr ListMenuItems ; otherwise reprint menu and return
   rts

XferCopyRun:
   ;copy PRGLoadStart code to tape buffer area in case this area gets overwritten
   ;192 byte limit, watch size of PRGLoadStart block!  check below

   ;no going back now...
   jsr SIDMusicOff    
   lda #<MsgLoading
   ldy #>MsgLoading
   jsr PrintString
   lda #rsstItemName
   jsr PrintSerialString

   lda #>PRGLoadStart
   ldy #<PRGLoadStart   
   sta PtrAddrHi
   sty PtrAddrLo 
   lda #>PRGLoadStartReloc
   ldy #<PRGLoadStartReloc   
   sta Ptr2AddrHi
   sty Ptr2AddrLo 
   ldy #$00
-  lda (PtrAddrLo), y 
   sta (Ptr2AddrLo),y
   iny
   cpy #PRGLoadEnd-PRGLoadStart  ;check length in build report here
   bne -   
   jmp PRGLoadStartReloc     

FWUpdate:
   jsr PrintBanner 
   lda #<MsgFWUpdate  ;Page Title
   ldy #>MsgFWUpdate
   jsr PrintString 
   lda #rsstItemName  ;File name
   jsr PrintSerialString
   lda #<MsgFWVerify  ;Verification prompt
   ldy #>MsgFWVerify
   jsr PrintString 

-  jsr GetIn    ; wait for user confirmation
   beq -
   cmp #'n'  
   beq fwAbort
   cmp #'y'  
   bne -

   lda #<MsgFWInProgress  ;In Progress Warning
   ldy #>MsgFWInProgress
   jsr PrintString 
   lda #rFWUSCContinue   ;TR FW in control, init for loop below
   sta rwRegFWUpdStatCont+IO1Port
   lda #rCtlStartSelItemWAIT ;kick off the update routine
   sta wRegControl+IO1Port
   ldy TODSecBCD ;reset dot second counter
   
FWWaitLoop ;waiting loop that shows 1 dot/sec and waits for rwRegFWUpdStatCont
   cpy TODSecBCD  ;no latch/unlatch needed for only reading seconds
   beq +
   ldy TODSecBCD  ;print 1 dot/sec while waiting
   lda #'.'
   jsr SendChar
+  lda rwRegFWUpdStatCont+IO1Port
   cmp #rFWUSCC64Message
   beq ++
   cmp #rFWUSCC64Finish
   bne FWWaitLoop
++ ldx#5 ;require 5 consecutive reads of rFWUSCC64* to continue
-  cmp rwRegFWUpdStatCont+IO1Port
   bne FWWaitLoop
   dex
   bne -
   ; the ball is in the C64 court, finish or display message and cont
   cmp #rFWUSCC64Finish
   beq fwFinish
   ; display message:
   lda #rsstSerialStringBuf ;FW upd populated message
   jsr PrintSerialString
   lda #rFWUSCContinue   ;tell fw we're done reading msg, continue
   sta rwRegFWUpdStatCont+IO1Port
   jmp FWWaitLoop

fwFinish
   jsr WaitForTRNoPr  ;be sure original update routine has finished
   lda #<MsgAnyKey  ;wait for any key to continue 
   ldy #>MsgAnyKey
   jsr PrintString 
-  jsr GetIn    
   beq -
fwAbort   
   jsr ListMenuItems
   rts


WaitForTR:  ;wait for ready status, uses acc, X and Y
   ldx #1 ;row   Show "Waiting:" over time disp
   ldy #29  ;col
   clc
   jsr SetCursor
   lda #<MsgWaiting
   ldy #>MsgWaiting
   jsr PrintString
WaitForTRNoPr:  ;wait without moving cursor/printing
!ifndef Debug {
-- ldx#5 ;require 5 consecutive reads of ready to continue
   inc ScreenCharMemStart+40*2-2 ;spinner @ end of 'Time' print loc.
-  lda rRegStatus+IO1Port
   cmp #rsReady
   bne --
   dex
   bne -
}
   rts

SynchEthernetTime:
   lda #rCtlGetTimeWAIT
   sta wRegControl+IO1Port
   jsr WaitForTR 
   lda rRegLastHourBCD+IO1Port
   sta TODHoursBCD  ;stop TOD regs incrementing
   lda rRegLastMinBCD+IO1Port
   sta TODMinBCD
   lda rRegLastSecBCD+IO1Port
   sta TODSecBCD
   lda #9
   sta TODTenthSecBCD ;have to write 10ths to release latch, start incrementing
   rts
   
   
   !src "source\SettingsMenu.asm"
   !src "source\PRGLoadStartReloc.s"
   !src "source\SIDRelated.s"
   !src "source\StringFunctions.s"
   !src "source\StringsMsgs.s"

EndOfAllMenuCode = *
   !byte 0
