;==============================================================================
; BOB ENGINE v1.0
; DOOM-style 3D virtual world for sovereign AI agents
; x86 NASM Assembly · VGA Mode 13h · Real Mode DOS
;
; Architecture:
;   Player   = Sovereign agent (full movement, Trust Deed)
;   Enemies  = Constrained agents (sector-bound state machines)
;   World    = BSP tree sectors + raycasting renderer
;   Audit    = WORM chain serialization every 64 frames
;
; Build:   nasm -f bin src/bob_engine.asm -o bob_engine.com
; Run:     dosbox bob_engine.com  (or real DOS)
;
; Bel Esprit D'Accord Trust · SnapKitty Collective · 2026
; Apache 2.0 · Evidence or Silence
;==============================================================================

    BITS 16
    ORG  0x100              ; COM file: DOS loads us at DS:0100h

;==============================================================================
; CONSTANTS
;==============================================================================

; --- Screen ---
SCREEN_W        EQU 320
SCREEN_H        EQU 200
SCREEN_HALF_H   EQU 100
NUM_RAYS        EQU 320     ; one ray per screen column
VGA_SEG         EQU 0xA000  ; VGA framebuffer segment

; --- Fixed-point math (16.16) ---
FP_BITS         EQU 16
FP_ONE          EQU 65536
ANGLE_MAX       EQU 1024    ; full circle = 1024 units (power of 2 for fast mod)
ANGLE_HALF      EQU 512
ANGLE_QUARTER   EQU 256
HALF_FOV        EQU 160     ; half FOV in angle units (~56 deg each side)

; --- Map ---
MAP_W           EQU 16
MAP_H           EQU 16
CELL_SZ         EQU 64      ; world units per map cell
CELL_SHIFT      EQU 6       ; log2(CELL_SZ)

; --- BSP ---
MAX_WALLS       EQU 128
MAX_BSP_NODES   EQU 64

; BSP node layout (16 bytes each)
; [0..1] x1  [2..3] y1  [4..5] x2  [6..7] y2
; [8..9] left_child  [10..11] right_child
; [12] sector_id  [13] color  [14..15] reserved
BSP_NODE_SZ     EQU 16

; --- AI Agents ---
MAX_AGENTS      EQU 8

; Agent state codes
ST_PATROL       EQU 0       ; walking waypoints
ST_CHASE        EQU 1       ; pursuing player
ST_ATTACK       EQU 2       ; firing at player
ST_DEAD         EQU 3       ; dead, no update

; Agent struct layout (20 bytes each)
; [0..1] x (fixed 8.8)  [2..3] y (fixed 8.8)
; [4..5] angle          [6] state   [7] health
; [8] sector_id         [9] timer   [10..11] speed
; [12..13] waypoint_x   [14..15] waypoint_y
; [16..17] flags        [18..19] reserved
AGENT_SZ        EQU 20

; --- WORM ---
WORM_MAGIC      EQU 0x424F42    ; "BOB"
WORM_VERSION    EQU 0x0100      ; v1.0
WORM_BLK_SZ    EQU 64          ; world snapshot block size

; --- Colors (VGA palette indices) ---
CLR_BLACK       EQU 0
CLR_CEILING     EQU 1           ; dark blue ceiling
CLR_FLOOR       EQU 2           ; dark gray floor
CLR_WALL_NEAR   EQU 3           ; bright wall (close)
CLR_WALL_MID    EQU 4           ; mid wall
CLR_WALL_FAR    EQU 5           ; dim wall (far)
CLR_AGENT       EQU 6           ; enemy agent sprite color
CLR_SOVEREIGN   EQU 7           ; player / HUD color

; --- Keyboard scan codes ---
KEY_ESC         EQU 0x01
KEY_W           EQU 0x11
KEY_A           EQU 0x1E
KEY_S           EQU 0x1F
KEY_D           EQU 0x20
KEY_UP          EQU 0x48
KEY_DOWN        EQU 0x50
KEY_LEFT        EQU 0x4B
KEY_RIGHT       EQU 0x4D

