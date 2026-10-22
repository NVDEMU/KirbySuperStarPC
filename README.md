# Kirby Super Star Recomp

A native recompilation of **Kirby Super Star** (USA), built on
[snesrecomp](https://github.com/RetroPortingToolKit/snesrecomp).

Kirby Super Star, released as Kirby's Fun Pak in PAL regions, is a 1996 anthology platform game developed by HAL Laboratory and published by Nintendo for the Super Nintendo Entertainment System. It is part of the Kirby series of video games by HAL Laboratory.

_Description from [Wikipedia](https://en.wikipedia.org/wiki/Kirby_Super_Star), CC BY-SA 4.0._

> **You must legally own a copy of the game.** No ROM data is distributed with
> this project, in the repository or in any release. The recompiled C is
> generated locally from your own copy and is never committed.

## Status

The local build now renders correctly across the tested graphics modes. GitHub
releases are **setup packs**, not prebuilt game binaries: each pack contains the
setup host, recompiler and source tree, and the player generates the playable
game locally from their own verified ROM. ROM images and ROM-derived generated
C are never included in releases.

## ROM identity

| | |
|---|---|
| File | `Kirby Super Star (USA).sfc` |
| Publisher | Nintendo |
| Developer | HAL Laboratory |
| Year | 1996 |
| Mapping | sa1 |
| Region | USA (North America) |
| Coprocessor | SA-1 |
| CRC32 | `89d0f7dc` |
| SHA-256 | `4e095fbbdec4a16b075d7140385ff68b259870ca9e3357f076dfff7f3d1c4a62` |

`tools/regen.sh` refuses to run against anything else, so a mismatched
revision fails immediately instead of producing subtly wrong output.

## Build

```sh
git submodule update --init --recursive
bash tools/regen.sh --rom /path/to/Kirby Super Star (USA).sfc
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

The ROM does not have to live in the repository — keeping it on your own
drive is the better habit, and `SNESRECOMP_ROM` sets the path once for a
shell. Without either, `tools/regen.sh` finds `Kirby Super Star (USA).sfc` at the repo root,
then the path the setup wizard recorded in `rom.cfg`; `.gitignore` blocks
both from ever being committed.

`tools/regen.sh` verifies the ROM, generates `src/gen/*.c`, and re-syncs
`recomp/funcs.h`. Re-run it whenever you change anything under `recomp/`.

## Run

```sh
./build/KirbySuperStarSNESRecomp                     # launcher picks the ROM
./build/KirbySuperStarSNESRecomp /path/to/Kirby Super Star (USA).sfc # or name it and skip the launcher
```

With no ROM on the command line the build opens the recomp-ui launcher: a ROM
picker with a verification badge, plus display / audio / input settings. Your
choice is cached in `rom.cfg` beside the executable, so the next launch opens
on it and "Skip launcher on boot" makes it immediate. If the launcher is not
built in (`--no-recomp-ui`), the host falls back to a native file picker.

Either way the ROM is checked against the digests above before anything boots
— a dump that could not have produced this build is refused at the door rather
than mis-executing ten frames in.

## Layout

| Path | What lives there |
|---|---|
| `recomp/` | Analysis input: `bank*.cfg`, `symbols.toml`, generated `funcs.h` |
| `rom_identity.txt` | ROM digests — read by the build, `tools/regen.sh` and CI |
| `src/` | Host code you own: `main.c`, `game_rtl.c` |
| `src/gen/` | Generated C. Never committed — regenerate locally |
| `snesrecomp/` | Framework submodule (owns `lib/recomp-net`, `lib/retcomm-rbengine`) |
| `tools/` | `regen.sh` — the ROM → C pipeline |
| `scripts/` | `package_release.sh` — player-facing zip |
| `framework_pins.txt` | Exact framework commits this project was scaffolded against |

## Porting from here

The scaffold stops where the game-specific work starts. In rough order:

1. **Make it boot.** `src/game_rtl.c` holds the frame driver. It starts on
   the framework's beam-aligned driver (`snesrecomp/runner/src/beam_frame_driver.h`):
   one frame per PPU field, interrupts taken where the beam latches them,
   the field rasterized from the raster journal. A title whose main loop it
   does not fit replaces those calls with its own driver.
2. **Name things.** Add entries to `recomp/symbols.toml` as you identify
   routines, then re-run `tools/regen.sh`. Set `emit = true` to promote one
   into ahead-of-time analysis; leave it false to keep it interpreted.
   Regen synchronizes the marked blocks in each bank cfg, creating missing
   configs. Only proven variants become AOT code. See `recomp/README.md`.
3. **Resolve dispatch misses.** After every run, deal with unresolved
   indirect targets before anything else — they are the reason a port
   diverges, and they are cheap to fix early.
4. **Never synthesise a result** to get past uncovered code, and never edit
   `src/gen/` by hand. Fix the config or the framework and regenerate.

## Nightly updates

Official Windows and macOS setup packs include **Check for Updates** in the
launcher. It checks the `NVDEMU/KirbySuperStarPC` `Nightly` release, verifies
the downloaded ZIP against its published SHA-256 checksum, and waits for the
running game to close before installation. Your ROM selection, settings, mod
state, saves, and locally generated ROM-derived files are preserved.

Because each release is a setup pack, the updater reopens the setup host after
installing. Choose **Generate & rebuild** to rebuild the playable executable
from your own ROM and the updated source. Linux users can download the latest
`linux-x64` setup ZIP from the Nightly GitHub Release and unpack it over their
existing setup-pack folder; Linux in-app updating is not enabled.

## Multiplayer

Two players, one controller per port.

Netplay is built in: delay-sync by default, rollback available
(`SNES_NET_MODE=rollback`). See `snesrecomp/docs/RECOMP_NET.md` and
`snesrecomp/docs/ROLLBACK.md`.

## License

This project's own source is under the license in `LICENSE`. The framework
carries its own terms — see `snesrecomp/LICENSE` and
`snesrecomp/THIRD_PARTY_ATTRIBUTION.md`. Neither covers the game data, which
is not distributed here.
