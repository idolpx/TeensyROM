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
   !src "source\CommonDefs.i" ;Common between crt loader and main code in RAM
   !src "source\Menu_Regs.i"  ;IO space registers matching Teensy code

   ;other RAM Registers
   ;$0334-033b is "free space"


;******************************* Main Code Start ************************************   

* = MainCodeRAMStart
Start:

;screen setup:     
   jsr TextScreenMemColor
  
!ifndef Debug {
;check for HW:
   lda rRegPresence1+IO1Port
   cmp #$55
   bne NoHW
   lda rRegPresence2+IO1Port
   cmp #$AA
   beq +
NoHW
   lda #<MsgNoHW
   ldy #>MsgNoHW
   jsr PrintString  
   ;jmp (BasicWarmStartVect)
-  jmp -
}

+  lda #rCtlVanishROM ;Deassert Game & ExROM
   sta wRegControl+IO1Port

   ;Get video standard and TOD frequency
   ; https://codebase64.org/doku.php?id=base:efficient_tod_initialisation
   ; Detecting TOD frequency by Silver Dream ! / Thorgal / W.F.M.H.
   sei             ; accounting for NMIs is not needed when
   lda #$00        ; used as part of application initialisation
   sta $dd08       ; TO2TEN start TOD - in case it wasn't running
-  cmp $dd08       ; TO2TEN wait until tenths
   beq -           ; register changes its value
   lda #$ff        ; count from $ffff (65535) down
   sta $dd04       ; TI2ALO both timer A register
   sta $dd05       ; TI2AHI set to $ff
   lda #%00010001  ; bit seven = 0 - 60Hz TOD mode
   sta $dd0e       ; CI2CRA start the timer
   lda $dd08       ; TO2TEN
-  cmp $dd08       ; poll TO2TEN for change
   beq -
   lda $dd05       ; TI2AHI expect (approximate) $7f4a $70a6 $3251 $20c0
   cli
   ;$7f4a for 60Hz TOD clock and 985248.444(PAL) CPU/CIA clock    10
   ;$70a6 for 60Hz TOD clock and 1022727.14(NTSC) CPU/CIA clock   11
   ;$3251 for 50Hz TOD clock and 985248.444(PAL) CPU/CIA clock    00
   ;$20c0 for 50Hz TOD clock and 1022727.14(NTSC) CPU/CIA clock   01
   ;convert from MSB timing to: bit 0: 1=NTSC, 0=PAL;    bit 1: 1=60Hz, 0=50Hz
   cmp #$29
   bcs +  ;(>29)
   ldx #%00000001  ;50/NTSC
   jmp ++
+  cmp #$51
   bcs +  ;(>51)
   ldx #%00000000  ;50/PAL
   jmp ++
+  cmp #$78
   bcs +  ;(>78)
   ldx #%00000011  ;60/NTSC
   jmp ++
+  ldx #%00000010  ;60/PAL
++ stx wRegVid_TOD_Clks+IO1Port   

   ;store this code page range for SID conflict detection
   lda #>MainCodeRAMStart   ;read hi byte of Start address
   sta rwRegCodeStartPage+IO1Port
   lda #>MainCodeRAMEnd   ;read hi byte of End address
   sta rwRegCodeLastPage+IO1Port
   
   ;check for remote launch on reset
   lda rwRegIRQ_CMD+IO1Port
   cmp #ricmdLaunch
   bne +
   ;inc BorderColorReg
   lda #ricmdNone
   sta rwRegIRQ_CMD+IO1Port
   jsr RunSelected  ;start TR selected app...
   ;prg/crt won't return from here, likely SID or error
   lda #rmtTeensy ; force back to TR menu
   jsr MenuChangeInit   
   jmp ++
   
   ;load SID to TR RAM
+  lda #rCtlLoadSIDWAIT ; sends SID Parse messages
   sta wRegControl+IO1Port
   jsr WaitForTRDots

   jsr SIDLoadInit  ;Load SID to C64, start the IRQ wedge, initial default is SID playback disable. 
 
   ;check default register for music playback
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudSIDPauseMask
   sta smcSIDPauseStop+1  ;set default SID playback

++ jsr ListMenuItems ;stay in current TR defined device/dir/cursor pos
   ;check default register for time update
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudNetTimeMask
   beq +
   jsr SynchEthernetTime
   jmp HighlightCurrent
   
