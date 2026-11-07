// ELF64 little-endian reader over an in-memory buffer (the whole file).
// Parsing is complete but lazy in spirit: section contents stay in `data`
// and are sliced on demand, mirroring lld's MemoryBufferRef discipline.

///|
/// Parsed `Elf64_Ehdr` fields that matter for linking.
pub(all) struct Ehdr {
  etype : Int32
  machine : Int32
  entry : Int64
  shoff : Int64
  phoff : Int64
  phnum : Int32
  shnum : Int32
  shstrndx : Int32
}

///|
/// Parsed `Elf64_Shdr`.
pub(all) struct Shdr {
  name_off : Int32
  stype : Int32
  flags : Int64
  addr : Int64
  offset : Int64
  size : Int64
  link : Int32
  info : Int32
  addralign : Int64
  entsize : Int64
}

///|
/// Parsed `Elf64_Sym`.
pub(all) struct ElfSym {
  name_off : Int32
  binding : Int32
  stype : Int32
  visibility : Int32
  shndx : Int32
  value : Int64
  size : Int64
}

///|
/// Parsed `Elf64_Rela`.
pub(all) struct Rela {
  offset : Int64
  sym : Int32
  rtype : Int32
  addend : Int64
}

///|
/// A slice of section content inside the backing file buffer. The base
/// `Bytes` outlives every `SecData` derived from it.
pub(all) struct SecData {
  bytes : Bytes
  offset : Int32
  size : Int32
}

///|
/// A parsed ELF object/shared object file.
pub(all) struct ElfReader {
  data : Bytes
  ehdr : Ehdr
  shdrs : FixedArray[Shdr]
  shstrtab : SecData
}

///|
/// Unsigned 16-bit LE read (caller guarantees bounds).
pub fn u16_at(data : Bytes, off : Int32) -> Int32 {
  Bytes::unsafe_read_uint16_le(data, off).to_int()
}

///|
/// Unsigned 32-bit LE read (caller guarantees bounds).
pub fn u32_at(data : Bytes, off : Int32) -> Int32 {
  Bytes::unsafe_read_uint32_le(data, off).reinterpret_as_int()
}

///|
/// Unsigned 64-bit LE read as Int64 (caller guarantees bounds).
pub fn u64_at(data : Bytes, off : Int32) -> Int64 {
  Bytes::unsafe_read_uint64_le(data, off).reinterpret_as_int64()
}

///|
/// Signed 64-bit LE read (bit reinterpretation, used for Rela addends).
pub fn i64_at(data : Bytes, off : Int32) -> Int64 {
  Bytes::unsafe_read_uint64_le(data, off).reinterpret_as_int64()
}

///|
/// Parses a complete ELF64 LE image. Returns `None` when the file is not a
/// well-formed ELF64 LE object we can process.
pub fn parse_elf(data : Bytes) -> ElfReader? {
  if data.length() < 16 {
    return None
  }
  if data[0] != b'\x7f' || data[1] != b'E' || data[2] != b'L' || data[3] != b'F' {
    return None
  }
  if data[4] != 2 || data[5] != 1 {
    // Only ELFCLASS64 + ELFDATA2LSB in MVP scope.
    return None
  }
  if data.length() < @elfspec.EH_SIZE {
    return None
  }
  let ehdr : Ehdr = {
    etype: u16_at(data, 16),
    machine: u16_at(data, 18),
    entry: u64_at(data, @elfspec.EH_ENTRY_OFF),
    shoff: u64_at(data, @elfspec.EH_SHOFF_OFF),
    phoff: u64_at(data, @elfspec.EH_PHOFF_OFF),
    phnum: u16_at(data, @elfspec.EH_PHNUM_OFF),
    shnum: u16_at(data, @elfspec.EH_SHNUM_OFF),
    shstrndx: u16_at(data, @elfspec.EH_SHSTRNDX_OFF),
  }
  if ehdr.shoff == 0L {
    return None
  }
  let mut shnum = ehdr.shnum
  let mut shstrndx = ehdr.shstrndx
  // Extended section numbering: real counts live in shdr[0].
  if shnum == 0 || shstrndx == @elfspec.SHN_XINDEX {
    if ehdr.shoff + @elfspec.SHDR_SIZE.to_int64() > data.length().to_int64() {
      return None
    }
    let sh0off = ehdr.shoff.to_int()
    if shnum == 0 {
      shnum = u64_at(data, sh0off + @elfspec.SHDR_SIZE_OFF).to_int()
    }
    if shstrndx == @elfspec.SHN_XINDEX {
      shstrndx = u32_at(data, sh0off + @elfspec.SHDR_LINK_OFF)
    }
  }
  let shdrs = parse_shdrs(data, ehdr.shoff, shnum)
  guard shdrs is Some(shdrs) else { return None }
  guard shstrndx >= 0 && shstrndx < shdrs.length() else { return None }
  let shstr = shdrs[shstrndx]
  guard section_data_raw(data, shstr) is Some(shstrtab) else { return None }
  Some({ data, ehdr, shdrs, shstrtab, })
}

