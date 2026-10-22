#!/usr/bin/env python3
"""Add a guarded Kirby Nightly updater action to the shared recomp-ui launcher."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

SOURCE = Path("src/common/backends/imgui/launcher_imgui.cpp")
INCLUDE_ANCHOR = '#include "launcher_sdlcompat.h"   // pulls the right SDL header + event shim'
DRAW_ANCHOR = "void draw_dashboard(LauncherModel* m, const LauncherTheme& th, int logical_w) {"
END_ANCHOR = "\n}\n\n// Trim a path from the LEFT"
HELPER_MARKER = "KIRBY_NIGHTLY_UPDATER_HELPER"
BUTTON_MARKER = "KIRBY_NIGHTLY_UPDATER_BUTTON"
INCLUDE_MARKER = "KIRBY_NIGHTLY_UPDATER_PLATFORM_HEADERS"

INCLUDES = r'''
// KIRBY_NIGHTLY_UPDATER_PLATFORM_HEADERS
#if defined(_WIN32)
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  #include <windows.h>
#else
  #include <sys/types.h>
  #include <unistd.h>
#endif
'''

HELPER = r'''
// KIRBY_NIGHTLY_UPDATER_HELPER
#if defined(_WIN32) || defined(__APPLE__)
static std::string s_kirby_update_status;

static bool launch_kirby_nightly_updater(std::string* error) {
    const char* base_raw = SDL_GetBasePath();
    if (!base_raw || !base_raw[0]) {
        if (error) *error = "Could not locate the setup-pack folder.";
        return false;
    }
    const std::filesystem::path base = std::filesystem::path(base_raw).lexically_normal();
    std::filesystem::path root = base;
    const std::filesystem::path parent = (base / "..").lexically_normal();
    // A generated build lives in <setup-pack>/build. Prefer the parent pack
    // whenever it has provenance; a local build/update helper alone is not
    // enough to make the build directory a safe installation target.
    if (!std::filesystem::is_regular_file(root / "update" / "BUILD_PROVENANCE.json") &&
        std::filesystem::is_regular_file(parent / "update" / "BUILD_PROVENANCE.json")) {
        root = parent;
    }
    const std::filesystem::path script = root / "update" / "updater.py";
    if (!std::filesystem::is_regular_file(script) ||
        !std::filesystem::is_regular_file(root / "update" / "BUILD_PROVENANCE.json")) {
        if (error) *error =
            "This is not an official packaged setup pack with updater metadata. Download the newest Kirby Nightly setup pack manually.";
        return false;
    }

#if defined(_WIN32)
    std::filesystem::path python = root / "toolchain" / "python" / "python.exe";
    if (!std::filesystem::is_regular_file(python)) {
        python = root / "toolchain" / "python" / "bin" / "python.exe";
    }
    // Developer builds may not embed the release toolchain; let CreateProcess
    // resolve an installed Python from PATH in that case.
    if (!std::filesystem::is_regular_file(python)) python = "python.exe";
    const std::wstring python_w = python.wstring();
    const std::wstring script_w = script.wstring();
    const std::wstring root_w = root.wstring();
    std::wstring command = L"\"" + python_w + L"\" \"" + script_w +
        L"\" --install-root \"" + root_w + L"\" --parent-pid " +
        std::to_wstring(GetCurrentProcessId());
    std::vector<wchar_t> buffer(command.begin(), command.end());
    buffer.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE,
                        DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
                        nullptr, root_w.c_str(), &startup, &process)) {
        if (error) *error = "Windows could not start the updater helper. Check that Python is installed.";
        return false;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
#elif defined(__APPLE__)
    std::filesystem::path python = root / "toolchain" / "python" / "bin" / "python3";
    if (!std::filesystem::is_regular_file(python)) python = "/usr/bin/python3";
    if (!std::filesystem::is_regular_file(python)) {
        if (error) *error = "Python 3 was not found. Install the build tools or download the latest Nightly manually.";
        return false;
    }
    const std::string python_s = python.string();
    const std::string script_s = script.string();
    const std::string root_s = root.string();
    const std::string pid_s = std::to_string(static_cast<long long>(getpid()));
    const pid_t child = fork();
    if (child < 0) {
        if (error) *error = "Could not start the updater helper.";
        return false;
    }
    if (child == 0) {
        (void)setsid();
        execl(python_s.c_str(), python_s.c_str(), script_s.c_str(),
              "--install-root", root_s.c_str(), "--parent-pid", pid_s.c_str(),
              static_cast<char*>(nullptr));
        _exit(127);
    }
    return true;
#endif
}
#endif
'''

BUTTON = r'''
    // KIRBY_NIGHTLY_UPDATER_BUTTON
#if defined(_WIN32) || defined(__APPLE__)
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextColored(col(th.accent2), "Kirby Super Star Recomp Updates");
    ImGui::TextWrapped("Check the official NVDEMU Nightly release. Downloads are verified with SHA-256; your ROM selection, settings, mod preferences, and local generated files are preserved.");
    if (ImGui::Button("Check for Updates", ImVec2(px(220.0f), px(34.0f)))) {
        std::string error;
        if (launch_kirby_nightly_updater(&error)) {
            s_kirby_update_status =
                "Updater opened. Follow its prompts and close Kirby Super Star Recomp when asked.";
        } else {
            s_kirby_update_status = error;
        }
    }
    if (!s_kirby_update_status.empty()) {
        ImGui::TextWrapped("%s", s_kirby_update_status.c_str());
    }
#else
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextColored(col(th.accent2), "Kirby Super Star Recomp Updates");
    ImGui::TextWrapped("Linux updates are installed by downloading the newest linux-x64 setup ZIP from the official GitHub Nightly release and unpacking it over your setup-pack folder.");
#endif
'''


def fail(message: str, code: int = 2) -> int:
    print(message, file=sys.stderr)
    return code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ui-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    path = args.ui_root / SOURCE
    if not path.is_file():
        return fail(f"Required recomp-ui launcher source is missing: {path}")
    text = path.read_text(encoding="utf-8")

    if HELPER_MARKER in text:
        required = (BUTTON_MARKER, INCLUDE_MARKER, 'ImGui::Button("Check for Updates"')
        missing = [item for item in required if item not in text]
        if missing:
            return fail("Updater launcher patch is incomplete; missing: " + ", ".join(missing), 3)
        print("Kirby Nightly updater launcher patch is already applied.")
        return 0
    if args.check:
        return fail("Kirby Nightly updater launcher patch has not been applied.", 1)

    for anchor, label in ((INCLUDE_ANCHOR, "header"),
                          (DRAW_ANCHOR, "dashboard"),
                          (END_ANCHOR, "dashboard end")):
        count = text.count(anchor)
        if count != 1:
            return fail(f"Pinned recomp-ui {label} anchor changed (expected 1 match, found {count}).")

    text = text.replace(INCLUDE_ANCHOR, INCLUDE_ANCHOR + "\n" + INCLUDES, 1)
    text = text.replace(DRAW_ANCHOR, HELPER + "\n" + DRAW_ANCHOR, 1)
    text = text.replace(END_ANCHOR, "\n" + BUTTON + END_ANCHOR, 1)
    if (HELPER_MARKER not in text or BUTTON_MARKER not in text or
            INCLUDE_MARKER not in text or text.count('ImGui::Button("Check for Updates"') != 1):
        return fail("Updater launcher patch failed its post-write checks.", 4)
    path.write_text(text, encoding="utf-8")
    print("Applied the Kirby Nightly updater button.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
