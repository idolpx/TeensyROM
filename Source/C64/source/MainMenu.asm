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
   BorderColor      = pokePurple
   BackgndColor     = pokeBlack
   TimeColor        = ChrOrange
   MenuMiscColor    = ChrGreen
   ROMNumColor      = ChrDrkGrey
   OptionColor      = ChrYellow
   SourcesColor     = ChrLtBlue
   TypeColor        = ChrBlue
   NameColor        = ChrLtGreen
   MaxMenuDispItems = 16
   M2SDataColumn    = 14


   ;Zero page RAM Registers:
   PtrAddrLo   = $fb
   PtrAddrHi   = $fc
   Ptr2AddrLo  = $fd
   Ptr2AddrHi  = $fe
   ;other RAM Registers/code space
   ;$0334-033b is "free space"
   RegMenuPageStart = $0334 ;first logical item # on current menu page
   SIDVoicCont      = $0335 ;midi2sid polyphonic voice/envelope controls
   SIDAttDec        = $0336
   SIDSusRel        = $0337
   SIDDutyHi        = $0338
   MusicPlaying     = $0339 ;is the music playing?
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

+  lda #rCtlVanish ;Deassert Game & ExROM
   sta wRegControl+IO1Port

   lda #$00
   jsr SIDCodeRAM ;Initialize music
   
   jsr ListMenuItemsInit

   ;check default registers for music & time settings
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudMusicMask
   sta MusicPlaying
   beq +
   jsr SIDMusicOn

+  lda rwRegPwrUpDefaults+IO1Port
   and #rpudNetTimeMask
   beq WaitForKey
   jsr SynchEthernetTime
   

WaitForKey:     
   jsr DisplayTime
   jsr GetIn    
   beq WaitForKey

   cmp #'a'  
   bmi +   ;skip if below 'a'
   cmp #'a'+ MaxMenuDispItems + 1  
   bpl +   ;skip if above MaxMenuDispItems
   ;convert to ROM number
   sec       ;set to subtract without carry
   sbc #'a'  ;now 0-?
   clc
   adc RegMenuPageStart   
   ;ROMSelected, ROM num in acc
   cmp rRegNumItems+IO1Port 
   bpl WaitForKey   ;skip if above num of ROMs
   sta rwRegSelItem+IO1Port ;select Item from list
   jsr SelectMenuItem
   jmp WaitForKey

+  cmp #ChrCSRSDn  ;Next Page
   bne +
   lda RegMenuPageStart
   clc
   adc #MaxMenuDispItems
   cmp rRegNumItems+IO1Port
   bpl WaitForKey  ;already on last page
   sta RegMenuPageStart
   jsr ListMenuItems
   jmp WaitForKey

+  cmp #ChrCSRSUp  ;Prev Page
   bne +
   lda RegMenuPageStart
   ;cmp #0     
   beq WaitForKey  ;already on first page
   sec
   sbc #MaxMenuDispItems
   sta RegMenuPageStart
   jsr ListMenuItems
   jmp WaitForKey  

+  cmp #ChrF1  ;Teensy mem Menu
   bne +
   lda #rmtTeensy
   jsr ListMenuItemsChangeInit
   jmp WaitForKey  

+  cmp #ChrF2  ;Exit to BASIC
   bne +
   lda #rCtlVanishReset ;reset to BASIC
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


;                           list out rom number, type, & names
ListMenuItemsChangeInit:  ;Prep: Load acc with menu to change to
   sta rWRegCurrMenuWAIT+IO1Port  ;must wait on a write (load dir)
   jsr WaitForTR
ListMenuItemsInit:
   lda #0       ;initialize to first Item
   sta RegMenuPageStart
