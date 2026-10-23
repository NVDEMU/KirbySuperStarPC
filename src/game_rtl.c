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
#include "snes/snes.h"
#include "snes/spc.h"

extern CpuState g_cpu;
extern Snes *g_snes;

/* CI-only diagnostics for the current black-frame regression. These hooks are
 * dormant unless the release smoke test explicitly enables them. */
static unsigned s_kirby_diagnostic_frame;

static uint16_t kirby_diag_read16(uint32_t address)
{
    return (uint16_t)(snes_read(g_snes, address) |
                      ((uint16_t)snes_read(g_snes, address + 1) << 8));
}

static void kirby_dump_wait_loop(void)
{
    if (!g_snes)
        return;

    /* Decode the observed short wait-loop without logging raw ROM bytes into
     * public CI logs. The operands say which hardware/register it polls. */
    const uint32_t pc = 0x00D5E9;
    const uint16_t stz = kirby_diag_read16(pc + 1);
    const uint8_t lda1 = snes_read(g_snes, pc + 4);
    const uint16_t sta1 = kirby_diag_read16(pc + 6);
    const uint8_t lda2 = snes_read(g_snes, pc + 9);
    const uint16_t sta2 = kirby_diag_read16(pc + 11);
    const uint16_t sta3 = kirby_diag_read16(pc + 15);
    const uint16_t cmp = kirby_diag_read16(pc + 18);
    const int8_t branch = (int8_t)snes_read(g_snes, pc + 21);

    fprintf(stderr,
            "[kirby_boot] loop $00D5E9: STZ $%04X; LDA #$%02X; STA $%04X; "
            "LDA #$%02X; STA $%04X; DEC A; STA $%04X; CMP $%04X; "
            "BNE %+d\n",
            stz, lda1, sta1, lda2, sta2, sta3, cmp, branch);
    fprintf(stderr,
            "[kirby_boot] PPU at wait: INIDISP=%02X BGMODE=%02X "
            "TM=%02X TS=%02X VRAM0=%04X CGRAM0=%04X "
            "h=%u v=%u in_vblank=%u nmi=%u\n",
            (unsigned)g_snes->ppu->inidisp,
            (unsigned)g_snes->ppu->bgmode,
            (unsigned)g_snes->ppu->screenEnabled[0],
            (unsigned)g_snes->ppu->screenEnabled[1],
            (unsigned)g_snes->ppu->vram[0],
            (unsigned)g_snes->ppu->cgram[0],
            (unsigned)g_snes->hPos, (unsigned)g_snes->vPos,
            (unsigned)g_snes->inVblank, (unsigned)g_snes->nmiEnabled);
    fprintf(stderr,
            "[kirby_boot] APU wait: SPC_PC=%04X stopped=%u IPL_ROM=%u "
            "IN=%02X,%02X,%02X,%02X OUT=%02X,%02X,%02X,%02X "
            "apu_cycles=%llu port_clock=%llu catchup=%.1f cpu_left=%u\n",
            g_snes->apu && g_snes->apu->spc ? (unsigned)g_snes->apu->spc->pc : 0u,
            g_snes->apu && g_snes->apu->spc ? (unsigned)g_snes->apu->spc->stopped : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->romReadable : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->inPorts[0] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->inPorts[1] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->inPorts[2] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->inPorts[3] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->outPorts[0] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->outPorts[1] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->outPorts[2] : 0u,
            g_snes->apu ? (unsigned)g_snes->apu->outPorts[3] : 0u,
            (unsigned long long)(g_snes->apu ? g_snes->apu->cycles : 0u),
            (unsigned long long)(g_snes->apu ? g_snes->apu->portClock : 0u),
            g_snes->apu ? g_snes->apuCatchupCycles : 0.0,
            g_snes->apu ? (unsigned)g_snes->apu->cpuCyclesLeft : 0u);
}

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

    if (phase[0] == 'a' && frame == 1)
        kirby_dump_wait_loop();
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
