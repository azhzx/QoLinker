// Input file model and parsers: ObjFile (.o), SharedFile (.so) and
// ArchiveFile (.a). Ported from lld InputFiles.cpp (sequential MVP subset:
// no LTO/bitcode, no CREL, no parallel symbol interning).

///|
fn zero_rela() -> @elffile.Rela {
  { offset: 0L, sym: 0, rtype: 0, addend: 0L, }
}

///|
/// Metadata section types that never become input sections.
fn is_metadata_type(stype : Int32) -> Bool {
  if stype == @elfspec.SHT_STRTAB {
    // Alloc STRTAB (.dynstr) is real content; non-alloc is metadata.
    return true
  }
  stype == @elfspec.SHT_NULL ||
  stype == @elfspec.SHT_SYMTAB ||
  stype == @elfspec.SHT_DYNSYM ||
  stype == @elfspec.SHT_RELA ||
  stype == @elfspec.SHT_REL ||
  stype == @elfspec.SHT_GROUP ||
  stype == @elfspec.SHT_SYMTAB_SHNDX ||
  stype == SHT_GNU_versym ||
  stype == SHT_GNU_verneed ||
  stype == SHT_GNU_verdef
}

///|
/// A parsed relocatable object file.
pub(all) struct ObjFile {
  path : Bytes
  data : Bytes
  reader : @elffile.ElfReader
  // Per section-header index; None for metadata/null sections.
  sections : Array[InputSection?]
  // Per symtab index; interned SymRef for global/weak symbols.
  sym_refs : Array[SymRef?]
  raw_syms : Array[@elffile.ElfSym]
  mut symtab_idx : Int32
  mut strtab_idx : Int32
  mut alive : Bool
}

///|
/// A parsed shared object (dynamic dependency).
pub(all) struct SharedFile {
  path : Bytes
  data : Bytes
  reader : @elffile.ElfReader
  mut so_name : Bytes
  needed : Array[Bytes]
  mut is_needed : Bool
  // dynsym index -> version name ("" when unversioned)
  versyms : Array[Bytes]
}

///|
/// A parsed archive with lazy member extraction.
pub(all) struct ArchiveFile {
  path : Bytes
  data : Bytes
  archive : @elffile.Archive
  mut extracted : Map[Int32, ObjFile]
}

///|
/// Creates an InputSection from a section header.
fn make_input_section(f : ObjFile, i : Int32) -> InputSection? {
  let sh = f.reader.shdrs[i]
  guard sh.stype != @elfspec.SHT_NULL else { return None }
  let is_alloc_strtab = sh.stype == @elfspec.SHT_STRTAB &&
    has_flag(sh.flags, @elfspec.SHF_ALLOC)
  if is_metadata_type(sh.stype) && !is_alloc_strtab {
    return None
  }
  Some({
    file: ObjRef(f),
    sec_index: i,
    name: f.reader.section_name(sh),
    stype: sh.stype,
    flags: sh.flags,
    offset: sh.offset.to_int(),
    size: sh.size,
    addralign: if sh.addralign > 1L {
      sh.addralign
    } else {
      1L
    },
    link: sh.link,
    info: sh.info,
    entsize: sh.entsize,
    relas: FixedArray::make(0, zero_rela()),
    dyn_actions: None,
    out_sec: None,
    live: true,
    discarded: false,
    addr: 0L,
    out_off: 0L,
  })
}