+  lda #0  ;set clock to midnight if not synching
   sta TODHoursBCD  ;stop TOD regs incrementing
   sta TODMinBCD
   sta TODSecBCD
   sta TODTenthSecBCD ;have to write 10ths to release latch, start incrementing

   
   
HighlightCurrent:   
   lda rwRegCursorItemOnPg+IO1Port 
   jsr InverseRow
   
WaitForJSorKey:     
   jsr DisplayTime
   ;Check joystick first:
   lda GamePort2  
   ;and GamePort1  keyboard input scan interferes with this port
   lsr
   bcs +
   jsr CursorUp    ;js Up
   jmp JSDelay
   
+  lsr
   bcs +
   jsr CursorDown  ;js Down
   jmp JSDelay
   
+  lsr
   bcs +
   jsr PrevPage    ;js Left
   jmp JSDelay
   
+  lsr
   bcs +
   jsr NextPage    ;js Right
   jmp JSDelay
   
+  lsr
   bcs ReadKeyboard
   jsr SelectItem  ;js Fire
   ;jmp JSDelay

JSDelay:   
   lda rwRegCursorItemOnPg+IO1Port ;HighlightCurrent
   jsr InverseRow
   ;pause after action:
   lda rwRegPwrUpDefaults+IO1Port
   and #rpudJoySpeedMask  ;upper 4 bits = speed 0-15 (00-f0)
   eor #rpudJoySpeedMask  ;make 15-0 (f0-00 step $10)
   lsr ;conv to $78-$00 step $08
   tay
   iny ;can't be 0, now $79-$01 step $08
   ;default of 9 ends up at $31 in y
   ;prev testing:ldy #$18   ;$10 is pretty quick, but controllable(?);  $80 is fairly slow
-- ldx #$ff
-  dex
   bne -
   dey
   bne --
   ;lda #0
   ;sta 198 ;clear keyboard buffer (only needed for port 1)
   ;jmp WaitForJSorKey

ReadKeyboard:
   jsr CheckForIRQGetIn
   beq WaitForJSorKey

+  cmp #ChrReturn
   bne +
   jsr SelectItem
   jmp HighlightCurrent ;highlight the same one (or dir change sets to 0)
   
+  cmp #ChrCRSRDn  ;Move cursor down
   bne +
   jsr CursorDown
   jmp HighlightCurrent
   
+  cmp #ChrCRSRUp  ;Move cursor up
   bne +
   jsr CursorUp
   jmp HighlightCurrent

+  cmp #ChrCRSRRight  ;Next Page
   bne +
   jsr NextPage
   jmp HighlightCurrent

+  cmp #ChrCRSRLeft  ;Prev Page
   bne +
   jsr PrevPage
   jmp HighlightCurrent  

+  cmp #ChrUpArrow ;Up directory
   bne +  
   lda #rCtlUpDirectoryWAIT
   sta wRegControl+IO1Port
   jsr WaitForTRWaitMsg
   jsr ListMenuItems ; reprint menu
   jmp HighlightCurrent 

+  cmp #ChrHome ;top of directory
   bne +  
   lda #1  ;first page
   sta rwRegPageNumber+IO1Port
   lda #0  ;set to first item
   sta rwRegCursorItemOnPg+IO1Port 
   jsr ListMenuItems ; reprint menu
   jmp HighlightCurrent 
   
+  cmp #'a'  
   bmi +   ;skip if below 'a'
   cmp #'z'+1
   bpl +   ;skip if above 'z'
   sta wRegSearchLetterWAIT+IO1Port
   jsr WaitForTRWaitMsg
   jsr ListMenuItems ; reprint menu
   jmp HighlightCurrent 

+  cmp #ChrF1  ;Teensy mem Menu
   bne +
   lda #rmtTeensy
   jsr ListMenuItemsChangeInit
   jmp HighlightCurrent  

+  cmp #ChrF2  ;Exit to BASIC
   bne +
   lda #rCtlBasicReset ;reset to BASIC
   sta wRegControl+IO1Port
-  jmp -  ;should be resetting to BASIC

+  cmp #ChrF3  ;SD Card Menu
   bne +
   lda #rmtSD
   jsr ListMenuItemsChangeInit
   jmp HighlightCurrent  

