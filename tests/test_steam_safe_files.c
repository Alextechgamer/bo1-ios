// SPDX-License-Identifier: GPL-3.0-or-later
// Regression tests for containment of Steam content filesystem operations.
#include "steam_safe_files.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static unsigned checks;
static char temporary[4096];

static void remove_tree(const char *path) {
  struct stat info;
  if (lstat(path, &info) != 0) return;
  if (!S_ISDIR(info.st_mode)) { (void)unlink(path); return; }
  DIR *directory = opendir(path);
  if (!directory) return;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    char child[4096];
    int count = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
    if (count >= 0 && (size_t)count < sizeof(child)) remove_tree(child);
  }
  (void)closedir(directory);
  (void)rmdir(path);
}

static void cleanup(void) { if (temporary[0]) remove_tree(temporary); }

static void require_at(int condition, const char *expression, int line) {
  ++checks;
  if (condition) return;
  fprintf(stderr, "FAIL at line %d: %s (errno %d)\n", line, expression, errno);
  exit(1);
}
#define REQUIRE(expression) require_at(!!(expression), #expression, __LINE__)

static void join(char *output, size_t capacity, const char *directory, const char *name) {
  int count = snprintf(output, capacity, "%s/%s", directory, name);
  REQUIRE(count >= 0 && (size_t)count < capacity);
}

static void reject_open(int root, const char *name, int writing, int create) {
  errno = 0;
  int file = bo1_steam_open_file(root, name, writing, create);
  if (file >= 0) close(file);
  REQUIRE(file == -1 && errno != 0);
}

static void reject_directory(int root, const char *name) {
  errno = 0;
  REQUIRE(bo1_steam_make_directory(root, name) == -1 && errno != 0);
}

static void unchanged(const char *path) {
  char data[32] = {0};
  int file = open(path, O_RDONLY);
  REQUIRE(file >= 0);
  REQUIRE(read(file, data, sizeof(data)) == 13);
  REQUIRE(!memcmp(data, "outside-data\n", 13));
  REQUIRE(close(file) == 0);
}

static void create_relative(int root, const char *path, const char *bytes) {
  int fd = bo1_steam_open_file(root, path, 1, 1);
  REQUIRE(fd >= 0);
  size_t length = strlen(bytes);
  REQUIRE(write(fd, bytes, length) == (ssize_t)length);
  REQUIRE(close(fd) == 0);
}

static void contents_equal(int root, const char *path, const char *expected) {
  int fd = bo1_steam_open_file(root, path, 0, 0);
  REQUIRE(fd >= 0);
  char bytes[128] = {0};
  ssize_t count = read(fd, bytes, sizeof(bytes));
  REQUIRE(count == (ssize_t)strlen(expected));
  REQUIRE(count >= 0 && !memcmp(bytes, expected, (size_t)count));
  REQUIRE(close(fd) == 0);
}

static void timed_out(int signal_number) {
  (void)signal_number;
  static const char message[] = "FAIL: filesystem helper blocked on nonregular input\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(2);
}