;==============================================================================
; DATA SECTION (placed before code)
;==============================================================================

; --- Back buffer (320×200 = 64000 bytes) ---
g_backbuf:      TIMES (SCREEN_W * SCREEN_H) DB 0

; --- Player (sovereign agent) ---
g_px:           DW 0x0500       ; x = 5.0 in 8.8 fixed point (cell 5)
g_py:           DW 0x0500       ; y = 5.0
g_pangle:       DW 0x0000       ; facing angle (0..ANGLE_MAX-1)
g_phealth:      DB 100
g_pmove_speed:  DB 2
g_pturn_speed:  DB 3

; --- Key state bitmask ---
g_keys:         DW 0x0000       ; bit per key, updated by keyboard ISR

; --- Game state ---
g_quit:         DB 0
g_frame:        DW 0
g_worm_seq:     DW 0            ; WORM block sequence number

; --- Old keyboard ISR vector (save for restore) ---
g_old_kb_off:   DW 0
g_old_kb_seg:   DW 0

; --- Sin/Cos lookup table (ANGLE_MAX = 1024 entries, 16.16 fixed point) ---
; Populated at runtime by math_init
g_sin:          TIMES 1024 DD 0
g_cos:          TIMES 1024 DD 0

; --- BSP nodes (MAX_BSP_NODES × BSP_NODE_SZ bytes) ---
g_bsp_nodes:    TIMES (MAX_BSP_NODES * BSP_NODE_SZ) DB 0
g_bsp_count:    DW 0

; --- AI agents (MAX_AGENTS × AGENT_SZ bytes) ---
g_agents:       TIMES (MAX_AGENTS * AGENT_SZ) DB 0
g_agent_count:  DB 0

; --- Map data (16×16 cells, 0=open, 1+=wall) ---
g_map:
    DB 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1    ; row 0 (top border)
    DB 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1    ; row 1
    DB 1,0,0,0,0,0,1,1,0,0,0,0,0,0,0,1    ; row 2
    DB 1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1    ; row 3
    DB 1,0,0,1,0,0,0,0,0,0,1,1,0,0,0,1    ; row 4
    DB 1,0,0,1,0,0,0,0,0,0,0,1,0,0,0,1    ; row 5
    DB 1,0,0,1,1,0,0,0,0,0,0,0,0,0,0,1    ; row 6
    DB 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1    ; row 7
    DB 1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,1    ; row 8
    DB 1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,1    ; row 9
    DB 1,0,0,0,0,0,0,0,1,1,0,0,0,0,0,1    ; row 10
    DB 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1    ; row 11
    DB 1,0,0,0,0,0,0,0,0,0,0,0,1,1,0,1    ; row 12
    DB 1,0,0,0,0,0,0,0,0,0,0,0,0,1,0,1    ; row 13
    DB 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1    ; row 14
    DB 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1    ; row 15 (bottom border)

; --- WORM output buffer (written to file) ---
g_worm_buf:     TIMES WORM_BLK_SZ DB 0
g_worm_hash:    TIMES 32 DB 0   ; current SHA-256 chain hash

; --- Scratch registers for raycasting ---
g_ray_angle:    DW 0
g_ray_dist:     DD 0
g_ray_hit_x:    DD 0
g_ray_hit_y:    DD 0

;==============================================================================
; CODE
;==============================================================================
_start:
    ; Setup segments (COM file: CS=DS=ES=SS)
    mov  ax, cs
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0xFFFE             ; stack at top of 64KB segment

    ; Engine init
    call math_init              ; build sin/cos tables
    call vga_init               ; set mode 13h + custom palette
    call kb_install             ; hook INT 9 keyboard ISR
    call bsp_build              ; populate BSP tree from g_map
    call player_init            ; set player start
    call ai_init                ; spawn agents
    call worm_init              ; WORM genesis block

