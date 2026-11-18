// SPDX-License-Identifier: GPL-3.0-or-later
// BO1 content installer additions. See ../../SteamAuth/UPSTREAM.md.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Open an existing installation root. Its final component must be a real
// directory, not a symbolic link. The caller owns the returned descriptor.
// Earlier absolute ancestors (for example iOS's /var alias) are OS-managed.
int bo1_steam_open_root(const char *path);

// Open a regular file beneath an already-open root. All relative components
// are walked with openat + O_NOFOLLOW. Reject absolute paths, empty components,
// . / .., backslashes, colons, control bytes, links and nonregular files.
// `create` makes missing parent directories and the leaf; `writing` requests
// read/write access. No sizing or data writes occur in this function.
// Files with multiple hard links are rejected even for a read-only open.
// Return an owned descriptor, or -1 with errno set.
int bo1_steam_open_file(int root_fd, const char *relative, int writing, int create);

// Create a relative directory (and parents), using the same no-follow walk.
// Return 0 on success, -1 with errno set on failure.
int bo1_steam_make_directory(int root_fd, const char *relative);

// Retained-directory operations for transactional publication. An empty
// relative directory duplicates root_fd; all other paths use the strict walk.
int bo1_steam_open_directory(int root_fd, const char *relative);
// 1 = regular single-link file, 0 = absent, -1 = unsafe path/type or error.
int bo1_steam_file_exists(int root_fd, const char *relative);
// Move a regular single-link file. Destination must be absent atomically.
int bo1_steam_move_file(int source_root, const char *source,
                      int destination_root, const char *destination);
// Atomic metadata replacement: destination may be absent or a regular
// single-link file. Source and destination parents are never followed.
int bo1_steam_replace_file(int source_root, const char *source,
                         int destination_root, const char *destination);
// Remove only a regular single-link file or an empty real directory.
// A missing leaf succeeds; unsafe parents/types fail with -1 + errno.
int bo1_steam_remove_file(int root_fd, const char *relative);
int bo1_steam_remove_directory(int root_fd, const char *relative);

#ifdef __cplusplus
}
#endif
