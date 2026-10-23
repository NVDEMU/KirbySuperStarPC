#!/usr/bin/env python3
"""Apply Kirby's SA-1/APU boot fix to the pinned snesrecomp checkout.

These exact replacements are idempotent, including a partly patched local
checkout; unexpected framework source changes fail with a useful message.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str, label: str) -> bool:
    text = path.read_text(encoding="utf-8")
    old_count = text.count(old)
    new_count = text.count(new)
    if old_count == 1 and new_count == 0:
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"patched: {path.relative_to(ROOT)} ({label})")
        return True
    if old_count == 0 and new_count == 1:
        print(f"already applied: {path.relative_to(ROOT)} ({label})")
        return False
    raise RuntimeError(
        f"{label}: expected exactly one old or new form in {path}; "
        f"found old={old_count}, new={new_count}. "
        "The pinned framework source may have changed."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--framework-root", type=Path, required=True)
    args = parser.parse_args()
    framework = args.framework_root.resolve()

    header = framework / "runner/src/snes/interp_bridge.h"
    bridge = framework / "runner/src/snes/interp_bridge.c"
    tests = framework / "tests/interp816/bridge_test.c"
    for required in (header, bridge, tests):
        if not required.is_file():
            raise FileNotFoundError(f"Required snesrecomp file not found: {required}")

    global ROOT
    ROOT = framework

    replace_once(
        header,
        """    bool frame_timeline_active, bool is_sa1, bool mapped_extended_frame) {
  return frame_timeline_active && (is_sa1 || mapped_extended_frame);
}""",
        """    bool frame_timeline_active, bool is_sa1, bool mapped_extended_frame,
    bool apu_port_time_mapped) {
  return frame_timeline_active &&
         (is_sa1 ? apu_port_time_mapped : mapped_extended_frame);
}""",
        "require mapped APU port time before SA-1 absolute sync",
    )
    replace_once(
        bridge,
        """    if (interp_bridge_use_absolute_apu_timeline(
            rtl_apu_frame_timeline_active(),
            g_snes && cart_has_sa1(g_snes->cart),
            rtl_apu_extended_frame_timing() &&
            g_snes && g_snes->apu && g_snes->apu->portTimeValid)) {""",
        """    if (interp_bridge_use_absolute_apu_timeline(
            rtl_apu_frame_timeline_active(),
            g_snes && cart_has_sa1(g_snes->cart),
            rtl_apu_extended_frame_timing() &&
            g_snes && g_snes->apu && g_snes->apu->portTimeValid,
            g_snes && g_snes->apu && g_snes->apu->portTimeValid)) {""",
        "APU flush timeline arguments",
    )
    replace_once(
        bridge,
        """                                !interp_bridge_use_absolute_apu_timeline(
                                    rtl_apu_frame_timeline_active(),
                                    cart_has_sa1(g_snes->cart), false);""",
        """                                !interp_bridge_use_absolute_apu_timeline(
                                    rtl_apu_frame_timeline_active(),
                                    cart_has_sa1(g_snes->cart), false,
                                    g_snes && g_snes->apu && g_snes->apu->portTimeValid);""",
        "interpreter idle-loop timeline arguments",
    )
    replace_once(
        bridge,
        """                    !interp_bridge_use_absolute_apu_timeline(
                        rtl_apu_frame_timeline_active(),
                        g_snes && cart_has_sa1(g_snes->cart), false)) {""",
        """                    !interp_bridge_use_absolute_apu_timeline(
                        rtl_apu_frame_timeline_active(),
                        g_snes && cart_has_sa1(g_snes->cart), false,
                        g_snes && g_snes->apu && g_snes->apu->portTimeValid)) {""",
        "interpreter batched-APU timeline arguments",
    )

    calls = (
        ("interp_bridge_use_absolute_apu_timeline(false, false, false)",
         "interp_bridge_use_absolute_apu_timeline(false, false, false, false)"),
        ("interp_bridge_use_absolute_apu_timeline(true, false, false)",
         "interp_bridge_use_absolute_apu_timeline(true, false, false, false)"),
        ("interp_bridge_use_absolute_apu_timeline(false, true, false)",
         "interp_bridge_use_absolute_apu_timeline(false, true, false, false)"),
        ("interp_bridge_use_absolute_apu_timeline(true, true, false)",
         "interp_bridge_use_absolute_apu_timeline(true, true, false, true)"),
        ("interp_bridge_use_absolute_apu_timeline(true, false, true)",
         "interp_bridge_use_absolute_apu_timeline(true, false, true, false)"),
        ("interp_bridge_use_absolute_apu_timeline(false, false, true)",
         "interp_bridge_use_absolute_apu_timeline(false, false, true, false)"),
    )
    for old, new in calls:
        replace_once(tests, old, new, "APU timeline policy unit test")

    print("Kirby SA-1/APU boot-sync fix is active.")
    return 0


ROOT = Path.cwd()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"apply_kirby_apu_timeline_fix: error: {exc}", file=sys.stderr)
        raise SystemExit(1)