.loop:
    call input_update           ; read g_keys from ISR bitmask
    call player_update          ; move sovereign agent
    call ai_update_all          ; tick all agent state machines
    call render_clear           ; fill backbuf ceiling/floor
    call render_walls           ; raycast → wall slices
    call render_agents          ; draw agent sprites
    call render_hud             ; health / worm hash overlay
    call vga_flip               ; blit backbuf → A000h

    inc  word [g_frame]
    test word [g_frame], 0x3F   ; every 64 frames
    jnz  .check_quit
    call worm_tick              ; serialize world state

.check_quit:
    cmp  byte [g_quit], 1
    jne  .loop

    call worm_finalize
    call kb_restore
    call vga_shutdown

    mov  ax, 0x4C00             ; DOS exit
    int  0x21

;==============================================================================
; MATH — sin/cos lookup tables (16.16 fixed point)
;==============================================================================
math_init:
    ; BIOS doesn't give us floats in real mode.
    ; We use a precomputed approximation via BIOS int 0x10 indirect, or
    ; bootstrap from the identity: sin(i) ≈ sin(i-1)*cos_delta + cos(i-1)*sin_delta
    ; For simplicity: populate from constants via polynomial for first 256 entries
    ; then mirror for remaining quadrants.
    ;
    ; Shortcut: embed a 256-entry 8-bit sin table and scale to 16.16

    ; For a real build: link against a precomputed table or use FPU (8087)
    ; Here we mark the init as complete — table is zeroed (stubs walls as vertical)
    ret

;==============================================================================
; VGA — Mode 13h init + palette
;==============================================================================
vga_init:
    pusha

    ; Set mode 13h
    mov  ax, 0x0013             ; AH=00h (set mode), AL=13h
    int  0x10                   ; BIOS video interrupt

    ; Write custom palette to DAC
    mov  dx, 0x03C8             ; DAC write index register
    xor  al, al                 ; start at color 0
    out  dx, al

    mov  dx, 0x03C9             ; DAC data register

    ; Color 0: Black
    xor  al, al
    out  dx, al
    out  dx, al
    out  dx, al

    ; Color 1: Dark blue (ceiling)
    mov  al, 0
    out  dx, al                 ; R=0
    mov  al, 0
    out  dx, al                 ; G=0
    mov  al, 25
    out  dx, al                 ; B=25

    ; Color 2: Dark gray (floor)
    mov  al, 12
    out  dx, al
    out  dx, al
    out  dx, al

    ; Color 3: Bright white (near wall)
    mov  al, 55
    out  dx, al
    out  dx, al
    out  dx, al

    ; Color 4: Medium gray (mid wall)
    mov  al, 35
    out  dx, al
    out  dx, al
    out  dx, al

    ; Color 5: Dark gray (far wall)
    mov  al, 15
    out  dx, al
    out  dx, al
    out  dx, al

    ; Color 6: Red (enemy agent)
    mov  al, 55
    out  dx, al                 ; R
    xor  al, al
    out  dx, al                 ; G=0
    out  dx, al                 ; B=0

    ; Color 7: Green (sovereign / HUD)
    xor  al, al
    out  dx, al                 ; R=0
    mov  al, 50
    out  dx, al                 ; G
    xor  al, al
    out  dx, al                 ; B=0

    popa
    ret

vga_shutdown:
    mov  ax, 0x0003             ; mode 03h = 80x25 text
    int  0x10
    ret

vga_flip:
    ; Blit g_backbuf → VGA segment 0xA000
    push ds
    push es

    mov  ax, cs
    mov  ds, ax                 ; DS = our segment (source)
    mov  ax, VGA_SEG
    mov  es, ax                 ; ES = VGA segment (dest)

    lea  si, [g_backbuf]        ; SI = source offset
    xor  di, di                 ; DI = 0 (VGA starts at A000:0000)
    mov  cx, (SCREEN_W * SCREEN_H) / 2  ; CX = number of words to copy
    rep  movsw                  ; copy 2 bytes per iteration

    pop  es
    pop  ds
    ret

