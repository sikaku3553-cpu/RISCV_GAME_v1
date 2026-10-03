# Original RV32I-only side-scroller firmware for the v3.1 Game Platform.
#
# The CPU owns every game-state transition.  VGA hardware only scans the tile
# map and the descriptors written here.  Coordinates are integer logical
# pixels in a 256x240 viewport; X is a world coordinate and VGA_SCROLL_X
# selects the visible part of the 96-tile-wide level.

.include "platform.inc"

# Data RAM state.  All values are 32-bit words unless noted otherwise.
.equ ST_PLAYER_X,       0x00
.equ ST_PLAYER_Y,       0x04
.equ ST_PLAYER_VX,      0x08
.equ ST_PLAYER_VY,      0x0c
.equ ST_GROUNDED,       0x10
.equ ST_PREV_INPUT,     0x14
.equ ST_GAME_STATE,     0x18
.equ ST_CAMERA_X,       0x1c
.equ ST_SCORE,          0x20
.equ ST_TIME,           0x24
.equ ST_SECOND_DIV,     0x28
.equ ST_ANIMATION,      0x2c
.equ ST_FRAME_LAST,     0x30
.equ ST_DEATH_TIMER,    0x34
.equ ST_LIVES,          0x38

.equ ENEMY0,            0x50
.equ ENEMY1,            0x68
.equ ENEMY2,            0x80
.equ ENEMY_X,           0x00
.equ ENEMY_Y,           0x04
.equ ENEMY_DIR,         0x08
.equ ENEMY_ACTIVE,      0x0c
.equ ENEMY_ANIM,        0x10
.equ ENEMY_RESERVED,    0x14

.equ STATE_PLAY,        0
.equ STATE_DEAD,        1
.equ STATE_WIN,         2

.equ LEVEL_TILES,       96
.equ LEVEL_WIDTH_PX,    1536
.equ CAMERA_MAX,        1280
.equ GROUND_Y,          193
.equ PLAYER_WIDTH,      12
.equ PLAYER_HEIGHT,     15
.equ FRAME_HZ,          60

.section .text
.globl _start
.org 0

_start:
    li      sp, STACK_TOP
    li      s0, DATA_BASE
    li      s1, SYS_BASE
    li      s2, VGA_BASE
    li      s3, SPRITE_BASE
    li      s4, TILEMAP_BASE

    call    init_level
    call    new_game

    # Configure both display layers and an original sky-blue RGB444 color.
    li      t0, 0x58e
    sw      t0, VGA_BACKDROP-VGA_BASE(s2)
    li      t0, 0x7
    sw      t0, VGA_LAYER_CONTROL-VGA_BASE(s2)
    lw      t0, SYS_FRAME_COUNT-SYS_BASE(s1)
    sw      t0, ST_FRAME_LAST(s0)
    call    render_frame

# Frame count, not CPU clock throttling, defines the deterministic update rate.
frame_wait:
    lw      t0, SYS_FRAME_COUNT-SYS_BASE(s1)
    lw      t1, ST_FRAME_LAST(s0)
    beq     t0, t1, frame_wait
    sw      t0, ST_FRAME_LAST(s0)

    lw      a0, SYS_INPUT_LEVEL-SYS_BASE(s1)
    lw      t1, ST_PREV_INPUT(s0)
    xori    t2, t1, -1
    and     a1, a0, t2
    sw      a0, ST_PREV_INPUT(s0)

    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, frame_nonplay
    call    update_player
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, frame_after_logic
    call    update_enemies
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, frame_after_logic
    call    update_timer
    j       frame_after_logic

frame_nonplay:
    mv      a0, a1
    call    update_nonplay

frame_after_logic:
    call    update_animation
    call    update_camera
    call    render_frame
    j       frame_wait


# ---------------------------------------------------------------------------
# Level construction.  Collision classes live in tile bits [7:6], so the CPU
# reads exactly the same map that the renderer displays.  The layout is an
# original educational level: ground, gaps, blocks, pipes, stairs and a goal.
# ---------------------------------------------------------------------------
init_level:
    addi    sp, sp, -4
    sw      ra, 0(sp)

    # Clear the complete 256 x 16 byte aperture.
    mv      t0, s4
    li      t1, 4096
    add     t1, t1, s4
    li      t2, 0