+  cmp #ChrF4  ;toggle music
   bne +
   jsr ToggleSIDMusic
   jmp WaitForJSorKey  

+  cmp #ChrF5  ;USB Drive Menu
   bne +
   lda #rmtUSBDrive
   jsr ListMenuItemsChangeInit
   jmp HighlightCurrent
   
+  cmp #ChrF6  ;Show SID info
   bne +
   jsr ShowSIDInfoPage
   jsr ListMenuItems
   jmp HighlightCurrent

+  cmp #ChrF7  ;Help Menu
   bne +
   jsr HelpMenu
   jsr ListMenuItems
   jmp HighlightCurrent

+  cmp #ChrF8  ;Settings Menu
   bne +
   jsr SettingsMenu
   jsr ListMenuItems
   jmp HighlightCurrent  


+  jmp WaitForJSorKey

   
; ******************************* Subroutines ******************************* 

___Subroutines________________________________:


;                           list out item number, type, & names
ListMenuItemsChangeInit:  ;changing menu source.  Prep: Load acc with menu to change to
   sta rWRegCurrMenuWAIT+IO1Port  ;must wait on a write (load dir)
   jsr WaitForTRWaitMsg
ListMenuItems:
   jsr PrintBanner 
   
   ldx #23 ;row
   ldy #0  ;col
   clc
   jsr SetCursor
   lda #<MsgMainOptions1
   ldy #>MsgMainOptions1
   jsr PrintString
   ;page x/y
   lda rwRegPageNumber+IO1Port
   jsr PrintIntByte
   lda #'/'
   jsr SendChar   
   lda rRegNumPages+IO1Port
   jsr PrintIntByte
   
   lda #<MsgMainOptions2
   ldy #>MsgMainOptions2
   jsr PrintString
   
   ldx #1  ;row
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
   
   ;display parent dir/path
   lda #ChrReturn
   jsr SendChar
   lda #rsstShortDirPath 
   jsr PrintSerialString

   ;There should always be at least one item, even if it's "Empty"
   lda #0       ;initialize to first Item on Page
   sta rwRegSelItemOnPage+IO1Port
nextLine
   lda #ChrReturn
   jsr SendChar 
   lda #ChrCRSRRight
   jsr SendChar
; print name
   lda #NameColor
   jsr SendChar
   lda #rsstItemName
   jsr PrintSerialString
;align to col
   sec
   jsr SetCursor ;read current to load x (row)
   ldy #MaxItemDispLength + 1  ;set y = col
   clc
   jsr SetCursor
; Assigned IO Handler? '+' if so
   lda rRegItemTypePlusIOH+IO1Port 
   and #$80  ;bit 7 indicates an assigned IOHandler, now we care!
   beq +
   lda #<MsgHasHandler
   ldy #>MsgHasHandler
   jsr PrintString
; print type, incl color
+  ldx #<TblItemType
   ldy #>TblItemType
   lda rRegItemTypePlusIOH+IO1Port 
   and #$7f  ;bit 7 indicates an assigned IOHandler, don't care
   jsr Print4CharTable
   
;line is done printing, check for next...
MenuLineDone
   inc rwRegSelItemOnPage+IO1Port
   ldx rwRegSelItemOnPage+IO1Port
   cpx rRegNumItemsOnPage+IO1Port
   bne nextLine
   ;all items listed
   rts

CheckForIRQGetIn:

smcIRQFlagged
   lda #ricmdNone  ;default to no IRQ detected (0)
   bne +
-  jsr GetIn ;No IRQ, read key and return it in the acc 
   rts

+  lda rwRegIRQ_CMD+IO1Port  ;Read command from TR
   sta wRegIRQ_ACK+IO1Port  ;echo command as ack 2 to TR
   ldx #ricmdNone  ;clear local flag
   stx smcIRQFlagged+1
   
   ;cmp ricmdNone   ;just check acceptable and do nothing otherwise
   cmp #ricmdSIDPause
   bne +
   jsr ToggleSIDMusic
   jmp -
   
+  cmp #ricmdLaunch
   bne -    ;no command or false irq

   jsr TextScreenMemColor  ;make sure we're in text mode:

   ;launch app set up by TR
   jsr RunSelected  ;start TR selected app...
   
   ;menu was custom built for remote start, not display
   ;  Force back to main TR Mem menu, display to be done after return (via F1)
   lda #rmtTeensy
   jsr MenuChangeInit

   lda #ChrF1 ; simulate F1 keypress
   rts
   
   