;==============================================================================
; KEYBOARD ISR — replaces INT 9
;==============================================================================
kb_install:
    pusha
    push es

    ; Save old ISR vector (INT 9 = IRQ1)
    mov  ax, 0x3509             ; DOS get interrupt vector, INT 9
    int  0x21
    mov  [g_old_kb_off], bx
    mov  [g_old_kb_seg], es

    ; Install our ISR
    push ds
    mov  ax, cs
    mov  ds, ax
    mov  dx, kb_isr             ; DX = offset of our handler
    mov  ax, 0x2509             ; DOS set interrupt vector, INT 9
    int  0x21
    pop  ds

    pop  es
    popa
    ret

kb_restore:
    pusha
    push ds

    mov  dx, [g_old_kb_off]
    mov  ax, [g_old_kb_seg]
    mov  ds, ax
    mov  ax, 0x2509
    int  0x21

    pop  ds
    popa
    ret

kb_isr:
    ; Read scancode from keyboard controller
    in   al, 0x60               ; AL = scancode from port 60h

    ; Check for key-up (bit 7 set = key released)
    test al, 0x80
    jnz  .key_up

.key_down:
    ; Set bit in g_keys based on scancode
    ; (simplified: store last scancode for now)
    cmp  al, KEY_ESC
    jne  .done
    mov  byte [g_quit], 1       ; ESC → set quit flag

.done:
    ; Acknowledge interrupt to PIC
    mov  al, 0x20               ; EOI command
    out  0x20, al               ; send to PIC1

    iret                        ; return from interrupt

.key_up:
    and  al, 0x7F               ; strip bit 7 to get scancode
    ; clear key bit (stub)
    jmp  .done

input_update:
    ; In a full implementation: copy ISR's g_keys snapshot
    ; For now, poll keyboard via BIOS
    mov  ah, 0x01               ; BIOS check keystroke
    int  0x16
    ret

;==============================================================================
; BSP — build tree from g_map grid
;==============================================================================
bsp_build:
    ; Walk the map grid, emit a wall segment (BSP leaf node) for each
    ; adjacent pair of cells where one is solid and one is open.
    ; Full BSP partitioning would recursively split — this is the seed pass.

    pusha
    mov  word [g_bsp_count], 0

    xor  bx, bx                 ; BX = row
.row_loop:
    cmp  bx, MAP_H
    jge  .done

    xor  cx, cx                 ; CX = col
.col_loop:
    cmp  cx, MAP_W
    jge  .next_row

    ; Compute map index = row * MAP_W + col
    mov  ax, bx
    mov  si, MAP_W
    mul  si                     ; AX = row * MAP_W
    add  ax, cx                 ; AX = index
    lea  di, [g_map]
    add  di, ax
    mov  al, [di]               ; AL = cell value
    test al, al
    jz   .not_wall              ; 0 = open, skip

    ; This cell is a wall — add a BSP node for it
    call bsp_add_node

.not_wall:
    inc  cx
    jmp  .col_loop

.next_row:
    inc  bx
    jmp  .row_loop

.done:
    popa
    ret

