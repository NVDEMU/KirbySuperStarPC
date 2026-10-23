# Kirby Super Star Recomp

A native recompilation of **Kirby Super Star** (USA), built on
[snesrecomp](https://github.com/RetroPortingToolKit/snesrecomp).

Kirby Super Star, released as Kirby's Fun Pak in PAL regions, is a 1996 anthology platform game developed by HAL Laboratory and published by Nintendo for the Super Nintendo Entertainment System. It is part of the Kirby series of video games by HAL Laboratory.

_Description from [Wikipedia](https://en.wikipedia.org/wiki/Kirby_Super_Star), CC BY-SA 4.0._

> **You must legally own a copy of the game.** No ROM data is distributed with
> this project, in the repository or in any release. The recompiled C is
> generated locally from your own copy and is never committed.

## Status

The local manual build renders correctly across the tested graphics modes.
The standard platform ZIPs remain setup/update packs. The native release assets
(`.dmg` / `.app`, Windows `.exe`, Linux `.AppImage`) become **playable builds**
when the repository Actions secret `KIRBY_ROM_URL` is configured to a direct
download URL for the project's exact, verified ROM. The build downloads that
ROM only inside the temporary CI runner, verifies it, generates the game code,
compiles each platform natively, and deletes the ROM before packaging. The
optional `KIRBY_ROM_TOKEN` secret is sent as a Bearer token for private hosts.
Without `KIRBY_ROM_URL`, the native assets remain the existing setup launchers.

No ROM image, generated C source files, or machine-specific ROM path is shipped.
Playable native executables contain the compiled recompiled program and still
require the player's own verified ROM at runtime. The updater's portable ZIPs
remain setup packs so existing in-app update behavior is preserved.

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

## Package the manual build as a macOS app

When the **manual build on your Mac has already been confirmed to render
correctly**, package that exact executable directly as a Finder-launchable
app, DMG, and app ZIP:

```sh
bash scripts/package_playable_macos_app.sh build
```

This is a packaging-only step: it does **not** rerun ROM-to-C generation or
compile C. It checks that `build/KirbySuperStarSNESRecomp` is a playable
macOS executable, then wraps its built runtime assets in a real `.app`
and `.dmg`. The app launches the already-built game directly and does not
show the setup-host's **Generate & rebuild** first-run screen. Files are
written to `dist/`.

The app stores writable runtime files separately and attempts to carry over
the ROM path, settings, saves, and installed mods from the previous setup-pack
data folder. It does not bundle the ROM, local `rom.cfg`, save files, or
installed mod state. **This manual app is built from one local ROM-derived
executable**; it is not an artifact the public Nightly workflow can recreate
without that local manual build. The official Nightly remains a setup pack.

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