SelectItem:
;Execute/select an item from the list
   lda rwRegCursorItemOnPg+IO1Port 
   sta rwRegSelItemOnPage+IO1Port ;select Item from page
   jsr InverseRow ;unhighlight the current

RunSelected:   
   lda rRegItemTypePlusIOH+IO1Port ;Read Item type selected
   and #$7f  ;bit 7 indicates an assigned IOHandler, we don't care here
   cmp #rtDirectory  ;check for dir selected
   bne + 
   ;DirUpdate:
   lda #rCtlStartSelItemWAIT
   sta wRegControl+IO1Port
   jsr WaitForTRWaitMsg
   lda #0
   sta rwRegCursorItemOnPg+IO1Port  ;set cursor to the first item in dir
   jmp ListAndDone

+  cmp #rtNone ;do nothing for 'none' type
   bne + 
   rts
   
   ;any type except None and sub-dir, clear screen and stop interrupts
+  pha ;store the type
   jsr IRQDisable  ;turn off interrupt (also stops SID playback, if on)
   jsr PrintBanner ;clear screen for messaging for remaining types:
   lda #NameColor
   jsr SendChar
   
   pla ;restore the type
   cmp #rtFileHex  ;check for .hex file selected
   bne +
   
   ;FWUpdate  
   lda #ChrReturn
   jsr SendChar
   lda #rsstItemName
   jsr PrintSerialString
   lda #<MsgFWVerify  ;Verification prompt
   ldy #>MsgFWVerify
   jsr PrintString 

-  jsr GetIn    ; wait for user confirmation
   beq -
   cmp #'n'  
   bne ++
   jsr IRQEnable
   jmp ListAndDone
++ cmp #'y'  
   bne -

   lda #<MsgFWInProgress  ;In Progress Warning
   ldy #>MsgFWInProgress
   jsr PrintString  
   jsr StartSelItem_WaitForTRDots    ;kick off the update routine

   ;if we get to this point without rebooting, there's been an error...
   lda #<MsgFWUpdateFailed 
   ldy #>MsgFWUpdateFailed
   jsr PrintString 
   jsr AnyKeyErrMsgWait  ;turns IRQ back on
   jmp ListAndDone
      
      
+  cmp #rtFileSID  ;check for .sid file selected
   bne +
   jsr StartSelItem_WaitForTRDots
   lda #0    ;rpudSIDPauseMask ;default to enable playback (clear all bits), may be turned off if error
   sta smcSIDPauseStop+1
   jsr SIDLoadInit ;check success, return or transfer to RAM and start playing.  Turns IRQ on regardless
   lda smcSIDPauseStop+1
   bne ListAndDone  ;skip sid info page on error
   jsr ShowSIDInfoPage
   jmp ListAndDone  
    
+  cmp #rtFileKla  ;check for Koala file selected
   bne +
-- jsr LoadViewKoala
   jmp ListAndDone  

+  cmp #rtFileArt  ;check for Hi-res art file selected
   beq --

   
   ;not a dir, "none", hex file, Koala, or SID, try to start/execute
+  jsr StartSelItem_WaitForTRDots ;if it's a ROM/crt image, it won't return from this unless error

   lda rRegStrAvailable+IO1Port 
   bne XferCopyRun   ;if it's a PRG (x-fer ready), x-fer it and launch. Won't return!!!
   
   ;If at this point, couldn't load item, and wasn't a dir, none, .hex, .prg or .p00
   jsr AnyKeyErrMsgWait  ;turns IRQ back on
   ;continue to...
   
ListAndDone
   jsr ListMenuItems ; reprint menu
   rts


XferCopyRun:
   ;copy PRGLoadStart code to tape buffer area in case this area gets overwritten
   ;192 byte limit, watch size of PRGLoadStart block!  check below
   ;no going back now...
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
   cpy #PRGLoadEnd-PRGLoadStart  ;check length in build report here against PRGLoadStartReloc available
   bne -   
   jmp PRGLoadStartReloc     
   ;rts ;SelectItem never returns