///|
/// Parses a relocatable object; registers its symbols in the symbol table.
pub fn parse_object(ctx : Ctx, path : Bytes, data : Bytes) -> ObjFile? {
  guard @elffile.parse_elf(data) is Some(reader) else {
    ctx.diag.error("\{@support.bytes_str(path)}: not a valid ELF64 LE object")
    return None
  }
  if reader.ehdr.machine != @elfspec.EM_X86_64 {
    ctx.diag.error(
      "\{@support.bytes_str(path)}: incompatible machine type \{reader.ehdr.machine} (only EM_X86_64 is supported)",
    )
    return None
  }
  if reader.ehdr.etype != @elfspec.ET_REL {
    ctx.diag.error(
      "\{@support.bytes_str(path)}: expected a relocatable object (ET_REL)",
    )
    return None
  }
  let f : ObjFile = {
    path,
    data,
    reader,
    sections: [],
    sym_refs: [],
    raw_syms: [],
    symtab_idx: -1,
    strtab_idx: -1,
    alive: true,
  }
  // 1) Create input sections.
  for i in 0..<reader.shdrs.length() {
    f.sections.push(make_input_section(f, i))
  }
  // 2) COMDAT group resolution.
  let discarded : Map[Int32, Unit] = Map([])
  for i in 0..<reader.shdrs.length() {
    let sh = reader.shdrs[i]
    if sh.stype == @elfspec.SHT_GROUP {
      match reader.section_data(sh) {
        Some(sec) =>
          if !process_comdat_group(ctx, f, sec, sh.info, discarded) {
            return None
          }
        None => {
          ctx.diag.error(
            "\{@support.bytes_str(path)}: malformed SHT_GROUP section",
          )
          return None
        }
      }
    }
  }
  // 3) Attach relocations to their target sections.
  for i in 0..<reader.shdrs.length() {
    let sh = reader.shdrs[i]
    if sh.stype == @elfspec.SHT_RELA {
      let target = sh.info
      guard target >= 0 && target < f.sections.length() else {
        ctx.diag.error(
          "\{@support.bytes_str(path)}: relocation section points outside section list",
        )
        return None
      }
      guard f.sections[target] is Some(tsec) else { continue }
      guard reader.section_data(sh) is Some(sec) else {
        ctx.diag.error(
          "\{@support.bytes_str(path)}: unreadable relocation section",
        )
        return None
      }
      guard @elffile.read_relas(sec) is Some(relas) else {
        ctx.diag.error(
          "\{@support.bytes_str(path)}: malformed relocations in \{@support.bytes_str(reader.section_name(sh))}",
        )
        return None
      }
      tsec.relas = relas
    }
  }
  // 4) Symbols.
  for i in 0..<reader.shdrs.length() {
    let sh = reader.shdrs[i]
    if sh.stype == @elfspec.SHT_SYMTAB {
      f.symtab_idx = i
      f.strtab_idx = sh.link
      break
    }
  }
  if f.symtab_idx < 0 {
    // Empty object (no symbols): still valid.
    return Some(f)
  }
  guard reader.section_data(reader.shdrs[f.symtab_idx]) is Some(sec) else {
    ctx.diag.error("\{@support.bytes_str(path)}: unreadable symbol table")
    return None
  }
  guard @elffile.read_syms(sec) is Some(syms) else {
    ctx.diag.error("\{@support.bytes_str(path)}: malformed symbol table")
    return None
  }
  let strtab : @elffile.SecData = match
    reader.section_data(reader.shdrs[f.strtab_idx]) {
    Some(s) => s
    None => { bytes: data, offset: 0, size: 0, }
  }
  for j in 0..<syms.length() {
    let sym = syms[j]
    f.raw_syms.push(sym)
    f.sym_refs.push(None)
  }
  // Intern in two passes so that section indices are all known before any
  // lazy extraction can pull more files in.
  for j in 0..<syms.length() {
    let sym = syms[j]
    if sym.binding == @elfspec.STB_LOCAL ||
      sym.stype == @elfspec.STT_SECTION ||
      sym.stype == @elfspec.STT_FILE {
      continue
    }
    let name = @elffile.sym_name(strtab, sym.name_off)
    if sym.shndx == @elfspec.SHN_UNDEF {
      ctx.symtab.add_undefined_symbol({
        name,
        file: ObjRef(f),
        binding: sym.binding,
        stype: sym.stype,
        visibility: sym.visibility,
        section: None,
        value: 0L,
        size: 0L,
        alignment: 1L,
        archive: None,
        member_index: -1,
        version: b"",
      })
    } else if sym.shndx == @elfspec.SHN_COMMON ||
      sym.stype == @elfspec.STT_COMMON {
      ctx.symtab.add_common_symbol({
        name,
        file: ObjRef(f),
        binding: sym.binding,
        stype: sym.stype,
        visibility: sym.visibility,
        section: None,
        value: 0L,
        size: sym.size,
        alignment: if sym.value > 0L {
          sym.value
        } else {
          1L
        },
        archive: None,
        member_index: -1,
        version: b"",
      })
    } else {
      let section : InputSection? = if sym.shndx == @elfspec.SHN_ABS {
        None
      } else if sym.shndx > 0 && sym.shndx < f.sections.length() {
        f.sections[sym.shndx]
      } else {
        ctx.diag.error(
          "\{@support.bytes_str(path)}: symbol \{@support.bytes_str(name)} has bad section index \{sym.shndx}",
        )
        None
      }
      let ref_ = ctx.symtab.add_defined_symbol({
        name,
        file: ObjRef(f),
        binding: sym.binding,
        stype: sym.stype,
        visibility: sym.visibility,
        section,
        value: sym.value,
        size: sym.size,
        alignment: 1L,
        archive: None,
        member_index: -1,
        version: b"",
      })
      f.sym_refs[j] = Some(ref_)
    }
  }
  // Second pass: undefined/common references keep their SymRef too (used by
  // relocation resolution and GOT/PLT bookkeeping).
  for j in 0..<syms.length() {
    let sym = syms[j]
    if sym.binding == @elfspec.STB_LOCAL ||
      sym.stype == @elfspec.STT_SECTION ||
      sym.stype == @elfspec.STT_FILE {
      continue
    }
    if f.sym_refs[j] is None {
      let name = @elffile.sym_name(strtab, sym.name_off)
      f.sym_refs[j] = ctx.symtab.find(name)
    }
  }
  Some(f)
}