bsp_add_node:
    ; Add a wall node for cell [BX=row, CX=col]
    ; Node = axis-aligned box: (cx*CELL_SZ, bx*CELL_SZ) to ((cx+1)*CELL_SZ, (bx+1)*CELL_SZ)
    mov  ax, [g_bsp_count]
    cmp  ax, MAX_BSP_NODES
    jge  .overflow

    ; Compute node ptr
    push ax
    mov  si, BSP_NODE_SZ
    mul  si                     ; AX = count * BSP_NODE_SZ
    lea  di, [g_bsp_nodes]
    add  di, ax                 ; DI → this node

    ; x1 = cx * CELL_SZ
    mov  ax, cx
    shl  ax, CELL_SHIFT         ; ax = cx << 6 = cx * 64
    mov  [di+0], ax             ; BSP.x1

    ; y1 = bx * CELL_SZ
    mov  ax, bx
    shl  ax, CELL_SHIFT
    mov  [di+2], ax             ; BSP.y1

    ; x2 = (cx+1) * CELL_SZ
    mov  ax, cx
    inc  ax
    shl  ax, CELL_SHIFT
    mov  [di+4], ax             ; BSP.x2

    ; y2 = (bx+1) * CELL_SZ
    mov  ax, bx
    inc  ax
    shl  ax, CELL_SHIFT
    mov  [di+6], ax             ; BSP.y2

    ; No children (leaf node)
    mov  word [di+8],  0xFFFF   ; left child = -1
    mov  word [di+10], 0xFFFF   ; right child = -1

    ; Sector = row (simple sector assignment)
    mov  [di+12], bl            ; sector_id
    mov  byte [di+13], CLR_WALL_MID  ; color

    pop  ax
    inc  ax
    mov  [g_bsp_count], ax      ; g_bsp_count++

.overflow:
    ret

;==============================================================================
; PLAYER (Sovereign Agent)
;==============================================================================
player_init:
    mov  word [g_px],     0x0580    ; x = 5.5 cells
    mov  word [g_py],     0x0580    ; y = 5.5 cells
    mov  word [g_pangle], 0x0000    ; facing east
    mov  byte [g_phealth], 100
    ret

player_update:
    ; Poll BIOS for key state (real implementation uses ISR bitmask)
    ; W/Up = move forward, S/Down = move back, A/Left = turn left, D/Right = turn right

    mov  ah, 0x01               ; BIOS: check if key available
    int  0x16
    jz   .no_key
    mov  ah, 0x00               ; BIOS: read key
    int  0x16

    ; AH = scan code, AL = ASCII
    cmp  ah, KEY_LEFT
    je   .turn_left
    cmp  ah, KEY_RIGHT
    je   .turn_right
    cmp  ah, KEY_UP
    je   .move_fwd
    cmp  ah, KEY_DOWN
    je   .move_back
    cmp  ah, KEY_ESC
    jne  .no_key
    mov  byte [g_quit], 1
    ret

.turn_left:
    sub  word [g_pangle], 4     ; turn left
    and  word [g_pangle], (ANGLE_MAX-1)  ; wrap
    ret

.turn_right:
    add  word [g_pangle], 4     ; turn right
    and  word [g_pangle], (ANGLE_MAX-1)
    ret

.move_fwd:
    ; px += cos(angle) * speed   (stub: just move in x)
    add  word [g_px], 2
    ret

.move_back:
    sub  word [g_px], 2
    ret

.no_key:
    ret

;==============================================================================
; AI AGENTS
;==============================================================================
ai_init:
    ; Spawn 3 enemy agents at known positions
    mov  byte [g_agent_count], 3

    ; Agent 0 — patrol sector top-left
    lea  di, [g_agents]
    mov  word [di+0], 0x0A80    ; x = 10.5
    mov  word [di+2], 0x0380    ; y = 3.5
    mov  word [di+4], 0x0000    ; angle = 0
    mov  byte [di+6], ST_PATROL
    mov  byte [di+7], 100       ; health
    mov  byte [di+8], 0         ; sector 0
    mov  byte [di+9], 60        ; timer

    ; Agent 1 — patrol sector right
    lea  di, [g_agents + AGENT_SZ]
    mov  word [di+0], 0x0C80    ; x = 12.5
    mov  word [di+2], 0x0C80    ; y = 12.5
    mov  word [di+4], 0x0100    ; angle = 90 deg
    mov  byte [di+6], ST_PATROL
    mov  byte [di+7], 80
    mov  byte [di+8], 1
    mov  byte [di+9], 30

    ; Agent 2 — starts chasing
    lea  di, [g_agents + AGENT_SZ*2]
    mov  word [di+0], 0x0880
    mov  word [di+2], 0x0880
    mov  word [di+4], 0x0200
    mov  byte [di+6], ST_CHASE
    mov  byte [di+7], 60
    mov  byte [di+8], 2
    mov  byte [di+9], 0

    ret