AnyKeyErrMsgWait:
   lda #rpudSIDPauseMask    ;Pause SID playback on error
   sta smcSIDPauseStop+1
   jsr IRQEnable  ;turn on IRQ
   lda #<MsgAnyKey  ;wait for any key to continue 
   ldy #>MsgAnyKey
   jsr PrintString 
-  jsr CheckForIRQGetIn    
   beq -
   rts

StartSelItem_WaitForTRDots:
   lda #rCtlStartSelItemWAIT ;kick off the selection
   sta wRegControl+IO1Port   
;WaitForTR* uses acc, X and Y
WaitForTRDots:  ;prints a dot per second while waiting, doesn't move cursor
   ldy TODSecBCD ;reset dot second counter
   jmp WaitForTRMain
WaitForTRWaitMsg:  ;Print Waiting message in upper right and waits
   ldx #1 ;row   Show "Waiting:" over time disp
   ldy #29  ;col
   clc
   jsr SetCursor
   lda #<MsgWaiting
   ldy #>MsgWaiting
   jsr PrintString
   ldy #$ff ;don't print dots
WaitForTRMain   ;Main wait loop
   ;!ifndef Debug {   ;} 
   inc C64ScreenRAM+40*2-2 ;spinner @ top-1, right-1
   cpy #$ff
   beq +    ;skip dot printing if wait message selected
   cpy TODSecBCD  ;no latch/unlatch needed for only reading seconds
   beq +
   ldy TODSecBCD  ;print 1 dot/sec while waiting
   lda #'.'
   jsr SendChar
+  lda rwRegStatus+IO1Port
   cmp #rsC64Message
   beq ++
   cmp #rsReady
   bne WaitForTRMain
++ ldx#5 ;require 1+5 consecutive reads of same rsC64Message/rsReady to continue
-  cmp rwRegStatus+IO1Port
   bne WaitForTRMain
   dex
   bne -
   ; the ball is in the C64 court, either done or display message and cont waiting
   cmp #rsReady
   beq +
   ; display message:
   lda #rsstSerialStringBuf ;pre-populated message
   jsr PrintSerialString
   lda #rsContinue    ;tell fw we're done reading msg, continue
   sta rwRegStatus+IO1Port
   jmp WaitForTRMain
+  rts

SynchEthernetTime:
   lda #rCtlGetTimeWAIT
   sta wRegControl+IO1Port
   jsr WaitForTRWaitMsg 
   lda rRegLastHourBCD+IO1Port
   sta TODHoursBCD  ;stop TOD regs incrementing
   lda rRegLastMinBCD+IO1Port
   sta TODMinBCD
   lda rRegLastSecBCD+IO1Port
   sta TODSecBCD
   lda #9
   sta TODTenthSecBCD ;have to write 10ths to release latch, start incrementing
   rts

CursorUp:
   lda rwRegCursorItemOnPg+IO1Port  
   tax
   jsr InverseRow ;unhighlight the current
   cpx #0
   bne ++
   jsr PageUp  ;at top of page, page up
   ldx rRegNumItemsOnPage+IO1Port 
++ dex   
   stx rwRegCursorItemOnPg+IO1Port 
   rts

CursorDown:
   ldx rwRegCursorItemOnPg+IO1Port 
   txa
   jsr InverseRow ;unhighlight the current
   inx   
   cpx rRegNumItemsOnPage+IO1Port ;last item?
   beq ++ 
   stx rwRegCursorItemOnPg+IO1Port 
   rts
++ jsr PageDown   ;at bottom of page, page down
   rts

PrevPage:
   lda rwRegCursorItemOnPg+IO1Port 
   jsr InverseRow ;unhighlight the current (in case 1 page)
   jsr PageUp
   lda #0
   sta rwRegCursorItemOnPg+IO1Port ;set cursor to the first item in dir
   rts
   
PageUp:
   ldx rwRegPageNumber+IO1Port
   cpx #1  ;on first page?
   bne +
   ldx rRegNumPages+IO1Port ;roll over to last
   cpx #1
   beq ++ ;do nothing if there's only 1 page
   inx ;avoids a jump to skip next
+  dex   
   stx rwRegPageNumber+IO1Port
   jsr ListMenuItems   
++ rts

NextPage:
   lda rwRegCursorItemOnPg+IO1Port 
   jsr InverseRow ;unhighlight the current (in case 1 page)
   jsr PageDown
   rts