init_clear_loop:
    sb      t2, 0(t0)
    addi    t0, t0, 1
    bne     t0, t1, init_clear_loop

    # Two ground rows across the playable 96 columns, except three pits.
    li      t0, 0
init_ground_loop:
    li      t1, LEVEL_TILES
    bge     t0, t1, init_ground_done
    li      t1, 20
    blt     t0, t1, init_ground_write
    li      t1, 24
    blt     t0, t1, init_ground_next
    li      t1, 45
    blt     t0, t1, init_ground_write
    li      t1, 49
    blt     t0, t1, init_ground_next
    li      t1, 72
    blt     t0, t1, init_ground_write
    li      t1, 76
    blt     t0, t1, init_ground_next

init_ground_write:
    li      t1, 3328                 # row 13 << 8
    add     t1, t1, s4
    add     t1, t1, t0
    li      t2, COLLISION_SOLID | TILE_GROUND_TOP
    sb      t2, 0(t1)
    addi    t1, t1, 256              # row 14
    li      t2, COLLISION_SOLID | TILE_GROUND_FILL
    sb      t2, 0(t1)
init_ground_next:
    addi    t0, t0, 1
    j       init_ground_loop
init_ground_done:

    # Brick and bonus-block groups.
    li      a0, 8
    li      a1, 9
    li      a2, 6
    li      a3, COLLISION_SOLID | TILE_BRICK
    call    place_hline
    li      a0, 10
    li      a1, 9
    li      a2, 1
    li      a3, COLLISION_SOLID | TILE_BONUS
    call    place_hline
    li      a0, 34
    li      a1, 8
    li      a2, 8
    li      a3, COLLISION_SOLID | TILE_BRICK
    call    place_hline
    li      a0, 37
    li      a1, 8
    li      a2, 1
    li      a3, COLLISION_SOLID | TILE_BONUS
    call    place_hline

    # Pipes have solid tops and bodies.  a0=x, a1=top row.
    li      a0, 28
    li      a1, 10
    call    place_pipe
    li      a0, 53
    li      a1, 9
    call    place_pipe
    li      a0, 78
    li      a1, 8
    call    place_pipe

    # Six ascending stair columns ending just before the third gap.
    li      a0, 62
    li      a1, 6
    call    place_stairs

    # A visible hazard tile exercises collision class 10 without hidden logic.
    li      a0, 58
    li      a1, 12
    li      a2, COLLISION_HAZARD | TILE_HAZARD
    call    set_tile

    # Goal pole uses special collision class 11; touching it wins in software.
    li      a0, 90
    li      a1, 5
    li      a2, 8
    li      a3, COLLISION_SPECIAL | TILE_GOAL_POLE
    call    place_vline
    li      a0, 89
    li      a1, 5
    li      a2, COLLISION_SPECIAL | TILE_GOAL_FLAG
    call    set_tile

    # Non-colliding decorative project-created tiles.
    li      a0, 16
    li      a1, 4
    li      a2, TILE_CLOUD
    call    set_tile
    li      a0, 43
    li      a1, 3
    li      a2, TILE_CLOUD
    call    set_tile
    li      a0, 6
    li      a1, 12
    li      a2, TILE_BUSH
    call    set_tile
    li      a0, 84
    li      a1, 12
    li      a2, TILE_HILL
    call    set_tile

    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# set_tile(x tile, y tile, encoded byte)
set_tile:
    slli    t0, a1, 8
    add     t0, t0, a0
    add     t0, t0, s4
    sb      a2, 0(t0)
    ret

# place_hline(x, y, count, encoded byte)
place_hline:
    slli    t0, a1, 8
    add     t0, t0, a0
    add     t0, t0, s4
place_hline_loop:
    beqz    a2, place_hline_done
    sb      a3, 0(t0)
    addi    t0, t0, 1
    addi    a2, a2, -1
    j       place_hline_loop
place_hline_done:
    ret