ListMenuItems:  ;Prep: load RegMenuPageStart with first ROM on menu page
   lda #<MsgBanner
   ldy #>MsgBanner
   jsr PrintString 
   lda #<MsgFrom
   ldy #>MsgFrom
   jsr PrintString 
   ;print menu source:
   lda rWRegCurrMenuWAIT+IO1Port ;don't have to wait on a read
   cmp #rmtSD
   bne +
   lda #<MsgMenuSD
   ldy #>MsgMenuSD
   jmp cont1

+  cmp #rmtTeensy
   bne +
   lda #<MsgMenuTeensy
   ldy #>MsgMenuTeensy
   jmp cont1
   
+  cmp #rmtUSBDrive
   bne +
   lda #<MsgMenuUSBDrive
   ldy #>MsgMenuUSBDrive
   jmp cont1
   
+  ;cmp #rmtUSBHost
   ;bne +
   lda #<MsgMenuUSBHost
   ldy #>MsgMenuUSBHost
   ;jmp cont1
   
cont1   
   jsr PrintString
   lda rRegNumItems+IO1Port
   bne +
   lda #<MsgNoItems
   ldy #>MsgNoItems
   jsr PrintString
   jmp finishMenu
+  lda RegMenuPageStart
   sta rwRegSelItem+IO1Port
   lda #'A' ;initialize to start of page
nextLine
   pha ;remember menu letter
   lda #ChrReturn
   jsr SendChar
   
;print option letter
   lda #OptionColor
   jsr SendChar
   lda #ChrSpace
   jsr SendChar
   lda #ChrRvsOn
   jsr SendChar
   pla
   pha
   jsr SendChar
   lda #ChrRvsOff
   jsr SendChar
   lda #'-'
   jsr SendChar
; print name
   lda #NameColor
   jsr SendChar
   lda #<rRegItemNameStart+IO1Port
   ldy #>rRegItemNameStart+IO1Port
   jsr PrintString
;align to col
   sec
   jsr SetCursor ;read current to load y (row)
   ldy #MaxItemNameLength + 3  ;col
   clc
   jsr SetCursor
; print type
   lda #TypeColor
   jsr SendChar
   ldx #<TblItemType
   ldy #>TblItemType
   lda rRegItemType+IO1Port 
   jsr Print4CharTable
;print ROM #
   lda #ROMNumColor
   jsr SendChar
   lda rwRegSelItem+IO1Port
   jsr PrintHexByte
   
;line is done printing, check for next...
   pla ;menu select letter
   inc rwRegSelItem+IO1Port
   ldx rwRegSelItem+IO1Port
   cpx rRegNumItems+IO1Port
   beq finishMenu
   clc
   adc #01
   cmp #'A' + MaxMenuDispItems
   bne nextLine  
finishMenu
   ldx #20 ;row
   ldy #0  ;col
   clc
   jsr SetCursor
   lda #<MsgSelect
   ldy #>MsgSelect
   jsr PrintString
   rts

;Execute/select an item from the list
; Dir, ROM, copy PRG to RAM and run, etc
;Pre-Load rwRegSelItem+IO1Port with Item # to execute/select
SelectMenuItem:
   lda rRegItemType+IO1Port ;grab this now it will change if new directory is loaded
   pha
   lda #rCtlStartSelItemWAIT
   sta wRegControl+IO1Port
   jsr WaitForTR ;if it's a ROM/crt image, it won't return from this
   pla
   cmp #rtPrg
   beq XferCopyRun  ;if it's a program, x-fer and launch, otherwise reprint menu and return
   jsr ListMenuItemsInit
   rts
   
XferCopyRun:
   ;copy PRGLoadStart code to tape buffer area in case this (Cxxx) area gets overwritten
   ;192 byte limit, watch size of PRGLoadStart block!  check below
   lda rRegStrAvailable+IO1Port
   bne +
   lda #<MsgErrNoData;no data to read!
   ldy #>MsgErrNoData
   jmp ErrOut
   ;no going back now...