PageDown:
   ldx rwRegPageNumber+IO1Port
   cpx rRegNumPages+IO1Port ;on last page?
   bne +
   ldx rRegNumPages+IO1Port 
   cpx #1
   beq ++ ;do nothing if there's only 1 page
   ldx #0 ;on last page, roll over to first
+  inx
   stx rwRegPageNumber+IO1Port
   jsr ListMenuItems
++ lda #0  ;set to first item
   sta rwRegCursorItemOnPg+IO1Port 
   rts
   
InverseRow:
   ;Acc contains item number to toggle reverse
   ;Uses A and Y   
   ;get mem loc from table:
   asl ;double it to point to word
   tay
   lda TblRowToMemLoc+1,y
   sta smcInverseRowSrc+2
   sta smcInverseRowDest+2
   lda TblRowToMemLoc,y
   sta smcInverseRowSrc+1 
   sta smcInverseRowDest+1 
   ldy #40
smcInverseRowSrc
-  lda $fffe, y 
   eor #$80 ; toggle reverse 
smcInverseRowDest
   sta $fffe,y
   dey
   bne -
   rts

HelpMenu:
   jsr PrintBanner
   lda #<MsgHelpMenu
   ldy #>MsgHelpMenu
   jsr PrintString 

   lda #<MsgSettingsMenu2SpaceRet
   ldy #>MsgSettingsMenu2SpaceRet
   jsr PrintString 

WaitHelpMenuKey:
   jsr DisplayTime   
   jsr CheckForIRQGetIn    
   beq WaitHelpMenuKey

+  cmp #ChrF1  ;Teensy mem Menu
   bne +
   lda #rmtTeensy
   jmp MenuChangeInit

+  cmp #ChrF2  ;Exit to BASIC
   bne +
   lda #rCtlBasicReset ;reset to BASIC
   sta wRegControl+IO1Port
-  jmp -  ;should be resetting to BASIC

+  cmp #ChrF3  ;SD Card Menu
   bne +
   lda #rmtSD
   jmp MenuChangeInit

+  cmp #ChrF4  ;toggle music
   bne +
   jsr ToggleSIDMusic
   jmp WaitHelpMenuKey  

+  cmp #ChrF5  ;USB Drive Menu
   bne +
   lda #rmtUSBDrive
   jmp MenuChangeInit
   
+  cmp #ChrF6  ;Show SID info
   bne +
   jmp ShowSIDInfoPage  ;return from there

+  cmp #ChrF7  ;Help
   bne +
   jmp HelpMenu ;refresh (could ignore)

+  cmp #ChrF8  ;Settings Menu
   bne +
   jmp SettingsMenu  ;return from there

+  cmp #ChrSpace  ;back to Main Menu
   bne WaitHelpMenuKey   
   rts


MenuChangeInit:  ;changing menu source.  Prep: Load acc with menu to change to
   sta rWRegCurrMenuWAIT+IO1Port  ;must wait on a write (load dir)
   jsr WaitForTRWaitMsg
rets
   rts

LoadViewKoala:
   ;Koala file is highlighted/detected before calling
   ; acc pre-loaded with ItemType
   cmp #rtFileArt  ;check for Hi-res art file selected
   bne +
   ldx #<ARTBorder
   ldy #>ARTBorder
   lda #$c8
   jmp ++
+  ldx #<KLABackground ;otherwise assume multi-color
   ldy #>KLABackground
   lda #$d8
++ stx smcPicBackgroundSource+1
   sty smcPicBackgroundSource+2
   sta smcPicVICCtlSet+1
   
   jsr StartSelItem_WaitForTRDots ;Tell Teensy to check file and prep for xfer
   
   ;force SID to stay paused (may have been overwritten)
   lda #$ff      ;rpudSIDPauseMask  ;disable SID playback, all bits don't allow un-pause until reload
   sta smcSIDPauseStop+1
   
   jsr FastLoadFile ;check for error and load file to C64 RAM
   bne rets  ;zero flag clear if an error occured, jump to rts from 

smcPicBackgroundSource
   lda KLABackground
   sta BackgndColorReg  ;set vic background color
   sta BorderColorReg   ;set border color to same

   ;copy color and screen data to their final locations:
   ldx #$00
