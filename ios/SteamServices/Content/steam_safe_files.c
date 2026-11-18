// SPDX-License-Identifier: GPL-3.0-or-later
// BO1 content installer additions. See ../../SteamAuth/UPSTREAM.md.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#include "steam_safe_files.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BO1_STEAM_PATH_LIMIT 1024

static int fail_close(int fd, int saved_errno) {
  if (fd >= 0) close(fd);
  errno = saved_errno;
  return -1;
}

static int copy_relative(const char *relative, char *out) {
  if (!relative) { errno = EINVAL; return -1; }
  size_t length = strnlen(relative, BO1_STEAM_PATH_LIMIT);
  if (length == 0 || length >= BO1_STEAM_PATH_LIMIT || relative[0] == '/' ||
      relative[length - 1] == '/') { errno = EINVAL; return -1; }
  size_t components = 0;
  const char *begin = relative;
  for (const char *p = relative;; ++p) {
    unsigned char ch = (unsigned char)*p;
    if (ch && (ch < 0x20 || ch == 0x7f || ch == ':' || ch == '\\')) {
      errno = EINVAL; return -1;
    }
    if (ch == '/' || ch == 0) {
      size_t n = (size_t)(p - begin);
      if (n == 0 || (n == 1 && begin[0] == '.') ||
          (n == 2 && begin[0] == '.' && begin[1] == '.') ||
          ++components > 64) { errno = EINVAL; return -1; }
      begin = p + 1;
      if (!ch) break;
    }
  }
  memcpy(out, relative, length + 1);
  return 0;
}