+  jsr SIDMusicOff    
   lda #<MsgLoading
   ldy #>MsgLoading
   jsr PrintString
   lda #<rRegItemNameStart+IO1Port
   ldy #>rRegItemNameStart+IO1Port
   jsr PrintString

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
     
WaitForTR:  ;wait for ready status, uses acc, X and Y
   ldx #1 ;row   Show "Waiting:" over time disp
   ldy #29  ;col
   clc
   jsr SetCursor
   lda #<MsgWaiting
   ldy #>MsgWaiting
   jsr PrintString
!ifndef Debug {
-- ldx#5 ;require 5 consecutive reads of ready to continue
   inc ScreenMemStart+40*2-2 ;spinner @ end of 'Time' print loc.
-  lda rRegStatus+IO1Port
   cmp #rsReady
   bne --
   dex
   bne -
}
   rts

ErrOut:   
   ;Error msg pointer stored in acc/y
   pha
   tya
   pha
   ldx #19 ;row
   ldy #0  ;col
   clc
   jsr SetCursor
   lda #<MsgError
   ldy #>MsgError
   jsr PrintString   
   pla
   tay
   pla
   jsr PrintString
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
   
SettingsMenu:
   lda #<MsgBanner
   ldy #>MsgBanner
   jsr PrintString 
   lda #<MsgSettingsMenu
   ldy #>MsgSettingsMenu
   jsr PrintString 
   lda #<MsgCreditsInfo
   ldy #>MsgCreditsInfo
   jsr PrintString 

ShowSettings:
   lda #NameColor
   jsr SendChar

   ldx #5 ;row Synch Time
   ldy #23 ;col
   clc
   jsr SetCursor
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudNetTimeMask  
   jsr PrintOnOff

   ldx #6 ;row Music State
   ldy #23 ;col
   clc
   jsr SetCursor
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudMusicMask  
   jsr PrintOnOff
   
   ldx #7 ;row Time Zone
   ldy #26 ;col
   clc
   jsr SetCursor
   ldx #'+'
   ldy rwRegTimezone+IO1Port
   tya
   and #$80
   beq +
   ;neg number
   tya
   eor#$ff  ;1's comp
   tay
   iny ;2's comp
   ldx #'-' 
+  txa
   jsr SendChar
   tya
   ;conv to bcd
   cmp #10
   bmi +     ;skip if below 10
   sec       ;set to subtract without carry
   sbc #10   ;subtract 10
   ora #$10
+  jsr PrintHexByte


WaitForSettingsKey:     
   jsr DisplayTime   
   jsr GetIn
   beq WaitForSettingsKey

   cmp #ChrF1  ;Power-up Synch Time toggle
   bne +
   lda rwRegPwrUpDefaults+IO1Port
   eor #rpudNetTimeMask  
   sta rwRegPwrUpDefaults+IO1Port
   jmp ShowSettings  

+  cmp #ChrF3  ;Power-up Music State toggle
   bne +
   lda rwRegPwrUpDefaults+IO1Port
   eor #rpudMusicMask  
   sta rwRegPwrUpDefaults+IO1Port
   jmp ShowSettings  

+  cmp #ChrF5  ;Power-up Time Zone increment
   bne +
   ldx rwRegTimezone+IO1Port
   inx
   cpx #15
   bne ++
   ldx #-12
++ stx rwRegTimezone+IO1Port
   jmp ShowSettings  

+  cmp #ChrF2  ;Synch Time now
   bne +
   jsr SynchEthernetTime
   jmp WaitForSettingsKey  

+  cmp #ChrF4  ;Toggle Music now
   bne +
   jsr ToggleSIDMusic
   jmp WaitForSettingsKey  

+  cmp #ChrF7  ;Exit
   bne +
   rts

+  jmp WaitForSettingsKey  


   !src "source\PRGLoadStartReloc.s"
   !src "source\SIDRelated.s"
   !src "source\StringsMsgs.s"

EndOfAllMenuCode = *
   !byte 0