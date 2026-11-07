// Small numeric/string helpers shared across the linker.

///|
/// Rounds `value` up to the next multiple of `align` (`align` must be > 0).
pub fn align_to(value : Int64, align : Int64) -> Int64 {
  (value + align - 1) / align * align
}

///|
/// Rounds `value` up to the next multiple of `align` (`align` must be > 0).
pub fn align_to_i(value : Int32, align : Int32) -> Int32 {
  (value + align - 1) / align * align
}

///|
/// True when `value` is already a multiple of `align` (align must be > 0).
pub fn is_aligned(value : Int64, align : Int64) -> Bool {
  value % align == 0
}

///|
/// Decodes raw bytes (file names, symbol names) into a printable String.
pub fn bytes_str(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}

///|
/// Slices out a NUL-terminated string starting at `start`, up to `end`
/// (exclusive). The NUL byte is not included.
pub fn cstring_at(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let mut len = 0
  while start + len < end && data[start + len] != b'\x00' {
    len += 1
  }
  data[start:start + len].to_owned()
}

///|
/// Lowercase hex, no prefix: for map files and diagnostics.
pub fn hex_u64(value : Int64) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  if value == 0L {
    return "0"
  }
  let mut v = value
  let parts : Array[Char] = []
  while v > 0L {
    parts.push(digits[(v % 16L).to_int()])
    v = v / 16L
  }
  let rev : Array[Char] = []
  for i in 0..<parts.length() {
    rev.push(parts[parts.length() - 1 - i])
  }
  String::from_array(rev[:])
}