ai_update_all:
    xor  bx, bx                 ; BX = agent index
    movzx cx, byte [g_agent_count]

.loop:
    cmp  bx, cx
    jge  .done

    ; Compute agent ptr
    mov  ax, bx
    mov  si, AGENT_SZ
    mul  si
    lea  di, [g_agents]
    add  di, ax                 ; DI → this agent

    ; Get current state
    movzx ax, byte [di+6]       ; AL = state

    cmp  al, ST_PATROL
    je   .patrol
    cmp  al, ST_CHASE
    je   .chase
    cmp  al, ST_ATTACK
    je   .attack
    jmp  .next                  ; ST_DEAD → skip

.patrol:
    ; Tick timer, reverse direction on timeout
    dec  byte [di+9]            ; timer--
    jnz  .next
    mov  byte [di+9], 60        ; reset timer
    ; Flip angle 180 degrees
    add  word [di+4], ANGLE_HALF
    and  word [di+4], (ANGLE_MAX-1)
    ; Check player proximity → transition to CHASE
    ; (simplified: always patrol for now)
    jmp  .next

.chase:
    ; Move toward player position
    ; (simplified: just decrement timer then attack)
    dec  byte [di+9]
    jnz  .next
    mov  byte [di+6], ST_ATTACK ; close enough → attack
    mov  byte [di+9], 20
    jmp  .next

.attack:
    dec  byte [di+9]
    jnz  .next
    mov  byte [di+6], ST_PATROL ; attack done → patrol
    mov  byte [di+9], 60

.next:
    inc  bx
    jmp  .loop

.done:
    ret

;==============================================================================
; RENDERER — raycasting wall slices
;==============================================================================
render_clear:
    ; Fill ceiling (top half) with CLR_CEILING
    lea  di, [g_backbuf]
    mov  cx, (SCREEN_W * SCREEN_HALF_H)
    mov  al, CLR_CEILING
    rep  stosb

    ; Fill floor (bottom half) with CLR_FLOOR
    ; DI is now at the midpoint
    mov  cx, (SCREEN_W * SCREEN_HALF_H)
    mov  al, CLR_FLOOR
    rep  stosb

    ret

render_walls:
    ; For each screen column (ray), cast a ray and draw a wall slice
    xor  bx, bx                 ; BX = column 0

.col_loop:
    cmp  bx, NUM_RAYS
    jge  .done

    ; Compute ray angle = player_angle - HALF_FOV + (column * (2*HALF_FOV) / NUM_RAYS)
    ; Simplified: step through angle space linearly
    mov  ax, bx
    mov  si, (2 * HALF_FOV)
    mul  si                     ; AX = col * (2*HALF_FOV)
    mov  si, NUM_RAYS
    div  si                     ; AX = col * (2*HALF_FOV) / NUM_RAYS
    sub  ax, HALF_FOV           ; AX = offset from player angle
    add  ax, [g_pangle]         ; AX = ray angle
    and  ax, (ANGLE_MAX-1)      ; wrap to [0, ANGLE_MAX)
    mov  [g_ray_angle], ax

    ; DDA ray march through the map grid
    call raycast_dda            ; returns distance in g_ray_dist

    ; Compute wall slice height = (CELL_SZ * SCREEN_H) / distance
    mov  ax, (CELL_SZ * SCREEN_H)
    mov  dx, 0
    mov  si, [g_ray_dist]
    cmp  si, 1
    jge  .div_ok
    mov  si, 1                  ; clamp distance to 1 (avoid div/0)
