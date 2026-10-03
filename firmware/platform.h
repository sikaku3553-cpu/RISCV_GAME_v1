#ifndef TD8_GAME_PLATFORM_H
#define TD8_GAME_PLATFORM_H

#include <stdint.h>

/* The firmware itself is assembly.  This mirror is the integration contract
 * for C tests and future C firmware; offsets match platform.inc exactly. */
#define TD8_MMIO32(address) (*(volatile uint32_t *)(uintptr_t)(address))

#define SYS_SWITCHES         0x00001000u
#define SYS_INPUT_LEVEL      0x00001004u
#define SYS_INPUT_RISE       0x00001008u
#define SYS_FRAME_COUNT      0x0000100cu
#define SYS_TIMER_LOW        0x00001010u
#define SYS_CYCLE_LOW        0x00001014u
#define SYS_CYCLE_HIGH       0x00001018u
#define SYS_INSTRET_LOW      0x0000101cu
#define SYS_INSTRET_HIGH     0x00001020u
#define SYS_STALL_LOW        0x00001024u
#define SYS_STALL_HIGH       0x00001028u
#define SYS_FLUSH_LOW        0x0000102cu
#define SYS_FLUSH_HIGH       0x00001030u
#define SYS_MEMWAIT_LOW      0x00001034u
#define SYS_MEMWAIT_HIGH     0x00001038u
#define SYS_COUNTER_CONTROL  0x0000103cu
#define SYS_DEBUG_LEDS       0x00001040u
#define SYS_PS2_STATUS       0x00001044u

#define VGA_STATUS           0x00001100u
#define VGA_SCROLL_X         0x00001104u
#define VGA_BACKDROP         0x00001108u
#define VGA_FRAME_COMMIT     0x0000110cu
#define VGA_LAYER_CONTROL    0x00001110u
#define VGA_HUD_SCORE        0x00001114u
#define VGA_HUD_TIME         0x00001118u
#define VGA_GAME_STATUS      0x0000111cu

#define SPRITE_BASE          0x00001200u
#define SPRITE_STRIDE        0x10u
#define SPRITE_XY(n)         (SPRITE_BASE + SPRITE_STRIDE * (n) + 0x0u)
#define SPRITE_ATTR(n)       (SPRITE_BASE + SPRITE_STRIDE * (n) + 0x4u)
#define SPRITE_TAG(n)        (SPRITE_BASE + SPRITE_STRIDE * (n) + 0x8u)
#define SPRITE_ATTR_ENABLE   0x00000001u
#define SPRITE_ATTR_HFLIP    0x00000002u
#define SPRITE_ATTR_VFLIP    0x00000004u
#define SPRITE_ATTR_PRIORITY(p) (((uint32_t)(p) & 3u) << 4)
#define SPRITE_ATTR_TILE(t)  (((uint32_t)(t) & 0x3fu) << 8)

#define TILEMAP_BASE         0x00002000u
#define DATA_RAM_BASE        0x00004000u
#define DATA_RAM_END         0x00007fffu

#define INPUT_LEFT           0x01u
#define INPUT_RIGHT          0x02u
#define INPUT_JUMP           0x04u
#define INPUT_DOWN           0x08u
#define INPUT_ACTION         0x10u

#define COLLISION_EMPTY      0x00u
#define COLLISION_SOLID      0x40u
#define COLLISION_HAZARD     0x80u
#define COLLISION_SPECIAL    0xc0u

#define TILE_EMPTY            0u
#define TILE_GROUND_TOP       1u
#define TILE_GROUND_FILL      2u
#define TILE_BRICK            3u
#define TILE_BONUS            4u
#define TILE_USED             5u
#define TILE_PIPE_TOP_L       6u
#define TILE_PIPE_TOP_R       7u
#define TILE_PIPE_BODY_L      8u
#define TILE_PIPE_BODY_R      9u
#define TILE_STAIR           10u
#define TILE_GOAL_POLE       11u
#define TILE_GOAL_FLAG       12u
#define TILE_CLOUD           13u
#define TILE_BUSH            14u
#define TILE_HILL            15u
#define TILE_HAZARD          16u
#define TILE_PLAYER_IDLE     32u
#define TILE_PLAYER_WALK     33u
#define TILE_PLAYER_JUMP     34u
#define TILE_ENEMY_A         40u
#define TILE_ENEMY_B         41u
#define TILE_TOKEN           42u
#define TILE_GOAL_SPRITE     43u

/* VGA_GAME_STATUS layout committed at vblank. */
#define GAME_STATUS_STATE_MASK      0x000000ffu
#define GAME_STATUS_ANIMATION_SHIFT 8u
#define GAME_STATUS_LIVES_SHIFT     16u

#endif
