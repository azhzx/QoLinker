// Safe file I/O wrappers over `ffi.mbt`. All linker-side code goes through
// these; the raw externs stay private to the package.

///|
/// Reads the whole file into a fresh immutable `Bytes`. `None` on any I/O
/// error (missing file, directory, read failure).
pub fn read_file(path : Bytes) -> Bytes? {
  qo_read_file(path)
}

///|
/// Opens (or creates/truncates) a file for random-access writing. Returns a
/// raw fd for use with `write_at`/`set_file_size`, or `None` on failure.
pub fn create_file(path : Bytes) -> Int32? {
  let fd = qo_create_rw(path)
  if fd < 0 {
    None
  } else {
    Some(fd)
  }
}

///|
pub fn close_fd(fd : Int32) -> Unit {
  let _ = qo_close(fd)
}

///|
/// Pre-allocates the output file to `size` bytes.
pub fn set_file_size(fd : Int32, size : Int64) -> Bool {
  qo_ftruncate(fd, size) == 0
}

///|
/// Writes `buf` at byte offset `offset` in full. `false` on failure.
pub fn write_at(fd : Int32, offset : Int64, buf : Bytes) -> Bool {
  qo_pwrite(fd, offset, buf) >= 0
}

///|
/// Appends `text` (UTF-8) to stderr without a trailing newline.
pub fn eprint(text : String) -> Unit {
  qo_eprint(@utf8.encode(text))
}

///|
pub fn eprintln(text : String) -> Unit {
  qo_eprint(@utf8.encode("\{text}\n"))
}

///|
/// Marks the output file executable (0755), like lld does for exec outputs.
pub fn make_executable(fd : Int32) -> Unit {
  let _ = qo_fchmod(fd, 0o755)
}

///|
/// Terminates the process immediately (lld-style fatal errors abort linking).
pub fn exit(code : Int32) -> Unit {
  qo_exit(code)
}
