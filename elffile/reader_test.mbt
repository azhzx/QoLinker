// Hermetic tests: synthesize a minimal ELF64 LE object in memory and verify
// the reader against hand-computed expectations.

///|
/// Builds a minimal ELF64 object with sections:
/// null, .text, .rela.text, .symtab, .strtab, .shstrtab
fn build_test_obj() -> Bytes {
  let body = Buffer()
  // .text: 3 bytes of code
  let text_off = 64
  body.write_bytes(b"\x48\x89\xe5"[:])
  let rela_off = 64 + 3
  // .rela.text: one R_X86_64_PC32 against sym 1
  body.write_int64_le(0L) // r_offset
  body.write_int64_le((1L << 32) | 2L) // r_info: sym=1, type=R_X86_64_PC32
  body.write_int64_le(-4L) // r_addend
  let symtab_off = rela_off + @elfspec.RELA_SIZE
  // .symtab: null sym + "foo" (each exactly 24 bytes)
  body.write_uint_le(0) // st_name
  body.write_byte(b'\x00') // st_info
  body.write_byte(b'\x00') // st_other
  body.write_uint16_le(0) // st_shndx
  body.write_int64_le(0L) // st_value
  body.write_int64_le(0L) // st_size
  let sym1 = symtab_off + @elfspec.SYM_SIZE
  body.write_uint_le(1) // st_name -> "foo"
  body.write_byte(b'\x12') // GLOBAL FUNC
  body.write_byte(b'\x00')
  body.write_uint16_le(1) // st_shndx = .text
  body.write_int64_le(0L)
  body.write_int64_le(3L)
  let strtab_off = sym1 + @elfspec.SYM_SIZE
  body.write_bytes(b"\x00foo\x00"[:])
  let shstrtab_off = strtab_off + 5
  body.write_bytes(
    b"\x00.text\x00.rela.text\x00.symtab\x00.strtab\x00.shstrtab\x00"[:],
  )
  let shoff = shstrtab_off + 44
  let full = Buffer()
  // e_ident
  full.write_bytes(b"\x7fELF\x02\x01\x01\x00"[:])
  for _ in 0..<8 {
    full.write_byte(b'\x00')
  }
  full.write_uint16_le(1) // e_type ET_REL
  full.write_uint16_le(62) // e_machine EM_X86_64
  full.write_uint_le(1) // e_version
  full.write_int64_le(0L) // e_entry
  full.write_int64_le(0L) // e_phoff
  full.write_int64_le(shoff.to_int64()) // e_shoff
  full.write_uint_le(0) // e_flags
  full.write_uint16_le(64) // e_ehsize
  full.write_uint16_le(0) // e_phentsize
  full.write_uint16_le(0) // e_phnum
  full.write_uint16_le(64) // e_shentsize
  full.write_uint16_le(6) // e_shnum
  full.write_uint16_le(5) // e_shstrndx
  // body
  full.write_bytes(body.to_bytes()[:])
  // section headers
  full.write_bytes(shdr_buf(0, 0, 0L, 0L, 0L, 0, 0, 0L)[:])
  full.write_bytes(
    shdr_buf(1, @elfspec.SHT_PROGBITS, 6L, text_off.to_int64(), 3L, 0, 0, 4L)[:],
  )
  full.write_bytes(
    shdr_buf(
      7,
      @elfspec.SHT_RELA,
      0x40L,
      rela_off.to_int64(),
      @elfspec.RELA_SIZE.to_int64(),
      3,
      1,
      8L,
    )[:],
  )
  full.write_bytes(
    shdr_buf(
      18,
      @elfspec.SHT_SYMTAB,
      0L,
      symtab_off.to_int64(),
      (2 * @elfspec.SYM_SIZE).to_int64(),
      4,
      1,
      8L,
    )[:],
  )
  full.write_bytes(
    shdr_buf(26, @elfspec.SHT_STRTAB, 0L, strtab_off.to_int64(), 5L, 0, 0, 1L)[:],
  )
  full.write_bytes(
    shdr_buf(
      34,
      @elfspec.SHT_STRTAB,
      0L,
      shstrtab_off.to_int64(),
      44L,
      0,
      0,
      1L,
    )[:],
  )
  full.to_bytes()
}