///|
/// Resolves one COMDAT group. Returns false on malformed input.
fn process_comdat_group(
  ctx : Ctx,
  f : ObjFile,
  sec : @elffile.SecData,
  sig_sym : Int32,
  discarded : Map[Int32, Unit],
) -> Bool {
  // entries[0] is the flag word; GRP_COMDAT groups dedup by signature.
  if sec.size < 4 {
    return false
  }
  let flags = @elffile.u32_at(sec.bytes, sec.offset)
  if flags != @elfspec.GRP_COMDAT {
    // Non-COMDAT groups (rare): keep contents.
    return true
  }
  // Signature = name of symbol sh_info in this file's symbol table.
  let sig : Bytes = if f.symtab_idx >= 0 &&
    sig_sym >= 0 &&
    sig_sym < f.raw_syms.length() {
    match f.reader.section_data(f.reader.shdrs[f.strtab_idx]) {
      Some(strtab) => @elffile.sym_name(strtab, f.raw_syms[sig_sym].name_off)
      None => b""
    }
  } else {
    b""
  }
  let prevailing = match ctx.symtab.comdat_groups.get(sig) {
    Some(_) => false
    None => {
      ctx.symtab.comdat_groups[sig] = ObjRef(f)
      true
    }
  }
  if !prevailing {
    for k in 1..<(sec.size / 4) {
      let member = @elffile.u32_at(sec.bytes, sec.offset + k * 4)
      discarded[member] = ()
    }
  }
  true
}

///|
/// Parses a shared object and registers its dynamic symbols.
pub fn parse_shared(ctx : Ctx, path : Bytes, data : Bytes) -> SharedFile? {
  guard @elffile.parse_elf(data) is Some(reader) else {
    ctx.diag.error(
      "\{@support.bytes_str(path)}: not a valid ELF64 LE shared object",
    )
    return None
  }
  if reader.ehdr.etype != @elfspec.ET_DYN {
    ctx.diag.error(
      "\{@support.bytes_str(path)}: expected a shared object (ET_DYN)",
    )
    return None
  }
  let f : SharedFile = {
    path,
    data,
    reader,
    so_name: base_name(path),
    needed: [],
    is_needed: false,
    versyms: [],
  }
  // Locate dynamic metadata sections.
  let mut dynsec : @elffile.SecData? = None
  let mut dynstr : @elffile.SecData? = None
  let mut dynsym : @elffile.SecData? = None
  let mut versym : @elffile.SecData? = None
  let mut verneed : @elffile.SecData? = None
  let mut dynstr_idx = -1
  for i in 0..<reader.shdrs.length() {
    let sh = reader.shdrs[i]
    match sh.stype {
      t if t == @elfspec.SHT_DYNAMIC => dynsec = reader.section_data(sh)
      t if t == @elfspec.SHT_DYNSYM => {
        dynsym = reader.section_data(sh)
        dynstr_idx = sh.link
        dynstr = reader.section_data(reader.shdrs[sh.link])
      }
      t if t == @elfspec.SHT_STRTAB && dynstr is None =>
        dynstr = reader.section_data(sh)
      t if t == SHT_GNU_versym => versym = reader.section_data(sh)
      t if t == SHT_GNU_verneed => verneed = reader.section_data(sh)
      _ => ()
    }
  }
  // Version index -> name map from verneed.
  let ver_names : Map[Int32, Bytes] = Map([])
  match verneed {
    Some(vn) => parse_verneed(vn, ver_names)
    None => ()
  }
  // Per-dynsym version names.
  match (dynsym, versym) {
    (Some(ds), Some(vs)) => {
      guard @elffile.read_syms(ds) is Some(syms) else { return None }
      for j in 0..<syms.length() {
        let mut vname : Bytes = b""
        if vs.offset + j * 2 + 2 <= vs.offset + vs.size {
          let idx = @elffile.u16_at(vs.bytes, vs.offset + j * 2) & 0x7fff
          if idx >= 2 {
            match ver_names.get(idx) {
              Some(n) => vname = n
              None => ()
            }
          }
        }
        f.versyms.push(vname)
      }
    }
    _ => ()
  }
  // Walk .dynamic for DT_NEEDED/DT_SONAME.
  let strtab = dynstr
  match dynsec {
    Some(sec) => {
      let n = sec.size / @elfspec.DYN_SIZE
      for k in 0..<n {
        let base = sec.offset + k * @elfspec.DYN_SIZE
        let tag = @elffile.u64_at(sec.bytes, base + @elfspec.DYN_TAG_OFF)
        let val = @elffile.u64_at(sec.bytes, base + @elfspec.DYN_VAL_OFF)
        if tag == 0L {
          break
        }
        if tag == @elfspec.DT_NEEDED.to_int64() {
          match strtab {
            Some(st) => f.needed.push(dyn_string(st, val.to_int()))
            None => ()
          }
        } else if tag == @elfspec.DT_SONAME.to_int64() {
          match strtab {
            Some(st) => f.so_name = dyn_string(st, val.to_int())
            None => ()
          }
        }
      }
    }
    None => ()
  }
  // Register defined global symbols (with version suffixes).
  match dynsym {
    Some(ds) => {
      guard @elffile.read_syms(ds) is Some(syms) else { return None }
      for j in 0..<syms.length() {
        let sym = syms[j]
        if sym.binding == @elfspec.STB_LOCAL || sym.shndx == @elfspec.SHN_UNDEF {
          continue
        }
        let mut name = @elffile.sym_name(dynstr.unwrap(), sym.name_off)
        if j < f.versyms.length() {
          let v = f.versyms[j]
          if v.length() > 0 {
            name = concat_name_version(name, v)
          }
        }
        ctx.symtab.add_shared_symbol({
          name,
          file: SharedRef(f),
          binding: sym.binding,
          stype: sym.stype,
          visibility: sym.visibility,
          section: None,
          value: 0L,
          size: sym.size,
          alignment: 1L,
          archive: None,
          member_index: -1,
          version: b"",
        })
      }
    }
    None => ()
  }
  Some(f)
}