int main(void) {
  const char *base = getenv("TMPDIR");
  if (!base || !*base) base = "/tmp";
  int count = snprintf(temporary, sizeof(temporary), "%s/bo1-steam-files-XXXXXX", base);
  REQUIRE(count >= 0 && (size_t)count < sizeof(temporary));
  REQUIRE(mkdtemp(temporary) != NULL);
  REQUIRE(atexit(cleanup) == 0);
  REQUIRE(signal(SIGALRM, timed_out) != SIG_ERR);
  alarm(10);

  char root_path[4096], outside[4096], sentinel[4096], path[4096], other[4096];
  join(root_path, sizeof(root_path), temporary, "install");
  join(outside, sizeof(outside), temporary, "outside");
  REQUIRE(mkdir(root_path, 0700) == 0);
  REQUIRE(mkdir(outside, 0700) == 0);
  join(sentinel, sizeof(sentinel), outside, "sentinel");
  int file = open(sentinel, O_WRONLY | O_CREAT | O_EXCL, 0600);
  REQUIRE(file >= 0);
  REQUIRE(write(file, "outside-data\n", 13) == 13);
  REQUIRE(close(file) == 0);

  int root = bo1_steam_open_root(root_path);
  REQUIRE(root >= 0);
  REQUIRE(bo1_steam_make_directory(root, "zone/Common") == 0);
  REQUIRE(bo1_steam_make_directory(root, "zone/Common") == 0);
  file = bo1_steam_open_file(root, "zone/Common/common.ff", 1, 1);
  REQUIRE(file >= 0);
  REQUIRE(pwrite(file, "ff-fixture", 10, 0) == 10);
  REQUIRE(close(file) == 0);
  // Reopening an existing file for writing does not truncate it.
  file = bo1_steam_open_file(root, "zone/Common/common.ff", 1, 1);
  struct stat info;
  REQUIRE(file >= 0 && fstat(file, &info) == 0 && info.st_size == 10);
  REQUIRE(close(file) == 0);
  file = bo1_steam_open_file(root, "zone/Common/common.ff", 0, 0);
  char bytes[16] = {0};
  REQUIRE(file >= 0 && read(file, bytes, sizeof(bytes)) == 10);
  REQUIRE(!memcmp(bytes, "ff-fixture", 10));
  REQUIRE(close(file) == 0);
  reject_open(root, "absent/sub/file", 0, 0);
  join(path, sizeof(path), root_path, "absent");
  REQUIRE(lstat(path, &info) != 0 && errno == ENOENT);

  // Reject all invalid syntax before creating any intermediate directory.
  static const char *invalid[] = {
    "", ".", "..", "/absolute", "../outside/sentinel", "zone/../sentinel",
    "zone/./sentinel", "zone//sentinel", "zone/", "zone\\sentinel", "C:sentinel",
    "zone/line\nbreak", "zone/control\177", "bad-parent/../outside/sentinel"
  };
  for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
    reject_open(root, invalid[i], 1, 1);
    reject_directory(root, invalid[i]);
  }
  reject_open(root, NULL, 1, 1);
  reject_directory(root, NULL);
  char too_long[1025];
  memset(too_long, 'x', sizeof(too_long) - 1); too_long[sizeof(too_long) - 1] = 0;
  reject_open(root, too_long, 1, 1);
  char too_deep[131];
  for (size_t i = 0; i < 65; ++i) { too_deep[2 * i] = 'x'; too_deep[2 * i + 1] = '/'; }
  too_deep[129] = 0;
  reject_open(root, too_deep, 1, 1);
  reject_directory(root, too_deep);
  join(path, sizeof(path), root_path, "bad-parent");
  REQUIRE(lstat(path, &info) != 0 && errno == ENOENT);
  join(path, sizeof(path), root_path, "x");
  REQUIRE(lstat(path, &info) != 0 && errno == ENOENT);

  // A pre-existing parent link cannot redirect creation or directory walks.
  join(path, sizeof(path), root_path, "parent-link");
  REQUIRE(symlink(outside, path) == 0);
  reject_open(root, "parent-link/sentinel", 1, 1);
  reject_open(root, "parent-link/new-file", 1, 1);
  reject_directory(root, "parent-link/new-directory");
  join(other, sizeof(other), outside, "new-file");
  REQUIRE(lstat(other, &info) != 0 && errno == ENOENT);
  join(other, sizeof(other), outside, "new-directory");
  REQUIRE(lstat(other, &info) != 0 && errno == ENOENT);

  // Leaf links, including dangling links and hardlinks, are also refused.
  join(path, sizeof(path), root_path, "leaf-link");
  REQUIRE(symlink(sentinel, path) == 0);
  reject_open(root, "leaf-link", 1, 1);
  reject_open(root, "leaf-link", 0, 0);
  join(path, sizeof(path), root_path, "dangling-link");
  REQUIRE(symlink(other, path) == 0);
  reject_open(root, "dangling-link", 1, 1);
  REQUIRE(lstat(other, &info) != 0 && errno == ENOENT);
  join(path, sizeof(path), root_path, "hard-link");
  REQUIRE(link(sentinel, path) == 0);
  reject_open(root, "hard-link", 1, 1);
  reject_open(root, "hard-link", 0, 0);
  unchanged(sentinel);

  // A FIFO must fail promptly instead of blocking in open before fstat.
  join(path, sizeof(path), root_path, "fifo");
  REQUIRE(mkfifo(path, 0600) == 0);
  reject_open(root, "fifo", 0, 0);
  reject_open(root, "fifo", 1, 1);
  reject_open(root, "zone", 0, 0);
  reject_open(root, "zone", 1, 1);
  reject_open(root, "zone/Common/common.ff/child", 1, 1);
  reject_directory(root, "zone/Common/common.ff/child");
  reject_open(-1, "valid-name", 1, 1);
  REQUIRE(fcntl(root, F_GETFD) >= 0); // failures do not consume the caller's root

  // The root itself cannot be a link, even with a trailing slash.
  join(path, sizeof(path), temporary, "root-link");
  REQUIRE(symlink(outside, path) == 0);
  int rejected = bo1_steam_open_root(path);
  if (rejected >= 0) close(rejected);
  REQUIRE(rejected == -1);
  join(other, sizeof(other), path, "");
  rejected = bo1_steam_open_root(other);
  if (rejected >= 0) close(rejected);
  REQUIRE(rejected == -1);
  REQUIRE(bo1_steam_open_root(sentinel) == -1);
  REQUIRE(bo1_steam_open_root(NULL) == -1);

  // Publication uses retained descriptors as well as no-follow reads.
  int duplicate = bo1_steam_open_directory(root, "");
  REQUIRE(duplicate >= 0);
  REQUIRE(close(duplicate) == 0);
  int nested = bo1_steam_open_directory(root, "zone/Common");
  REQUIRE(nested >= 0);
  REQUIRE(close(nested) == 0);
  REQUIRE(bo1_steam_open_directory(root, "parent-link") == -1);
  REQUIRE(bo1_steam_file_exists(root, "zone/Common/common.ff") == 1);
  REQUIRE(bo1_steam_file_exists(root, "missing/file") == 0);
  REQUIRE(bo1_steam_file_exists(root, "leaf-link") == -1);
  REQUIRE(bo1_steam_file_exists(root, "hard-link") == -1);
  REQUIRE(bo1_steam_file_exists(root, "zone") == -1);

  char staging_path[4096];
  join(staging_path, sizeof(staging_path), temporary, "staging");
  REQUIRE(mkdir(staging_path, 0700) == 0);
  int staging = bo1_steam_open_root(staging_path);
  REQUIRE(staging >= 0);
  create_relative(staging, "incoming.bin", "new-bytes");
  REQUIRE(bo1_steam_move_file(staging, "incoming.bin", root, "published/new.bin") == 0);
  REQUIRE(bo1_steam_file_exists(staging, "incoming.bin") == 0);
  contents_equal(root, "published/new.bin", "new-bytes");
  create_relative(staging, "conflict.bin", "incoming");
  create_relative(root, "published/existing.bin", "keep");
  errno = 0;
  REQUIRE(bo1_steam_move_file(staging, "conflict.bin", root, "published/existing.bin") == -1 && errno == EEXIST);
  contents_equal(staging, "conflict.bin", "incoming");
  contents_equal(root, "published/existing.bin", "keep");

  REQUIRE(bo1_steam_move_file(staging, "conflict.bin", root, "parent-link/sentinel") == -1);
  REQUIRE(bo1_steam_move_file(staging, "conflict.bin", root, "leaf-link") == -1);
  REQUIRE(bo1_steam_replace_file(staging, "conflict.bin", root, "leaf-link") == -1);
  REQUIRE(bo1_steam_replace_file(staging, "conflict.bin", root, "hard-link") == -1);
  join(path, sizeof(path), staging_path, "source-link");
  REQUIRE(symlink(sentinel, path) == 0);
  REQUIRE(bo1_steam_move_file(staging, "source-link", root, "published/link.bin") == -1);
  REQUIRE(bo1_steam_replace_file(staging, "source-link", root, "published/existing.bin") == -1);
  join(path, sizeof(path), staging_path, "source-parent-link");
  REQUIRE(symlink(outside, path) == 0);
  REQUIRE(bo1_steam_move_file(staging, "source-parent-link/sentinel", root, "published/link.bin") == -1);
  contents_equal(root, "published/existing.bin", "keep");
  unchanged(sentinel);

  create_relative(root, "metadata.json", "old");
  create_relative(staging, "metadata-new.json", "new");
  REQUIRE(bo1_steam_replace_file(staging, "metadata-new.json", root, "metadata.json") == 0);
  REQUIRE(bo1_steam_file_exists(staging, "metadata-new.json") == 0);
  contents_equal(root, "metadata.json", "new");
  create_relative(staging, "metadata-new.json", "absent-target");
  REQUIRE(bo1_steam_replace_file(staging, "metadata-new.json", root, "metadata-absent.json") == 0);
  contents_equal(root, "metadata-absent.json", "absent-target");
  REQUIRE(bo1_steam_remove_file(root, "metadata.json") == 0);
  REQUIRE(bo1_steam_file_exists(root, "metadata.json") == 0);
  REQUIRE(bo1_steam_remove_file(root, "metadata.json") == 0);
  REQUIRE(bo1_steam_remove_file(root, "missing/path/file") == 0);
  REQUIRE(bo1_steam_remove_file(root, "parent-link/sentinel") == -1);
  REQUIRE(bo1_steam_remove_file(root, "leaf-link") == -1);
  REQUIRE(bo1_steam_remove_file(root, "hard-link") == -1);
  REQUIRE(bo1_steam_remove_file(root, "zone") == -1);
  REQUIRE(bo1_steam_make_directory(root, "empty-directory") == 0);
  REQUIRE(bo1_steam_remove_directory(root, "empty-directory") == 0);
  REQUIRE(bo1_steam_remove_directory(root, "empty-directory") == 0);
  REQUIRE(bo1_steam_remove_directory(root, "zone") == -1);
  REQUIRE(bo1_steam_remove_directory(root, "parent-link") == -1);
  REQUIRE(bo1_steam_remove_directory(root, "zone/Common/common.ff") == -1);
  unchanged(sentinel);

  // After opening the root, replacing its path cannot redirect later writes.
  join(path, sizeof(path), temporary, "moved-install");
  REQUIRE(rename(root_path, path) == 0);
  REQUIRE(symlink(outside, root_path) == 0);
  file = bo1_steam_open_file(root, "anchored.bin", 1, 1);
  REQUIRE(file >= 0);
  REQUIRE(write(file, "anchor", 6) == 6);
  REQUIRE(close(file) == 0);
  join(other, sizeof(other), outside, "anchored.bin");
  REQUIRE(lstat(other, &info) != 0 && errno == ENOENT);
  join(other, sizeof(other), path, "anchored.bin");
  REQUIRE(lstat(other, &info) == 0 && info.st_size == 6);
  create_relative(staging, "anchored-publish.bin", "descriptor-move");
  REQUIRE(bo1_steam_move_file(staging, "anchored-publish.bin", root, "published/anchored.bin") == 0);
  contents_equal(root, "published/anchored.bin", "descriptor-move");
  join(other, sizeof(other), outside, "published/anchored.bin");
  REQUIRE(lstat(other, &info) != 0 && errno == ENOENT);
  REQUIRE(bo1_steam_remove_file(root, "published/anchored.bin") == 0);
  REQUIRE(close(staging) == 0);
  unchanged(sentinel);
  REQUIRE(close(root) == 0);
  alarm(0);
  printf("Steam filesystem containment: %u checks passed\n", checks);
  return 0;
}