# place_vline(x, y, count, encoded byte)
place_vline:
    slli    t0, a1, 8
    add     t0, t0, a0
    add     t0, t0, s4
place_vline_loop:
    beqz    a2, place_vline_done
    sb      a3, 0(t0)
    addi    t0, t0, 256
    addi    a2, a2, -1
    j       place_vline_loop
place_vline_done:
    ret

# place_pipe(x, top_y), extending both columns through row 12.
place_pipe:
    slli    t0, a1, 8
    add     t0, t0, a0
    add     t0, t0, s4
    li      t1, COLLISION_SOLID | TILE_PIPE_TOP_L
    sb      t1, 0(t0)
    li      t1, COLLISION_SOLID | TILE_PIPE_TOP_R
    sb      t1, 1(t0)
    addi    a1, a1, 1
    addi    t0, t0, 256
place_pipe_body:
    li      t1, 13
    bge     a1, t1, place_pipe_done
    li      t1, COLLISION_SOLID | TILE_PIPE_BODY_L
    sb      t1, 0(t0)
    li      t1, COLLISION_SOLID | TILE_PIPE_BODY_R
    sb      t1, 1(t0)
    addi    a1, a1, 1
    addi    t0, t0, 256
    j       place_pipe_body
place_pipe_done:
    ret

# place_stairs(first_x, columns); column n is n+1 solid tiles high.
place_stairs:
    li      t0, 0
place_stairs_column:
    bge     t0, a1, place_stairs_done
    li      t1, 12
    sub     t1, t1, t0
    slli    t2, t1, 8
    add     t2, t2, a0
    add     t2, t2, t0
    add     t2, t2, s4
    addi    t3, t0, 1
    li      t4, COLLISION_SOLID | TILE_STAIR
place_stairs_row:
    beqz    t3, place_stairs_next
    sb      t4, 0(t2)
    addi    t2, t2, 256
    addi    t3, t3, -1
    j       place_stairs_row
place_stairs_next:
    addi    t0, t0, 1
    j       place_stairs_column
place_stairs_done:
    ret


# ---------------------------------------------------------------------------
# Game lifecycle.
# ---------------------------------------------------------------------------
new_game:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    sw      zero, ST_SCORE(s0)
    li      t0, 3
    sw      t0, ST_LIVES(s0)
    call    reset_round
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

reset_round:
    li      t0, 32
    sw      t0, ST_PLAYER_X(s0)
    li      t0, GROUND_Y
    sw      t0, ST_PLAYER_Y(s0)
    sw      zero, ST_PLAYER_VX(s0)
    sw      zero, ST_PLAYER_VY(s0)
    li      t0, 1
    sw      t0, ST_GROUNDED(s0)
    sw      zero, ST_PREV_INPUT(s0)
    sw      zero, ST_GAME_STATE(s0)
    sw      zero, ST_CAMERA_X(s0)
    li      t0, 300
    sw      t0, ST_TIME(s0)
    sw      zero, ST_SECOND_DIV(s0)
    li      t0, TILE_PLAYER_IDLE
    sw      t0, ST_ANIMATION(s0)
    sw      zero, ST_DEATH_TIMER(s0)

    li      t0, 288
    sw      t0, ENEMY0+ENEMY_X(s0)
    li      t0, GROUND_Y
    sw      t0, ENEMY0+ENEMY_Y(s0)
    li      t0, -1
    sw      t0, ENEMY0+ENEMY_DIR(s0)
    li      t0, 1
    sw      t0, ENEMY0+ENEMY_ACTIVE(s0)
    sw      zero, ENEMY0+ENEMY_ANIM(s0)

    li      t0, 640
    sw      t0, ENEMY1+ENEMY_X(s0)
    li      t0, GROUND_Y
    sw      t0, ENEMY1+ENEMY_Y(s0)
    li      t0, -1
    sw      t0, ENEMY1+ENEMY_DIR(s0)
    li      t0, 1
    sw      t0, ENEMY1+ENEMY_ACTIVE(s0)
    sw      zero, ENEMY1+ENEMY_ANIM(s0)

    li      t0, 1080
    sw      t0, ENEMY2+ENEMY_X(s0)
    li      t0, GROUND_Y
    sw      t0, ENEMY2+ENEMY_Y(s0)
    li      t0, 1
    sw      t0, ENEMY2+ENEMY_DIR(s0)
    li      t0, 1
    sw      t0, ENEMY2+ENEMY_ACTIVE(s0)
    sw      zero, ENEMY2+ENEMY_ANIM(s0)
    ret

