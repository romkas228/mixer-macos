// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include <stdio.h>

// Publish a complete release once. Never merge with or replace an existing release.
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: publish-release CANDIDATE DESTINATION\n");
        return 2;
    }
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
        perror("publish release without replacement");
        return 1;
    }
    return 0;
}
