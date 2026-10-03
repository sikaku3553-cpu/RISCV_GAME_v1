# v3.1 Game Platform memory map shared by the hand-written firmware.
# Keep this file numerically identical to platform.h and README_GAME_PLATFORM.md.
# *_HIGH counter registers and both MEMWAIT registers currently read zero.
# SYS_COUNTER_CONTROL reads zero; writes are accepted but have no effect.

.equ SYS_BASE,             0x00001000
.equ SYS_SWITCHES,         0x00001000
.equ SYS_INPUT_LEVEL,      0x00001004
.equ SYS_INPUT_RISE,       0x00001008
.equ SYS_FRAME_COUNT,      0x0000100c
.equ SYS_TIMER_LOW,        0x00001010
.equ SYS_CYCLE_LOW,        0x00001014
.equ SYS_CYCLE_HIGH,       0x00001018
.equ SYS_INSTRET_LOW,      0x0000101c
.equ SYS_INSTRET_HIGH,     0x00001020
.equ SYS_STALL_LOW,        0x00001024
.equ SYS_STALL_HIGH,       0x00001028
.equ SYS_FLUSH_LOW,        0x0000102c
.equ SYS_FLUSH_HIGH,       0x00001030
.equ SYS_MEMWAIT_LOW,      0x00001034
.equ SYS_MEMWAIT_HIGH,     0x00001038
.equ SYS_COUNTER_CONTROL,  0x0000103c
.equ SYS_DEBUG_LEDS,       0x00001040
.equ SYS_PS2_STATUS,       0x00001044

.equ VGA_BASE,             0x00001100
.equ VGA_STATUS,           0x00001100
.equ VGA_SCROLL_X,         0x00001104
.equ VGA_BACKDROP,         0x00001108
.equ VGA_FRAME_COMMIT,     0x0000110c
.equ VGA_LAYER_CONTROL,    0x00001110
.equ VGA_HUD_SCORE,        0x00001114
.equ VGA_HUD_TIME,         0x00001118
.equ VGA_GAME_STATUS,      0x0000111c

# VGA_FRAME_COMMIT reads pending in bit 0.  Writing bit 0 requests commit.

.equ SPRITE_BASE,          0x00001200
.equ SPRITE_STRIDE,        0x10
.equ SPRITE_XY,            0x0
.equ SPRITE_ATTR,          0x4
.equ SPRITE_TAG,           0x8
.equ SPRITE_RESERVED,      0xc

# SPRITE_RESERVED reads zero; writes raise a data-bus access fault.

.equ TILEMAP_BASE,         0x00002000
.equ DATA_BASE,            0x00004000
.equ STACK_TOP,            0x00008000

# Logical input bitmap.  Hardware buttons and PS/2 keys map to these bits.
.equ INPUT_LEFT,            0x01
.equ INPUT_RIGHT,           0x02
.equ INPUT_JUMP,            0x04
.equ INPUT_DOWN,            0x08
.equ INPUT_ACTION,          0x10

# Sprite ATTR: enable[0], hflip[1], vflip[2], priority[5:4], tile[13:8].
.equ SPRITE_ENABLE,         0x01
.equ SPRITE_HFLIP,          0x02
.equ SPRITE_VFLIP,          0x04

# Tile byte: graphic id[5:0], collision class[7:6].
.equ COLLISION_EMPTY,       0x00
.equ COLLISION_SOLID,       0x40
.equ COLLISION_HAZARD,      0x80
.equ COLLISION_SPECIAL,     0xc0

# Original/project-created atlas allocation (not Nintendo ROM data).
.equ TILE_EMPTY,            0
.equ TILE_GROUND_TOP,       1
.equ TILE_GROUND_FILL,      2
.equ TILE_BRICK,            3
.equ TILE_BONUS,            4
.equ TILE_USED,             5
.equ TILE_PIPE_TOP_L,       6
.equ TILE_PIPE_TOP_R,       7
.equ TILE_PIPE_BODY_L,      8
.equ TILE_PIPE_BODY_R,      9
.equ TILE_STAIR,           10
.equ TILE_GOAL_POLE,       11
.equ TILE_GOAL_FLAG,       12
.equ TILE_CLOUD,           13
.equ TILE_BUSH,            14
.equ TILE_HILL,            15
.equ TILE_HAZARD,          16
.equ TILE_PLAYER_IDLE,     32
.equ TILE_PLAYER_WALK,     33
.equ TILE_PLAYER_JUMP,     34
.equ TILE_ENEMY_A,         40
.equ TILE_ENEMY_B,         41
.equ TILE_TOKEN,           42
.equ TILE_GOAL_SPRITE,     43