set_dead:
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, set_dead_done
    li      t0, STATE_DEAD
    sw      t0, ST_GAME_STATE(s0)
    li      t0, 90
    sw      t0, ST_DEATH_TIMER(s0)
    lw      t0, ST_LIVES(s0)
    beqz    t0, set_dead_done
    addi    t0, t0, -1
    sw      t0, ST_LIVES(s0)
set_dead_done:
    ret

set_win:
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, set_win_done
    li      t0, STATE_WIN
    sw      t0, ST_GAME_STATE(s0)
    lw      t0, ST_SCORE(s0)
    addi    t0, t0, 1000
    sw      t0, ST_SCORE(s0)
set_win_done:
    ret

# a0 is this frame's rising input bitmap.
update_nonplay:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    li      t0, INPUT_ACTION | INPUT_JUMP
    and     t0, t0, a0
    beqz    t0, update_nonplay_done
    lw      t0, ST_GAME_STATE(s0)
    li      t1, STATE_WIN
    beq     t0, t1, update_nonplay_new_game
    lw      t0, ST_LIVES(s0)
    beqz    t0, update_nonplay_new_game
    call    reset_round
    j       update_nonplay_done
update_nonplay_new_game:
    call    new_game
update_nonplay_done:
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret


# ---------------------------------------------------------------------------
# Collision and player physics.  tile_class_at is the sole collision query;
# there is no collision controller hidden in VGA logic.
# ---------------------------------------------------------------------------
# tile_class_at(pixel_x, pixel_y) -> a0 in {0x00,0x40,0x80,0xc0}
tile_class_at:
    bltz    a0, tile_class_solid
    bltz    a1, tile_class_empty
    li      t0, LEVEL_WIDTH_PX
    bge     a0, t0, tile_class_solid
    li      t0, 256
    bge     a1, t0, tile_class_empty
    srli    t0, a0, 4
    srli    t1, a1, 4
    slli    t1, t1, 8
    add     t0, t0, t1
    add     t0, t0, s4
    lbu     a0, 0(t0)
    andi    a0, a0, 0xc0
    ret
tile_class_solid:
    li      a0, COLLISION_SOLID
    ret
tile_class_empty:
    li      a0, COLLISION_EMPTY
    ret

# update_player(input level=a0, input rising=a1)
update_player:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s5, 24(sp)
    sw      s6, 20(sp)
    sw      s7, 16(sp)
    sw      s8, 12(sp)

    # Horizontal acceleration and friction, clamped to -3..+3 px/frame.
    lw      t0, ST_PLAYER_VX(s0)
    andi    t1, a0, INPUT_LEFT
    andi    t2, a0, INPUT_RIGHT
    beqz    t1, player_try_right
    bnez    t2, player_friction
    addi    t0, t0, -1
    li      t3, -3
    bge     t0, t3, player_vx_ready
    mv      t0, t3
    j       player_vx_ready
player_try_right:
    beqz    t2, player_friction
    addi    t0, t0, 1
    li      t3, 3
    bge     t3, t0, player_vx_ready
    mv      t0, t3
    j       player_vx_ready
player_friction:
    beqz    t0, player_vx_ready
    bltz    t0, player_friction_negative
    addi    t0, t0, -1
    j       player_vx_ready
player_friction_negative:
    addi    t0, t0, 1
player_vx_ready:
    sw      t0, ST_PLAYER_VX(s0)

    # Jump is edge-sensitive and only starts while grounded.
    andi    t1, a1, INPUT_JUMP
    beqz    t1, player_apply_gravity
    lw      t1, ST_GROUNDED(s0)
    beqz    t1, player_apply_gravity
    li      t1, -7
    sw      t1, ST_PLAYER_VY(s0)
    sw      zero, ST_GROUNDED(s0)
