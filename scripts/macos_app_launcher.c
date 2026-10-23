#define _DARWIN_C_SOURCE 1
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX];
    uint32_t executable_size = (uint32_t)sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0) {
        fputs("Kirby Super Star Recomp: executable path is too long.\n", stderr);
        return 127;
    }

    char resolved[PATH_MAX];
    if (realpath(executable, resolved) == NULL) {
        perror("Kirby Super Star Recomp: resolving app executable");
        return 127;
    }

    char *separator = strrchr(resolved, '/');
    if (separator == NULL) {
        fputs("Kirby Super Star Recomp: invalid app executable path.\n", stderr);
        return 127;
    }
    *separator = '\0';

    char script_path[PATH_MAX];
    int written = snprintf(script_path, sizeof(script_path),
                           "%s/../Resources/launcher.sh", resolved);
    if (written < 0 || (size_t)written >= sizeof(script_path)) {
        fputs("Kirby Super Star Recomp: launcher script path is too long.\n", stderr);
        return 127;
    }
    if (access(script_path, R_OK) != 0) {
        perror("Kirby Super Star Recomp: locating Resources/launcher.sh");
        return 127;
    }

    char **child_argv = calloc((size_t)argc + 2, sizeof(*child_argv));
    if (child_argv == NULL) {
        perror("Kirby Super Star Recomp: allocating arguments");
        return 127;
    }
    child_argv[0] = (char *)"/bin/sh";
    child_argv[1] = script_path;
    for (int i = 1; i < argc; ++i) {
        child_argv[i + 1] = argv[i];
    }
    child_argv[argc + 1] = NULL;

    execv(child_argv[0], child_argv);
    perror("Kirby Super Star Recomp: launching app script");
    free(child_argv);
    return 127;
}
