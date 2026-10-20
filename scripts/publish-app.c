// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>

// Publish a fully signed bundle in one filesystem operation. On update, the old
// bundle moves to the staging path and can be removed by the caller afterwards.
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: publish-app STAGED_APP DESTINATION_APP\n");
        return 2;
    }
    struct stat staged, destination;
    if (lstat(argv[1], &staged) != 0) { perror("staged app"); return 1; }
    if (!S_ISDIR(staged.st_mode)) {
        fprintf(stderr, "The staged app must be a directory, not a symbolic link.\n");
        return 1;
    }
    if (lstat(argv[2], &destination) == 0) {
        if (!S_ISDIR(destination.st_mode)) {
            fprintf(stderr, "The destination must be a directory, not a symbolic link.\n");
            return 1;
        }
        if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
            perror("atomic app exchange");
            return 1;
        }
    } else {
        if (errno != ENOENT) { perror("destination app"); return 1; }
        if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
            perror("publish new app");
            return 1;
        }
    }
    return 0;
}