player_apply_gravity:
    lw      t1, ST_PLAYER_VY(s0)
    addi    t1, t1, 1
    li      t2, 6
    bge     t2, t1, player_gravity_ready
    mv      t1, t2
player_gravity_ready:
    sw      t1, ST_PLAYER_VY(s0)

    # Horizontal move: sample the leading edge at two heights.
    lw      s6, ST_PLAYER_VX(s0)
    lw      t0, ST_PLAYER_X(s0)
    add     s5, t0, s6
    lw      s7, ST_PLAYER_Y(s0)
    beqz    s6, player_vertical_begin
    mv      a0, s5
    bltz    s6, player_h_probe_x_ready
    addi    a0, a0, PLAYER_WIDTH-1
player_h_probe_x_ready:
    addi    a1, s7, 1
    call    tile_class_at
    mv      s8, a0
    li      t0, COLLISION_HAZARD
    beq     s8, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     s8, t0, player_hit_goal

    mv      a0, s5
    bltz    s6, player_h_probe2_x_ready
    addi    a0, a0, PLAYER_WIDTH-1
player_h_probe2_x_ready:
    addi    a1, s7, PLAYER_HEIGHT-1
    call    tile_class_at
    li      t0, COLLISION_HAZARD
    beq     a0, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     a0, t0, player_hit_goal
    li      t0, COLLISION_SOLID
    beq     s8, t0, player_horizontal_blocked
    beq     a0, t0, player_horizontal_blocked
    sw      s5, ST_PLAYER_X(s0)
    j       player_vertical_begin

player_horizontal_blocked:
    mv      t0, s5
    bltz    s6, player_snap_left
    addi    t0, t0, PLAYER_WIDTH-1
    srli    t0, t0, 4
    slli    t0, t0, 4
    addi    t0, t0, -PLAYER_WIDTH
    sw      t0, ST_PLAYER_X(s0)
    sw      zero, ST_PLAYER_VX(s0)
    j       player_vertical_begin
player_snap_left:
    srli    t0, t0, 4
    addi    t0, t0, 1
    slli    t0, t0, 4
    sw      t0, ST_PLAYER_X(s0)
    sw      zero, ST_PLAYER_VX(s0)

player_vertical_begin:
    lw      s6, ST_PLAYER_VY(s0)
    lw      t0, ST_PLAYER_Y(s0)
    add     s5, t0, s6
    lw      s7, ST_PLAYER_X(s0)
    bltz    s6, player_move_up

    # Falling/standing: sample both bottom corners.
    addi    a0, s7, 1
    addi    a1, s5, PLAYER_HEIGHT
    call    tile_class_at
    mv      s8, a0
    li      t0, COLLISION_HAZARD
    beq     s8, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     s8, t0, player_hit_goal
    addi    a0, s7, PLAYER_WIDTH-2
    addi    a1, s5, PLAYER_HEIGHT
    call    tile_class_at
    li      t0, COLLISION_HAZARD
    beq     a0, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     a0, t0, player_hit_goal
    li      t0, COLLISION_SOLID
    beq     s8, t0, player_landed
    beq     a0, t0, player_landed
    sw      s5, ST_PLAYER_Y(s0)
    sw      zero, ST_GROUNDED(s0)
    j       player_post_move

player_landed:
    addi    t0, s5, PLAYER_HEIGHT
    srli    t0, t0, 4
    slli    t0, t0, 4
    addi    t0, t0, -PLAYER_HEIGHT
    sw      t0, ST_PLAYER_Y(s0)
    sw      zero, ST_PLAYER_VY(s0)
    li      t0, 1
    sw      t0, ST_GROUNDED(s0)
    j       player_post_move

player_move_up:
    addi    a0, s7, 1
    mv      a1, s5
    call    tile_class_at
    mv      s8, a0
    li      t0, COLLISION_HAZARD
    beq     s8, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     s8, t0, player_hit_goal
    addi    a0, s7, PLAYER_WIDTH-2
    mv      a1, s5
    call    tile_class_at
    li      t0, COLLISION_HAZARD
    beq     a0, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     a0, t0, player_hit_goal
    li      t0, COLLISION_SOLID
    beq     s8, t0, player_head_hit
    beq     a0, t0, player_head_hit
    sw      s5, ST_PLAYER_Y(s0)
    sw      zero, ST_GROUNDED(s0)
    j       player_post_move
