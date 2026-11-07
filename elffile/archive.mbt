// ar archive reader (GNU flavor, plus thin-archive detection).
// Mirrors llvm/Object/Archive.cpp behavior for the parts a linker needs:
// member listing and the symbol-index → member mapping used for lazy
// extraction ("remember every symbol ever seen", lld-style).
//
// MVP scope: GNU archives (llvm-ar default on Linux targets, and what
// `llvm-ar --format=gnu` produces). BSD `__.SYMDEF` symbol tables are not
// parsed (fixture tooling pins GNU format).

///|
const GNU_MAGIC : Bytes = b"!<arch>\n"

///|
const THIN_MAGIC : Bytes = b"!<thin>\n"

///|
const HEADER_SIZE : Int32 = 60

///|
/// One member record. For thin archives `size` is zero and the content must
/// be resolved as a sibling file by the caller.
pub(all) struct ArchiveMember {
  name : Bytes
  offset : Int64
  size : Int64
  thin : Bool
}

///|
/// A parsed archive. `symbols` maps each defined symbol to the member index
/// defining it.
pub(all) struct Archive {
  data : Bytes
  thin : Bool
  members : Array[ArchiveMember]
  symbols : Array[(Bytes, Int32)]
}

///|
pub fn Archive::member_data(self : Archive, m : ArchiveMember) -> SecData? {
  if m.thin {
    return None
  }
  let file_len = self.data.length().to_int64()
  if m.offset < 0L || m.size < 0L || m.offset + m.size > file_len {
    return None
  }
  Some({ bytes: self.data, offset: m.offset.to_int(), size: m.size.to_int(), })
}

///|
/// Parses an archive. Returns `None` when the magic is missing or a member
/// header is malformed.
pub fn parse_archive(data : Bytes) -> Archive? {
  if data.length() < 8 {
    return None
  }
  let thin = data[:8] == THIN_MAGIC
  if !thin && data[:8] != GNU_MAGIC {
    return None
  }
  let members : Array[ArchiveMember] = []
  let mut symtab : SecData? = None
  let mut symtab64 = false
  let mut longnames : SecData? = None
  let mut pos = 8
  let len = data.length()
  while pos + HEADER_SIZE <= len {
    guard header_size(data, pos) is Some(size) else { return None }
    let mut content_off = pos + HEADER_SIZE
    let name_field = data[pos:pos + 16].to_owned()
    let mut is_symtab = false
    let mut is_longnames = false
    let name : Bytes? = if name_field is [b'/', b'/', ..] {
      is_longnames = true
      Some(b"//")
    } else if name_field is [b'/', b' ', ..] ||
      name_field is [b'/', b'S', b'Y', b'M', b'6', b'4', b'/', ..] {
      is_symtab = true
      symtab64 = name_field is [b'/', b'S', b'Y', b'M', b'6', b'4', b'/', ..]
      Some(name_field)
    } else if name_field is [b'#', b'1', b'/', .. rest] {
      // BSD extended name: decimal length N, name bytes follow in content.
      guard decimal_prefix(rest) is Some(n) else { return None }
      if n <= 0 || content_off + n > len {
        return None
      }
      let raw = data[content_off:content_off + n].to_owned()
      content_off += n
      let sz = size - n
      // Strip trailing NUL padding.
      let mut e = raw.length()
      while e > 0 && raw[e - 1] == b'\x00' {
        e -= 1
      }
      members.push({
        name: raw[:e].to_owned(),
        offset: content_off.to_int64(),
        size: sz.to_int64(),
        thin: false,
      })
      pos = content_off + (sz + 1) / 2 * 2
      None
    } else {
      Some(plain_member_name(name_field))
    }
    match name {
      Some(nm) => {
        if is_longnames {
          longnames = Some({ bytes: data, offset: content_off, size, })
        } else if is_symtab {
          symtab = Some({ bytes: data, offset: content_off, size, })
        } else {
          let resolved : Bytes = match nm {
            _ if nm is [b'/', ..] => {
              // "/N" reference into the "//" long-names table.
              guard longnames is Some(table) else { return None }
              guard decimal_prefix(nm[1:]) is Some(n) else { return None }
              // Long-table names carry their own trailing '/'.
              let raw = long_name_at(table, n)
              let e = raw.length()
              if e > 0 && raw[e - 1] == b'/' {
                raw[:e - 1].to_owned()
              } else {
                raw
              }
            }
            nm => nm
          }
          members.push({
            name: resolved,
            offset: content_off.to_int64(),
            size: size.to_int64(),
            thin: thin && size == 0,
          })
        }
        pos = content_off + (size + 1) / 2 * 2
      }
      None => ()
    }
  }
  let symbols : Array[(Bytes, Int32)] = match symtab {
    Some(tab) => parse_archive_symbols(tab, symtab64, members)
    None => []
  }
  Some({ data, thin, members, symbols, })
}