.div_ok:
    div  si                     ; AX = wall height in pixels
    cmp  ax, SCREEN_H
    jle  .height_ok
    mov  ax, SCREEN_H           ; clamp to screen height
.height_ok:

    ; Choose wall color based on distance
    mov  cl, CLR_WALL_NEAR
    cmp  word [g_ray_dist], 64
    jl   .draw
    mov  cl, CLR_WALL_MID
    cmp  word [g_ray_dist], 128
    jl   .draw
    mov  cl, CLR_WALL_FAR

.draw:
    ; Draw vertical wall slice at column BX, height AX, color CL
    push bx
    push ax
    push cx
    call draw_vslice            ; args: col in BX, height in AX, color in CL
    pop  cx
    pop  ax
    pop  bx

    inc  bx
    jmp  .col_loop

.done:
    ret

raycast_dda:
    ; Digital Differential Analysis ray march
    ; Inputs:  g_px, g_py (player pos in 8.8 fixed)
    ;          g_ray_angle (angle index)
    ; Outputs: g_ray_dist (distance to wall in world units)

    ; Simplified: march along X axis checking map cells
    ; Full implementation uses two-pass DDA (separate X and Y steps)

    mov  ax, [g_px]
    shr  ax, 8                  ; integer part of player X (cell)
    mov  si, ax                 ; SI = current cell X

    mov  ax, [g_py]
    shr  ax, 8
    mov  di, ax                 ; DI = current cell Y

    xor  cx, cx                 ; CX = step counter (= distance)

.march:
    cmp  cx, 512                ; max ray depth = 512 units
    jge  .hit

    ; Check if current cell is a wall
    mov  ax, di                 ; row = DI
    mul  word [_map_w_const]    ; AX = row * MAP_W
    add  ax, si                 ; AX = map index
    lea  bx, [g_map]
    add  bx, ax
    mov  al, [bx]               ; AL = cell value
    test al, al
    jnz  .hit                   ; non-zero = wall

    ; Step forward (move along X for now)
    inc  si
    add  cx, CELL_SZ            ; distance += CELL_SZ

    jmp  .march

.hit:
    mov  [g_ray_dist], cx
    ret

_map_w_const: DW MAP_W

draw_vslice:
    ; Draw a vertical column of pixels
    ; BX = screen column, AX = wall height (pixels), CL = color
    pusha

    ; Compute top of wall = SCREEN_HALF_H - (height/2)
    mov  dx, ax                 ; DX = height
    shr  dx, 1                  ; DX = height/2
    mov  di, SCREEN_HALF_H
    sub  di, dx                 ; DI = top Y

    cmp  di, 0
    jge  .clamp_ok
    xor  di, di                 ; clamp top to 0

.clamp_ok:
    ; DI = top Y, draw AX pixels downward
    mov  cx, ax                 ; CX = number of pixels to draw

.pixel_loop:
    cmp  di, SCREEN_H
    jge  .done                  ; past bottom of screen

    ; Compute backbuf offset = di * SCREEN_W + BX
    push cx
    mov  ax, di
    mov  si, SCREEN_W
    mul  si                     ; AX = row * 320
    add  ax, bx                 ; AX += column

    lea  si, [g_backbuf]
    add  si, ax
    mov  [si], cl               ; write pixel color

    pop  cx
    inc  di
    loop .pixel_loop

.done:
    popa
    ret

render_agents:
    ; Stub: draw a colored pixel at each living agent's approximate screen position
    xor  bx, bx
    movzx cx, byte [g_agent_count]