player_head_hit:
    srli    t0, s5, 4
    addi    t0, t0, 1
    slli    t0, t0, 4
    sw      t0, ST_PLAYER_Y(s0)
    sw      zero, ST_PLAYER_VY(s0)
    sw      zero, ST_GROUNDED(s0)

player_post_move:
    # Center-foot sample catches a one-tile hazard and the goal pole.
    lw      a0, ST_PLAYER_X(s0)
    addi    a0, a0, 6
    lw      a1, ST_PLAYER_Y(s0)
    addi    a1, a1, PLAYER_HEIGHT-1
    call    tile_class_at
    li      t0, COLLISION_HAZARD
    beq     a0, t0, player_hit_hazard
    li      t0, COLLISION_SPECIAL
    beq     a0, t0, player_hit_goal
    lw      t0, ST_PLAYER_Y(s0)
    li      t1, 240
    blt     t1, t0, player_hit_hazard
    j       player_update_done

player_hit_hazard:
    call    set_dead
    j       player_update_done
player_hit_goal:
    call    set_win
player_update_done:
    lw      s8, 12(sp)
    lw      s7, 16(sp)
    lw      s6, 20(sp)
    lw      s5, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret


# ---------------------------------------------------------------------------
# Enemies.  Direction, ledge checks, player overlap and stomp decisions all
# execute as ordinary RV32I code once per frame.
# ---------------------------------------------------------------------------
update_enemies:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    a0, s0, ENEMY0
    call    update_enemy_one
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, update_enemies_done
    addi    a0, s0, ENEMY1
    call    update_enemy_one
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, update_enemies_done
    addi    a0, s0, ENEMY2
    call    update_enemy_one
update_enemies_done:
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# a0 points to one ENEMY structure.
update_enemy_one:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s5, 24(sp)
    sw      s6, 20(sp)
    sw      s7, 16(sp)
    sw      s8, 12(sp)
    sw      s9, 8(sp)
    mv      s5, a0
    lw      t0, ENEMY_ACTIVE(s5)
    beqz    t0, enemy_done
    lw      s6, ENEMY_X(s5)
    lw      s7, ENEMY_Y(s5)
    lw      s8, ENEMY_DIR(s5)
    add     s9, s6, s8

    # Reverse at a wall.
    mv      a0, s9
    bltz    s8, enemy_front_ready
    addi    a0, a0, 11
enemy_front_ready:
    addi    a1, s7, 14
    call    tile_class_at
    li      t0, COLLISION_SOLID
    beq     a0, t0, enemy_reverse

    # Reverse before walking into a pit or onto a non-solid special tile.
    addi    a0, s9, 6
    addi    a1, s7, 16
    call    tile_class_at
    li      t0, COLLISION_SOLID
    bne     a0, t0, enemy_reverse
    sw      s9, ENEMY_X(s5)

    # Alternate the software animation tag every eight observed frames.
    lw      t0, ST_FRAME_LAST(s0)
    srli    t0, t0, 3
    andi    t0, t0, 1
    sw      t0, ENEMY_ANIM(s5)

    # Axis-aligned overlap with the player.
    lw      t0, ST_PLAYER_X(s0)
    sub     t1, t0, s9
    bgez    t1, enemy_dx_ready
    neg     t1, t1
enemy_dx_ready:
    li      t2, 12
    bge     t1, t2, enemy_done
    lw      t0, ST_PLAYER_Y(s0)
    sub     t1, t0, s7
    bgez    t1, enemy_dy_ready
    neg     t1, t1
enemy_dy_ready:
    li      t2, 15
    bge     t1, t2, enemy_done

    # A descending player whose lower body is above the enemy stomps it.
    lw      t0, ST_PLAYER_VY(s0)
    blez    t0, enemy_hurts_player
    lw      t0, ST_PLAYER_Y(s0)
    addi    t0, t0, 10
    addi    t1, s7, 8
    bge     t0, t1, enemy_hurts_player
    sw      zero, ENEMY_ACTIVE(s5)
    li      t0, -5
    sw      t0, ST_PLAYER_VY(s0)
    lw      t0, ST_SCORE(s0)
    addi    t0, t0, 100
    sw      t0, ST_SCORE(s0)
    j       enemy_done