///|
/// Parses a leading decimal number from bytes.
fn decimal_prefix(data : BytesView) -> Int32? {
  let mut v = 0
  let mut digits = 0
  for c in data {
    if c >= b'0' && c <= b'9' {
      v = v * 10 + (c - b'0').to_int()
      digits += 1
    } else {
      break
    }
  }
  if digits == 0 {
    None
  } else {
    Some(v)
  }
}

///|
/// Extracts the size field from a member header (decimal, right-aligned).
fn header_size(data : Bytes, pos : Int32) -> Int32? {
  let mut v = 0
  for i in 0..<10 {
    let c = data[pos + 48 + i]
    if c == b' ' {
      continue
    }
    if c < b'0' || c > b'9' {
      return None
    }
    v = v * 10 + (c - b'0').to_int()
  }
  Some(v)
}

///|
/// Strips trailing spaces and the trailing `/` from a GNU member name field.
fn plain_member_name(name_field : Bytes) -> Bytes {
  let mut end = name_field.length()
  while end > 0 && name_field[end - 1] == b' ' {
    end -= 1
  }
  if end > 0 && name_field[end - 1] == b'/' {
    end -= 1
  }
  name_field[:end].to_owned()
}

///|
/// Reads a NUL/newline-terminated name from the "//" long-names table.
fn long_name_at(table : SecData, start : Int32) -> Bytes {
  let mut len = 0
  let begin = table.offset + start
  let end = table.offset + table.size
  while begin + len < end &&
        table.bytes[begin + len] != b'\x00' &&
        table.bytes[begin + len] != b'\n' {
    len += 1
  }
  table.bytes[begin:begin + len].to_owned()
}

///|
/// GNU symbol table: big-endian count, member-header offsets, then
/// NUL-separated names. The 64-bit variant ("/SYM64/") uses 8-byte offsets.
fn parse_archive_symbols(
  symtab : SecData,
  use64 : Bool,
  members : Array[ArchiveMember],
) -> Array[(Bytes, Int32)] {
  let out : Array[(Bytes, Int32)] = []
  guard symtab.size >= 4 else { return out }
  // Symbol-table offsets point at member *headers*; our members record the
  // content offset, so index by (content offset - header size).
  let index_of_offset : Map[Int64, Int32] = Map([])
  for i, m in members {
    index_of_offset[m.offset - HEADER_SIZE.to_int64()] = i
  }
  let base = symtab.offset
  let entry_size = if use64 { 8 } else { 4 }
  let count = if use64 {
    be_u64(symtab.bytes, base).to_int()
  } else {
    be_u32(symtab.bytes, base)
  }
  if count < 0 || count > symtab.size {
    return out
  }
  let names_start = base + 4 + count * entry_size
  let names_end = base + symtab.size
  let mut name_pos = names_start
  for i in 0..<count {
    let entry = base + 4 + i * entry_size
    let member_off = if use64 {
      be_u64(symtab.bytes, entry)
    } else {
      Int64::from_int(be_u32(symtab.bytes, entry))
    }
    let start = name_pos
    if start >= names_end {
      break
    }
    let mut n = 0
    while start + n < names_end && symtab.bytes[start + n] != b'\x00' {
      n += 1
    }
    name_pos = start + n + 1
    let idx = index_of_offset.get(member_off)
    guard idx is Some(idx) else { continue }
    out.push((symtab.bytes[start:start + n].to_owned(), idx))
  }
  out
}

///|
fn be_u32(data : Bytes, off : Int32) -> Int32 {
  (data[off].to_int() << 24) |
  (data[off + 1].to_int() << 16) |
  (data[off + 2].to_int() << 8) |
  data[off + 3].to_int()
}

///|
fn be_u64(data : Bytes, off : Int32) -> Int64 {
  Bytes::unsafe_read_uint64_be(data, off).reinterpret_as_int64()
}