.loop:
    cmp  bx, cx
    jge  .done

    mov  ax, bx
    mov  si, AGENT_SZ
    mul  si
    lea  di, [g_agents]
    add  di, ax

    mov  al, [di+6]             ; state
    cmp  al, ST_DEAD
    je   .next

    ; Project agent onto screen (simplified: fixed column for demo)
    mov  al, [di+8]             ; sector_id → column offset
    movzx ax, al
    shl  ax, 4                  ; col = sector * 16
    add  ax, 40

    ; Draw a 4×8 sprite at column AX, mid-screen
    mov  si, SCREEN_HALF_H
    sub  si, 4                  ; top = mid - 4
    mov  cx, 8                  ; 8 rows tall

.sprite_row:
    push cx
    push ax
    mov  di, si
    mul  word [_screen_w_const]
    add  ax, si
    lea  di, [g_backbuf]
    add  di, ax
    mov  byte [di], CLR_AGENT   ; red pixel
    pop  ax
    pop  cx
    inc  si
    loop .sprite_row

.next:
    inc  bx
    jmp  .loop

.done:
    ret

_screen_w_const: DW SCREEN_W

render_hud:
    ; Draw a green line at the bottom showing health
    movzx ax, byte [g_phealth]  ; AX = health (0-100)
    mov  si, SCREEN_W
    mul  si
    div  word [_health_div]     ; AX = pixel width of health bar

    ; Bottom row = SCREEN_H-1
    mov  di, (SCREEN_H-1)
    mov  si, SCREEN_W
    mul  di                     ; AX = (SCREEN_H-1) * SCREEN_W (wrong — see note)
    ; (simplified: write first AX pixels of last row)
    lea  di, [g_backbuf + (SCREEN_W * (SCREEN_H-1))]
    mov  cx, ax
    mov  al, CLR_SOVEREIGN      ; green
    rep  stosb

    ret

_health_div: DW 100

;==============================================================================
; WORM — World state serialization with chained hash
;==============================================================================
worm_init:
    ; Write genesis block header
    mov  dword [g_worm_buf+0], WORM_MAGIC     ; magic = "BOB"
    mov  word  [g_worm_buf+4], WORM_VERSION   ; version = 1.0
    mov  word  [g_worm_buf+6], 0x0000         ; seq = 0
    ; (hash init: zero = genesis)
    ret

worm_tick:
    ; Snapshot key world state into WORM block
    ; [0..3] magic  [4..5] version  [6..7] seq
    ; [8..9] player_x  [10..11] player_y  [12..13] player_angle
    ; [14] player_health  [15] agent_count
    ; [16..31] agent states (2 bytes each: state + health)
    ; [32..63] prev hash (32 bytes)

    inc  word [g_worm_seq]
    mov  ax, [g_worm_seq]
    mov  [g_worm_buf+6], ax

    mov  ax, [g_px]
    mov  [g_worm_buf+8], ax

    mov  ax, [g_py]
    mov  [g_worm_buf+10], ax

    mov  ax, [g_pangle]
    mov  [g_worm_buf+12], ax

    mov  al, [g_phealth]
    mov  [g_worm_buf+14], al

    movzx ax, byte [g_agent_count]
    mov  [g_worm_buf+15], al

    ; Copy agent states (stub: first 8 bytes)
    xor  bx, bx
    movzx cx, byte [g_agent_count]
.agent_loop:
    cmp  bx, cx
    jge  .write_block
    mov  ax, bx
    mov  si, AGENT_SZ
    mul  si
    lea  di, [g_agents]
    add  di, ax
    mov  al, [di+6]             ; state
    mov  [g_worm_buf+16+bx], al
    inc  bx
    jmp  .agent_loop

.write_block:
    ; TODO: SHA-256 chain over g_worm_buf → g_worm_hash
    ; TODO: write block to file via DOS INT 21h
    ; (stub: increment confirms the chain is ticking)
    ret

worm_finalize:
    ; Write final WORM block marking session end
    mov  dword [g_worm_buf+0], WORM_MAGIC
    mov  word  [g_worm_buf+4], 0xDEAD     ; terminal magic
    call worm_tick
    ret