enemy_hurts_player:
    call    set_dead
    j       enemy_done
enemy_reverse:
    neg     s8, s8
    sw      s8, ENEMY_DIR(s5)
enemy_done:
    lw      s9, 8(sp)
    lw      s8, 12(sp)
    lw      s7, 16(sp)
    lw      s6, 20(sp)
    lw      s5, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret


# Count exactly sixty firmware updates per game second.
update_timer:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    lw      t0, ST_SECOND_DIV(s0)
    addi    t0, t0, 1
    li      t1, FRAME_HZ
    blt     t0, t1, update_timer_store
    sw      zero, ST_SECOND_DIV(s0)
    lw      t0, ST_TIME(s0)
    beqz    t0, update_timer_expired
    addi    t0, t0, -1
    sw      t0, ST_TIME(s0)
    bnez    t0, update_timer_done
update_timer_expired:
    call    set_dead
    j       update_timer_done
update_timer_store:
    sw      t0, ST_SECOND_DIV(s0)
update_timer_done:
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret


# Select one of the original sprite tiles from CPU-visible state.
update_animation:
    lw      t0, ST_GAME_STATE(s0)
    bnez    t0, animation_nonplay
    lw      t0, ST_GROUNDED(s0)
    beqz    t0, animation_jump
    lw      t0, ST_PLAYER_VX(s0)
    beqz    t0, animation_idle
    lw      t0, ST_FRAME_LAST(s0)
    srli    t0, t0, 3
    andi    t0, t0, 1
    beqz    t0, animation_idle
    li      t0, TILE_PLAYER_WALK
    sw      t0, ST_ANIMATION(s0)
    ret
animation_jump:
    li      t0, TILE_PLAYER_JUMP
    sw      t0, ST_ANIMATION(s0)
    ret
animation_nonplay:
    li      t1, STATE_DEAD
    beq     t0, t1, animation_jump
animation_idle:
    li      t0, TILE_PLAYER_IDLE
    sw      t0, ST_ANIMATION(s0)
    ret


# Camera follows after x=96 and is clamped to the level's right edge.
update_camera:
    lw      t0, ST_PLAYER_X(s0)
    addi    t0, t0, -96
    bgez    t0, camera_not_negative
    li      t0, 0
camera_not_negative:
    li      t1, CAMERA_MAX
    bge     t1, t0, camera_ready
    mv      t0, t1
camera_ready:
    sw      t0, ST_CAMERA_X(s0)
    ret


# ---------------------------------------------------------------------------
# Render producer.  This writes only the inactive descriptor/control bank;
# FRAME_COMMIT atomically publishes it at vblank.
# ---------------------------------------------------------------------------
render_frame:
    addi    sp, sp, -4
    sw      ra, 0(sp)

    lw      t0, ST_CAMERA_X(s0)
    sw      t0, VGA_SCROLL_X-VGA_BASE(s2)
    lw      t0, ST_SCORE(s0)
    sw      t0, VGA_HUD_SCORE-VGA_BASE(s2)
    lw      t0, ST_TIME(s0)
    sw      t0, VGA_HUD_TIME-VGA_BASE(s2)
    lw      t0, ST_GAME_STATE(s0)
    lw      t1, ST_ANIMATION(s0)
    slli    t1, t1, 8
    or      t0, t0, t1
    lw      t1, ST_LIVES(s0)
    slli    t1, t1, 16
    or      t0, t0, t1
    sw      t0, VGA_GAME_STATUS-VGA_BASE(s2)

    # Slot 0: player.  Facing direction is encoded with hflip.
    li      a0, 0
    lw      a1, ST_PLAYER_X(s0)
    lw      a2, ST_PLAYER_Y(s0)
    lw      t0, ST_ANIMATION(s0)
    slli    a3, t0, 8
    ori     a3, a3, SPRITE_ENABLE
    lw      t0, ST_PLAYER_VX(s0)
    bgez    t0, render_player_facing_ready
    ori     a3, a3, SPRITE_HFLIP