///|
/// Parses .gnu.version_r: version index -> version name.
fn parse_verneed(vn : @elffile.SecData, out : Map[Int32, Bytes]) -> Unit {
  let mut off = vn.offset
  let end = vn.offset + vn.size
  while off + @elfspec.VERNEED_SIZE <= end {
    let cnt = @elffile.u16_at(vn.bytes, off + @elfspec.VERNEED_CNT_OFF)
    let file_off = @elffile.u32_at(vn.bytes, off + @elfspec.VERNEED_FILE_OFF)
    let file_name = dyn_string(vn, file_off)
    let _ = file_name
    let mut aux = off +
      @elffile.u32_at(vn.bytes, off + @elfspec.VERNEED_AUX_OFF)
    for _ in 0..<cnt {
      if aux + @elfspec.VERNAUX_SIZE > end {
        break
      }
      let other = @elffile.u16_at(vn.bytes, aux + @elfspec.VERNAUX_OTHER_OFF) &
        0x7fff
      let name_off = @elffile.u32_at(vn.bytes, aux + @elfspec.VERNAUX_NAME_OFF)
      out[other] = dyn_string(vn, name_off)
      let next = @elffile.u32_at(vn.bytes, aux + @elfspec.VERNAUX_NEXT_OFF)
      if next == 0 {
        break
      }
      aux += next
    }
    let next = @elffile.u32_at(vn.bytes, off + @elfspec.VERNEED_NEXT_OFF)
    if next == 0 {
      break
    }
    off += next
  }
}

///|
/// Reads a NUL-terminated string at `off` inside a string-table slice.
fn dyn_string(sec : @elffile.SecData, off : Int32) -> Bytes {
  @support.cstring_at(sec.bytes, sec.offset + off, sec.offset + sec.size)
}

///|
fn base_name(path : Bytes) -> Bytes {
  let mut last = 0
  for i in 0..<path.length() {
    if path[i] == b'/' {
      last = i + 1
    }
  }
  path[last:].to_owned()
}

///|
/// Concatenates "name@version".
fn concat_name_version(name : Bytes, ver : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(name[:])
  buf.write_byte(b'@')
  buf.write_bytes(ver[:])
  buf.to_bytes()
}

///|
/// Parses an archive and registers lazy symbols for its members.
pub fn parse_archive_file(
  ctx : Ctx,
  path : Bytes,
  data : Bytes,
) -> ArchiveFile? {
  guard @elffile.parse_archive(data) is Some(ar) else {
    ctx.diag.error("\{@support.bytes_str(path)}: not a valid archive")
    return None
  }
  let f : ArchiveFile = { path, data, archive: ar, extracted: Map([]), }
  if ctx.config.whole_archive {
    for i in 0..<ar.members.length() {
      Ctx::extract_member(ctx, f, i)
    }
  }
  for pair in ar.symbols {
    let name = pair.0
    let member_idx = pair.1
    ctx.symtab.add_lazy_symbol({
      name,
      file: ArchiveRef(f),
      binding: @elfspec.STB_GLOBAL,
      stype: @elfspec.STT_NOTYPE,
      visibility: @elfspec.STV_DEFAULT,
      section: None,
      value: 0L,
      size: 0L,
      alignment: 1L,
      archive: Some(f),
      member_index: member_idx,
      version: b"",
    })
  }
  Some(f)
}
