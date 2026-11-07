// Hermetic archive tests: synthesize GNU ar archives and verify member and
// symbol-index parsing.
//
// Layout of the synthesized archive:
//   symtab header @8   (60 bytes), content @68, size 20
//   a.o header    @88  (60 bytes), content @148, size 10
//   b.o header    @158 (60 bytes), content @218, size 5

///|
/// Serializes one 60-byte archive member header.
fn ar_header(name : String, size : Int32) -> Bytes {
  let b = Buffer()
  let nm = @utf8.encode(name)
  b.write_bytes(nm[:])
  for _ in nm.length()..<16 {
    b.write_byte(b' ')
  }
  // mtime/uid/gid/mode fields: zeros as decimal, left-padded.
  for _ in 0..<12 {
    b.write_byte(b'0')
  }
  for _ in 0..<6 {
    b.write_byte(b'0')
  }
  for _ in 0..<6 {
    b.write_byte(b'0')
  }
  for _ in 0..<8 {
    b.write_byte(b'0')
  }
  let sz = @utf8.encode("\{size}")
  for _ in sz.length()..<10 {
    b.write_byte(b' ')
  }
  b.write_bytes(sz[:])
  b.write_bytes(b"`\n"[:])
  b.to_bytes()
}

///|
/// Writes a big-endian 32-bit value.
fn be32(b : @buffer.Buffer, v : Int32) -> Unit {
  b.write_byte(((v >> 24) & 0xff).to_byte())
  b.write_byte(((v >> 16) & 0xff).to_byte())
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())
}

///|
/// Builds a GNU archive with two members and a symbol index:
///   a.o defines "foo", b.o defines "bar".
fn build_test_archive() -> Bytes {
  let b = Buffer()
  b.write_bytes(b"!<arch>\n"[:])
  // Symbol index: BE count, BE member-header offsets, NUL-separated names.
  b.write_bytes(ar_header("/", 20)[:])
  be32(b, 2) // count
  be32(b, 88) // header offset of a.o
  be32(b, 158) // header offset of b.o
  b.write_bytes(b"foo\x00bar\x00"[:])
  // a.o: 10 bytes
  b.write_bytes(ar_header("a.o/", 10)[:])
  b.write_bytes(b"\x48\x89\xe5\x48\x89\xe5\x48\x89\xe5\xc3"[:])
  // b.o: 5 bytes
  b.write_bytes(ar_header("b.o/", 5)[:])
  b.write_bytes(b"\xb8\x2a\x00\x00\x00"[:])
  b.to_bytes()
}

///|
test "parse_archive: members and symbols" {
  let data = build_test_archive()
  guard @elffile.parse_archive(data) is Some(ar) else {
    fail("parse_archive failed")
  }
  assert_false(ar.thin)
  assert_eq(ar.members.length(), 2)
  assert_eq(@support.bytes_str(ar.members[0].name), "a.o")
  assert_eq(ar.members[0].size, 10L)
  assert_eq(@support.bytes_str(ar.members[1].name), "b.o")
  assert_eq(ar.members[1].size, 5L)
  guard ar.member_data(ar.members[0]) is Some(sec) else {
    fail("no member data")
  }
  assert_eq(sec.size, 10)
  assert_eq(sec.bytes[sec.offset], 0x48)
  // Symbol index maps "foo" -> member 0, "bar" -> member 1.
  assert_eq(ar.symbols.length(), 2)
  assert_eq(@support.bytes_str(ar.symbols[0].0), "foo")
  assert_eq(ar.symbols[0].1, 0)
  assert_eq(@support.bytes_str(ar.symbols[1].0), "bar")
  assert_eq(ar.symbols[1].1, 1)
}

///|
test "parse_archive: rejects bad magic" {
  assert_true(@elffile.parse_archive(b"garbage-data-here") is None)
}