render_player_facing_ready:
    lw      a4, ST_FRAME_LAST(s0)
    call    write_sprite

    # Slots 1..3: software-controlled enemies.
    li      a0, 1
    addi    t4, s0, ENEMY0
    lw      a1, ENEMY_X(t4)
    lw      a2, ENEMY_Y(t4)
    lw      t0, ENEMY_ACTIVE(t4)
    beqz    t0, render_enemy0_off
    li      a3, (TILE_ENEMY_A << 8) | SPRITE_ENABLE
    lw      t0, ENEMY_DIR(t4)
    bgez    t0, render_enemy0_attr_ready
    ori     a3, a3, SPRITE_HFLIP
    j       render_enemy0_attr_ready
render_enemy0_off:
    li      a3, 0
render_enemy0_attr_ready:
    lw      a4, ENEMY_ANIM(t4)
    call    write_sprite

    li      a0, 2
    addi    t4, s0, ENEMY1
    lw      a1, ENEMY_X(t4)
    lw      a2, ENEMY_Y(t4)
    lw      t0, ENEMY_ACTIVE(t4)
    beqz    t0, render_enemy1_off
    li      a3, (TILE_ENEMY_B << 8) | SPRITE_ENABLE
    lw      t0, ENEMY_DIR(t4)
    bgez    t0, render_enemy1_attr_ready
    ori     a3, a3, SPRITE_HFLIP
    j       render_enemy1_attr_ready
render_enemy1_off:
    li      a3, 0
render_enemy1_attr_ready:
    lw      a4, ENEMY_ANIM(t4)
    call    write_sprite

    li      a0, 3
    addi    t4, s0, ENEMY2
    lw      a1, ENEMY_X(t4)
    lw      a2, ENEMY_Y(t4)
    lw      t0, ENEMY_ACTIVE(t4)
    beqz    t0, render_enemy2_off
    li      a3, (TILE_ENEMY_A << 8) | SPRITE_ENABLE
    lw      t0, ENEMY_DIR(t4)
    bgez    t0, render_enemy2_attr_ready
    ori     a3, a3, SPRITE_HFLIP
    j       render_enemy2_attr_ready
render_enemy2_off:
    li      a3, 0
render_enemy2_attr_ready:
    lw      a4, ENEMY_ANIM(t4)
    call    write_sprite

    # Slot 4 is a decorative goal flag; win detection still reads tile class.
    li      a0, 4
    li      a1, 1424
    li      a2, 72
    li      a3, (TILE_GOAL_SPRITE << 8) | SPRITE_ENABLE
    li      a4, 0x474f414c           # "GOAL" debug tag
    call    write_sprite

    # Explicitly disable the remaining slots in whichever bank is shadow now.
    addi    t0, s3, 84               # slot 5 ATTR
    li      t1, 11
render_disable_loop:
    sw      zero, 0(t0)
    addi    t0, t0, SPRITE_STRIDE
    addi    t1, t1, -1
    bnez    t1, render_disable_loop

    # LEDs expose state in [7:6] and the low six score bits for board debug.
    lw      t0, ST_SCORE(s0)
    andi    t0, t0, 0x3f
    lw      t1, ST_GAME_STATE(s0)
    slli    t1, t1, 6
    or      t0, t0, t1
    sw      t0, SYS_DEBUG_LEDS-SYS_BASE(s1)

    li      t0, 1
    sw      t0, VGA_FRAME_COMMIT-VGA_BASE(s2)
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# write_sprite(slot=a0, world_x=a1, logical_y=a2, attr=a3, tag=a4)
write_sprite:
    slli    t0, a0, 4
    add     t0, t0, s3
    slli    t1, a2, 16
    slli    t2, a1, 16
    srli    t2, t2, 16
    or      t1, t1, t2
    sw      t1, SPRITE_XY(t0)
    sw      a3, SPRITE_ATTR(t0)
    sw      a4, SPRITE_TAG(t0)
    ret