-  lda KLAColorRAM       ,x
   sta C64ColorRAM       ,x
   lda KLAColorRAM + $100,x
   sta C64ColorRAM + $100,x
   lda KLAColorRAM + $200,x
   sta C64ColorRAM + $200,x
   lda KLAColorRAM + $300,x
   sta C64ColorRAM + $300,x

   lda KLAScreenRAM       ,x
   sta C64ScreenRAM       ,x
   lda KLAScreenRAM + $100,x
   sta C64ScreenRAM + $100,x
   lda KLAScreenRAM + $200,x
   sta C64ScreenRAM + $200,x
   lda KLAScreenRAM + $300,x
   sta C64ScreenRAM + $300,x

   dex
   bne -

   lda #$18   
   sta $d018  ;set vic bitmap screen data offset to 8k ($2000)
smcPicVICCtlSet
   lda #$d8    
   sta $d016  ;turn on vic multi-color  or hi-res mode
   lda #$3b    
   sta $d011  ;bit 5 ($20) turns on bitmap graphics mode

   jsr IRQEnable  ;re-start the IRQ wedge
-  jsr CheckForIRQGetIn ;read key/IRQ
   beq -  
   ;a key was pressed
   
   cmp #ChrCRSRUp
   bne +
   inc BackgndColorReg 
   inc BorderColorReg  
   jmp -
   
+  cmp #ChrCRSRDn
   bne +
   dec BackgndColorReg 
   dec BorderColorReg  
   jmp -
   
+  cmp #'-'
   bne +  
   lda #rCtlLastPicture 
CtlWaitReprint
   sta wRegControl+IO1Port
   lda #$00    
   sta $d011   ;turn off the display   
   jsr PrintBanner ;clear screen for messaging
   lda #NameColor
   jsr SendChar
   jsr WaitForTRDots
   lda rRegItemTypePlusIOH+IO1Port ;Read Item type selected
   and #$7f  ;bit 7 indicates an assigned IOHandler, we don't care here
   jmp LoadViewKoala
   
+  cmp #'+'
   bne +
   lda #rCtlNextPicture 
   jmp CtlWaitReprint
   
   ;any other key, just exit...
+  jsr TextScreenMemColor
   rts

TextScreenMemColor:
   ;vic/bitmap back to default for text:
   ;jsr $fda3   ;initialise sid, cia and irq
   ;jsr $e5a0   ;initialize the vic
   lda #$17  ;Lower case
   sta $d018 
   lda #$c8  
   sta $d016 
   lda #$1b  
   sta $d011 
   
   ;set screen and border colors back
   lda #BorderColor
   sta BorderColorReg
   lda #BackgndColor
   sta BackgndColorReg
   rts

TblRowToMemLoc:
   !word C64ScreenRAM+40*(3+ 0)-1
   !word C64ScreenRAM+40*(3+ 1)-1
   !word C64ScreenRAM+40*(3+ 2)-1
   !word C64ScreenRAM+40*(3+ 3)-1
   !word C64ScreenRAM+40*(3+ 4)-1
   !word C64ScreenRAM+40*(3+ 5)-1
   !word C64ScreenRAM+40*(3+ 6)-1
   !word C64ScreenRAM+40*(3+ 7)-1
   !word C64ScreenRAM+40*(3+ 8)-1
   !word C64ScreenRAM+40*(3+ 9)-1
   !word C64ScreenRAM+40*(3+10)-1
   !word C64ScreenRAM+40*(3+11)-1
   !word C64ScreenRAM+40*(3+12)-1
   !word C64ScreenRAM+40*(3+13)-1
   !word C64ScreenRAM+40*(3+14)-1
   !word C64ScreenRAM+40*(3+15)-1
   !word C64ScreenRAM+40*(3+16)-1
   !word C64ScreenRAM+40*(3+17)-1
   !word C64ScreenRAM+40*(3+18)-1
   !word C64ScreenRAM+40*(3+19)-1
   !word C64ScreenRAM+40*(3+20)-1
   ; check MaxItemsPerPage
   
   
   !src "source\SettingsMenu.asm"
   !src "source\PRGLoadStartReloc.s"
   !src "source\SIDRelated.s"
   !src "source\StringFunctions.s"
   !src "source\StringsMsgs.s"

MainCodeRAMEnd = *
   !byte 0