int bo1_steam_open_root(const char *path) {
  if (!path || !*path) { errno = EINVAL; return -1; }
  // O_NOFOLLOW may otherwise be defeated by a trailing slash on some systems.
  size_t length = strlen(path);
  if (length > 1 && path[length - 1] == '/') { errno = EINVAL; return -1; }
  return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int child_directory(int parent, const char *name, int create) {
  if (create && mkdirat(parent, name, 0755) != 0 && errno != EEXIST) return -1;
  return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

// The caller supplies an immutable root descriptor; it is never closed here.
// Each walk owns its working descriptor, so concurrent chunks cannot change
// one another's directory position and a rename cannot redirect the walk.
static int walk_parent(int root_fd, char *path, char **leaf, int create) {
  int current = fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
  if (current < 0) return -1;
  char *part = path;
  for (char *slash; (slash = strchr(part, '/')) != NULL; part = slash + 1) {
    *slash = '\0';
    int next = child_directory(current, part, create);
    int saved = errno;
    close(current);
    if (next < 0) { errno = saved; return -1; }
    current = next;
  }
  *leaf = part;
  return current;
}

int bo1_steam_open_file(int root_fd, const char *relative, int writing, int create) {
  char path[BO1_STEAM_PATH_LIMIT];
  if (copy_relative(relative, path) != 0) return -1;
  char *leaf = NULL;
  int parent = walk_parent(root_fd, path, &leaf, create);
  if (parent < 0) return -1;
  // NONBLOCK ensures a malicious FIFO leaf cannot hang before fstat rejects it.
  int flags = (writing ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
  if (create) flags |= O_CREAT;
  int fd = openat(parent, leaf, flags, 0644);
  int saved = errno;
  close(parent);
  if (fd < 0) { errno = saved; return -1; }
  struct stat info;
  if (fstat(fd, &info) != 0) return fail_close(fd, errno);
  if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_size < 0)
    return fail_close(fd, EINVAL);
  return fd;
}

int bo1_steam_make_directory(int root_fd, const char *relative) {
  char path[BO1_STEAM_PATH_LIMIT];
  if (copy_relative(relative, path) != 0) return -1;
  char *leaf = NULL;
  int parent = walk_parent(root_fd, path, &leaf, 1);
  if (parent < 0) return -1;
  int fd = child_directory(parent, leaf, 1);
  int saved = errno;
  close(parent);
  if (fd < 0) { errno = saved; return -1; }
  close(fd);
  return 0;
}

int bo1_steam_open_directory(int root_fd, const char *relative) {
  if (relative && !*relative) return fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
  char path[BO1_STEAM_PATH_LIMIT];
  if (copy_relative(relative, path) != 0) return -1;
  char *leaf = NULL;
  int parent = walk_parent(root_fd, path, &leaf, 0);
  if (parent < 0) return -1;
  int fd = child_directory(parent, leaf, 0);
  int saved = errno;
  close(parent);
  if (fd < 0) errno = saved;
  return fd;
}

int bo1_steam_file_exists(int root_fd, const char *relative) {
  int fd = bo1_steam_open_file(root_fd, relative, 0, 0);
  if (fd < 0) return errno == ENOENT ? 0 : -1;
  close(fd);
  return 1;
}

static int regular_leaf(int parent, const char *leaf, int absent_allowed) {
  struct stat info;
  if (fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0)
    return absent_allowed && errno == ENOENT ? 0 : -1;
  if (!S_ISREG(info.st_mode) || info.st_nlink != 1) { errno = EINVAL; return -1; }
  return 0;
}

static int move_file(int source_root, const char *source, int destination_root,
                     const char *destination, int replace) {
  char from[BO1_STEAM_PATH_LIMIT], to[BO1_STEAM_PATH_LIMIT];
  if (copy_relative(source, from) != 0 || copy_relative(destination, to) != 0) return -1;
  char *source_leaf = NULL, *destination_leaf = NULL;
  int source_parent = walk_parent(source_root, from, &source_leaf, 0);
  if (source_parent < 0) return -1;
  if (regular_leaf(source_parent, source_leaf, 0) != 0)
    return fail_close(source_parent, errno);
  int destination_parent = walk_parent(destination_root, to, &destination_leaf, 1);
  if (destination_parent < 0) return fail_close(source_parent, errno);
  int result = -1;
  if (replace) {
    if (regular_leaf(destination_parent, destination_leaf, 1) == 0)
      result = renameat(source_parent, source_leaf, destination_parent, destination_leaf);
  } else {
    // Public Darwin API (stdio.h, iOS 10+). Never emulate exclusive rename by
    // checking existence then using a replace-capable rename.
#if defined(__APPLE__)
    result = renameatx_np(source_parent, source_leaf, destination_parent, destination_leaf, RENAME_EXCL);
#elif defined(__linux__)
    result = renameat2(source_parent, source_leaf, destination_parent, destination_leaf, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
#endif
  }
  int saved = errno;
  close(source_parent);
  close(destination_parent);
  if (result != 0) errno = saved;
  return result;
}

int bo1_steam_move_file(int source_root, const char *source,
                      int destination_root, const char *destination) {
  return move_file(source_root, source, destination_root, destination, 0);
}

int bo1_steam_replace_file(int source_root, const char *source,
                         int destination_root, const char *destination) {
  return move_file(source_root, source, destination_root, destination, 1);
}

static int remove_leaf(int root_fd, const char *relative, int directory) {
  char path[BO1_STEAM_PATH_LIMIT];
  if (copy_relative(relative, path) != 0) return -1;
  char *leaf = NULL;
  int parent = walk_parent(root_fd, path, &leaf, 0);
  if (parent < 0) return errno == ENOENT ? 0 : -1;
  struct stat info;
  if (fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0) {
    int saved = errno;
    close(parent);
    if (saved == ENOENT) return 0;
    errno = saved;
    return -1;
  }
  if (directory ? !S_ISDIR(info.st_mode) : (!S_ISREG(info.st_mode) || info.st_nlink != 1))
    return fail_close(parent, EINVAL);
  int result = unlinkat(parent, leaf, directory ? AT_REMOVEDIR : 0);
  int saved = errno;
  close(parent);
  if (result != 0) errno = saved;
  return result;
}

int bo1_steam_remove_file(int root_fd, const char *relative) {
  return remove_leaf(root_fd, relative, 0);
}

int bo1_steam_remove_directory(int root_fd, const char *relative) {
  return remove_leaf(root_fd, relative, 1);
}