///|
fn parse_shdrs(data : Bytes, shoff : Int64, shnum : Int32) -> FixedArray[Shdr]? {
  let total = shoff + (shnum * @elfspec.SHDR_SIZE).to_int64()
  if shnum < 0 || total > data.length().to_int64() {
    return None
  }
  let out = FixedArray::make(shnum, default_shdr())
  for i in 0..<shnum {
    let base = shoff.to_int() + i * @elfspec.SHDR_SIZE
    out[i] = {
      name_off: u32_at(data, base + @elfspec.SHDR_NAME_OFF),
      stype: u32_at(data, base + @elfspec.SHDR_TYPE_OFF),
      flags: u64_at(data, base + @elfspec.SHDR_FLAGS_OFF),
      addr: u64_at(data, base + @elfspec.SHDR_ADDR_OFF),
      offset: u64_at(data, base + @elfspec.SHDR_OFFSET_OFF),
      size: u64_at(data, base + @elfspec.SHDR_SIZE_OFF),
      link: u32_at(data, base + @elfspec.SHDR_LINK_OFF),
      info: u32_at(data, base + @elfspec.SHDR_INFO_OFF),
      addralign: u64_at(data, base + @elfspec.SHDR_ADDRALIGN_OFF),
      entsize: u64_at(data, base + @elfspec.SHDR_ENTSIZE_OFF),
    }
  }
  Some(out)
}

///|
fn default_shdr() -> Shdr {
  {
    name_off: 0,
    stype: 0,
    flags: 0L,
    addr: 0L,
    offset: 0L,
    size: 0L,
    link: 0,
    info: 0,
    addralign: 0L,
    entsize: 0L,
  }
}

///|
/// Bounds-checked slice of a section's file contents.
pub fn section_data_raw(data : Bytes, s : Shdr) -> SecData? {
  let file_len = data.length().to_int64()
  if s.offset < 0L || s.size < 0L || s.offset + s.size > file_len {
    return None
  }
  // NOBITS has no file content.
  if s.stype == @elfspec.SHT_NOBITS {
    return Some({ bytes: data, offset: s.offset.to_int(), size: 0, })
  }
  Some({ bytes: data, offset: s.offset.to_int(), size: s.size.to_int(), })
}

///|
/// Bounds-checked slice of this reader's section contents.
pub fn ElfReader::section_data(self : ElfReader, s : Shdr) -> SecData? {
  section_data_raw(self.data, s)
}

///|
/// Resolves a section name through the section header string table.
pub fn ElfReader::section_name(self : ElfReader, s : Shdr) -> Bytes {
  @support.cstring_at(
    self.shstrtab.bytes,
    self.shstrtab.offset + s.name_off,
    self.shstrtab.offset + self.shstrtab.size,
  )
}

///|
/// Reads the symbol table of a SHT_SYMTAB/SHT_DYNSYM section.
pub fn read_syms(sec : SecData) -> FixedArray[ElfSym]? {
  let entsize = if sec.size % @elfspec.SYM_SIZE == 0 {
    @elfspec.SYM_SIZE
  } else {
    return None
  }
  let count = sec.size / entsize
  let out = FixedArray::make(count, default_sym())
  for i in 0..<count {
    let base = sec.offset + i * entsize
    let info = sec.bytes[base + @elfspec.SYM_INFO_OFF].to_int()
    out[i] = {
      name_off: u32_at(sec.bytes, base + @elfspec.SYM_NAME_OFF),
      binding: info >> @elfspec.STB_SHIFT,
      stype: info & 0xf,
      visibility: sec.bytes[base + @elfspec.SYM_OTHER_OFF].to_int() & 3,
      shndx: u16_at(sec.bytes, base + @elfspec.SYM_SHNDX_OFF),
      value: u64_at(sec.bytes, base + @elfspec.SYM_VALUE_OFF),
      size: u64_at(sec.bytes, base + @elfspec.SYM_SIZE_OFF),
    }
  }
  Some(out)
}

///|
fn default_sym() -> ElfSym {
  {
    name_off: 0,
    binding: 0,
    stype: 0,
    visibility: 0,
    shndx: 0,
    value: 0L,
    size: 0L,
  }
}

///|
/// Resolves a symbol name from the string table `strtab` at `name_off`.
pub fn sym_name(strtab : SecData, name_off : Int32) -> Bytes {
  @support.cstring_at(
    strtab.bytes,
    strtab.offset + name_off,
    strtab.offset + strtab.size,
  )
}

///|
/// Reads a SHT_RELA section. `r_info` splits into (sym, type).
pub fn read_relas(sec : SecData) -> FixedArray[Rela]? {
  if sec.size % @elfspec.RELA_SIZE != 0 {
    return None
  }
  let count = sec.size / @elfspec.RELA_SIZE
  let out = FixedArray::make(count, default_rela())
  for i in 0..<count {
    let base = sec.offset + i * @elfspec.RELA_SIZE
    let info = u64_at(sec.bytes, base + @elfspec.REL_INFO_OFF)
    out[i] = {
      offset: u64_at(sec.bytes, base + @elfspec.REL_OFFSET_OFF),
      sym: (info >> 32).to_int(),
      rtype: (info & 0xffffffffL).to_int(),
      addend: i64_at(sec.bytes, base + @elfspec.RELA_ADDEND_OFF),
    }
  }
  Some(out)
}

///|
fn default_rela() -> Rela {
  { offset: 0L, sym: 0, rtype: 0, addend: 0L, }
}

///|
/// Reads the `Elf64_Phdr` table (used for shared objects).
pub fn read_phdrs(
  data : Bytes,
  phoff : Int64,
  phnum : Int32,
) -> FixedArray[(Int32, Int32)]? {
  // Returns (p_type, p_flags) pairs; full layout is not needed for inputs.
  let total = phoff + (phnum * @elfspec.PHDR_SIZE).to_int64()
  if phnum < 0 || total > data.length().to_int64() {
    return None
  }
  let out = FixedArray::make(phnum, (0, 0))
  for i in 0..<phnum {
    let base = phoff.to_int() + i * @elfspec.PHDR_SIZE
    out[i] = (
      u32_at(data, base + @elfspec.PHDR_TYPE_OFF),
      u32_at(data, base + @elfspec.PHDR_FLAGS_OFF),
    )
  }
  Some(out)
}
