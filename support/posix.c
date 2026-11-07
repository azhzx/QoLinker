// Minimal POSIX bindings used by the linker. Each function is intentionally
// tiny: all control flow lives in MoonBit, C only bridges syscalls.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "moonbit.h"

// Reads the whole file. Returns NULL on any failure (open/fstat/read).
MOONBIT_FFI_EXPORT
moonbit_bytes_t qo_read_file(moonbit_bytes_t path) {
  int fd = open((const char *)path, O_RDONLY);
  if (fd < 0) {
    return NULL;
  }
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(fd);
    return NULL;
  }
  off_t len = st.st_size;
  moonbit_bytes_t buf = moonbit_make_bytes((int32_t)len, 0);
  if (buf == NULL) {
    close(fd);
    return NULL;
  }
  off_t done = 0;
  while (done < len) {
    ssize_t n = read(fd, (char *)buf + done, (size_t)(len - done));
    if (n <= 0) {
      close(fd);
      return NULL;
    }
    done += n;
  }
  close(fd);
  return buf;
}

MOONBIT_FFI_EXPORT
int32_t qo_create_rw(moonbit_bytes_t path) {
  return open((const char *)path, O_RDWR | O_CREAT | O_TRUNC, 0666);
}

MOONBIT_FFI_EXPORT
int32_t qo_close(int32_t fd) {
  return close(fd);
}

MOONBIT_FFI_EXPORT
int32_t qo_ftruncate(int32_t fd, int64_t size) {
  return ftruncate(fd, (off_t)size);
}

// Returns total bytes written, or -1 on error. `buf` is borrowed.
MOONBIT_FFI_EXPORT
int64_t qo_pwrite(int32_t fd, int64_t offset, moonbit_bytes_t buf) {
  size_t len = Moonbit_array_length(buf);
  size_t done = 0;
  while (done < len) {
    ssize_t n = pwrite(fd, (const char *)buf + done, len - done, (off_t)(offset + done));
    if (n <= 0) {
      return -1;
    }
    done += n;
  }
  return (int64_t)done;
}

MOONBIT_FFI_EXPORT
int32_t qo_fchmod(int32_t fd, int32_t mode) {
  return fchmod(fd, (mode_t)mode);
}

MOONBIT_FFI_EXPORT
void qo_eprint(moonbit_bytes_t buf) {
  fwrite((const char *)buf, 1, Moonbit_array_length(buf), stderr);
}

MOONBIT_FFI_EXPORT
void qo_exit(int32_t code) {
  exit(code);
}
