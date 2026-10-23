/*
 * Kirby Super Star — per-game runtime glue.
 *
 * THIS FILE IS THE PORT. Everything else the scaffold produced is layout,
 * build wiring, and packaging; this is where the actual work happens.
 *
 * The framework does not, and cannot, drive an arbitrary SNES game on its
 * own. Two responsibilities always land on the game host:
 *
 *   1. Deciding what "one frame" means for THIS title, and returning from
 *      run_frame() at that boundary. A real ROM's reset vector never
 *      returns — it enters a main loop that waits on vblank — so somebody
 *      has to choose the yield point.
 *   2. Delivering NMI/IRQ at the hardware edge (see
 *      snesrecomp/docs/FRAME_MODEL_HOSTS.md).
 *
 * A new port starts on the framework's beam-aligned driver
 * (runner/src/beam_frame_driver.h): one frame is one PPU field, cut at the
 * beam's vblank edge; interrupts -- raster splits and a coprocessor's IRQ
 * line -- are taken where the beam latches them; parked time still runs the
 * beam, APU and coprocessors; and the field is rasterized from the raster
 * journal with real HDMA. It is the framework's, so a fix to it reaches this
 * port on a submodule pull.
 *
 * This file used to hold its own copy of a simpler driver: frames measured
 * from wherever the CPU last stopped, NMI delivered at an arbitrary beam
 * position, the field drawn with end-of-frame register state. A game that
 * uploads in vblank between INIDISP=$80 and $0F flickered black, and one
 * that chains raster splits fell apart. Replace these calls only for what
 * the driver does not do; MetalWarriorsSNESRecomp's src/mw_rtl.c and
 * GundamWingEndlessDuelSNESRecomp's src/game_rtl.c are developed examples of
 * title-specific drivers.
 */

#include "game_rtl.h"

#include <stdio.h>
#include <stdlib.h>

#include "beam_frame_driver.h"
#include "cpu_state.h"
#include "snes/interp_bridge.h"

extern CpuState g_cpu;

/* CI-only diagnostics for the current black-frame regression. These hooks are
 * dormant unless the release smoke test explicitly enables them. */
static unsigned s_kirby_diagnostic_frame;

static void kirby_boot_trace(unsigned frame, const char *phase)
{
    if (getenv("SNESRECOMP_KIRBY_BOOT_TRACE") == NULL || frame > 12)
        return;

    fprintf(stderr,
            "[kirby_boot] %s frame=%u resume_pc=%06X "
            "A=%04X X=%04X Y=%04X S=%04X D=%04X "
            "DB=%02X PB=%02X P=%02X master=%llu\n",
            phase, frame, (unsigned)interp_bridge_lle_resume_pc(),
            (unsigned)g_cpu.A, (unsigned)g_cpu.X, (unsigned)g_cpu.Y,
            (unsigned)g_cpu.S, (unsigned)g_cpu.D, (unsigned)g_cpu.DB,
            (unsigned)g_cpu.PB, (unsigned)g_cpu.P,
            (unsigned long long)g_cpu.master_cycles);
}

void GameRunOneFrame(void)
{
    const unsigned frame = ++s_kirby_diagnostic_frame;
    kirby_boot_trace(frame, "before");
    snes_beam_frame_driver_run_frame();
    kirby_boot_trace(frame, "after");

    if (getenv("SNESRECOMP_KIRBY_BOOT_TRACE") != NULL &&
        (frame == 1 || frame == 12)) {
        fprintf(stderr, "[kirby_boot] interpreter snapshot after frame %u\n", frame);
        interp_bridge_dump_recent(128, stderr);
    }
}

void GameDrawPpuFrame(void)
{
    snes_beam_frame_driver_draw_ppu_frame();
}

void GameSessionReset(void)
{
    /* Rematch / soft-return: clear anything that must not survive a new
     * session. recomp-ai-rules/NETPLAY.md §3 — sticky state that "has always
     * been fine" is the usual desync culprit, because single-player never
     * re-enters the boot path twice in one process. */
    snes_beam_frame_driver_reset();
}

const RtlGameInfo kGameInfo = {
    .title = "kirbysuperstar",
    .initialize = NULL,
    .run_frame = &GameRunOneFrame,
    .draw_ppu_frame = &GameDrawPpuFrame,
    .save_name_prefix = "save",
    .session_reset = &GameSessionReset,
};