///|
/// Serializes one section header.
fn shdr_buf(
  name : Int32,
  stype : Int32,
  flags : Int64,
  off : Int64,
  size : Int64,
  link : Int32,
  info : Int32,
  align : Int64,
) -> Bytes {
  let b = Buffer()
  b.write_uint_le(name.reinterpret_as_uint()) // sh_name
  b.write_uint_le(stype.reinterpret_as_uint()) // sh_type
  b.write_int64_le(flags) // sh_flags
  b.write_int64_le(0L) // sh_addr
  b.write_int64_le(off) // sh_offset
  b.write_int64_le(size) // sh_size
  b.write_uint_le(link.reinterpret_as_uint()) // sh_link
  b.write_uint_le(info.reinterpret_as_uint()) // sh_info
  b.write_int64_le(align) // sh_addralign
  b.write_int64_le(0L) // sh_entsize
  b.to_bytes()
}

///|
test "parse_elf: header and section names" {
  let data = build_test_obj()
  guard @elffile.parse_elf(data) is Some(reader) else {
    fail("parse_elf failed")
  }
  assert_eq(reader.ehdr.etype, 1)
  assert_eq(reader.ehdr.machine, 62)
  assert_eq(reader.shdrs.length(), 6)
  // Section names via shstrtab.
  assert_eq(@support.bytes_str(reader.section_name(reader.shdrs[1])), ".text")
  assert_eq(
    @support.bytes_str(reader.section_name(reader.shdrs[2])),
    ".rela.text",
  )
  assert_eq(
    @support.bytes_str(reader.section_name(reader.shdrs[5])),
    ".shstrtab",
  )
}

///|
test "parse_elf: symbols" {
  let data = build_test_obj()
  guard @elffile.parse_elf(data) is Some(reader) else {
    fail("parse_elf failed")
  }
  let symtab = reader.shdrs[3]
  guard reader.section_data(symtab) is Some(sec) else { fail("no symtab data") }
  guard @elffile.read_syms(sec) is Some(syms) else { fail("read_syms failed") }
  assert_eq(syms.length(), 2)
  // null symbol
  assert_eq(syms[0].binding, 0)
  assert_eq(syms[0].shndx, 0)
  // "foo": GLOBAL FUNC in section 1, size 3
  assert_eq(syms[1].binding, @elfspec.STB_GLOBAL)
  assert_eq(syms[1].stype, @elfspec.STT_FUNC)
  assert_eq(syms[1].shndx, 1)
  assert_eq(syms[1].size, 3L)
  let strtab = reader.shdrs[4]
  guard reader.section_data(strtab) is Some(strsec) else {
    fail("no strtab data")
  }
  assert_eq(
    @support.bytes_str(@elffile.sym_name(strsec, syms[1].name_off)),
    "foo",
  )
}

///|
test "parse_elf: relocations" {
  let data = build_test_obj()
  guard @elffile.parse_elf(data) is Some(reader) else {
    fail("parse_elf failed")
  }
  let rela = reader.shdrs[2]
  guard reader.section_data(rela) is Some(sec) else { fail("no rela data") }
  guard @elffile.read_relas(sec) is Some(relas) else {
    fail("read_relas failed")
  }
  assert_eq(relas.length(), 1)
  assert_eq(relas[0].offset, 0L)
  assert_eq(relas[0].sym, 1)
  assert_eq(relas[0].rtype, @elfspec.R_X86_64_PC32)
  assert_eq(relas[0].addend, -4L)
}

///|
test "parse_elf: section data bounds" {
  let data = build_test_obj()
  guard @elffile.parse_elf(data) is Some(reader) else {
    fail("parse_elf failed")
  }
  let text = reader.shdrs[1]
  guard reader.section_data(text) is Some(sec) else { fail("no text data") }
  assert_eq(sec.size, 3)
  assert_eq(sec.bytes[sec.offset], 0x48)
  // A section with out-of-bounds offset yields no data.
  let bogus = { ..text, offset: 999_999L, }
  assert_true(reader.section_data(bogus) is None)
  // Non-ELF data is rejected.
  assert_true(@elffile.parse_elf(b"not an elf file at all......") is None)
}
