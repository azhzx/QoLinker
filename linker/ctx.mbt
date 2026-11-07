// Link context: configuration, diagnostics, all parsed files, and the
// lazy archive-extraction entry point.

///|
pub struct Ctx {
  config : Config
  diag : @support.Diag
  symtab : SymbolTable
  files : Array[FileRef]
  // Common symbol allocation results (offset within .bss per symbol name),
  // filled by the writer; absolute VA = common_bss.addr + offset.
  common_alloc : Map[Bytes, Int64]
  mut common_bss : OutSec?
  mut script : Script?
  script_outsecs : Map[Bytes, OutSec]
  mut version_script : VersionScript?
}

///|
pub fn Ctx::new(config : Config, diag : @support.Diag) -> Ctx {
  let symtab = SymbolTable::new(diag)
  let ctx : Ctx = {
    config,
    diag,
    symtab,
    files: [],
    common_alloc: Map([]),
    common_bss: None,
    script: None,
    script_outsecs: Map([]),
    version_script: None,
  }
  symtab.ctx = Some(ctx)
  ctx
}

///|
/// Loads one input file, dispatching on its magic.
pub fn Ctx::load_file(self : Ctx, path : Bytes) -> Unit {
  guard @support.read_file(path) is Some(data) else {
    self.diag.error("cannot open \{@support.bytes_str(path)}")
    return
  }
  if data.length() >= 4 &&
    data[0] == b'\x7f' &&
    data[1] == b'E' &&
    data[2] == b'L' &&
    data[3] == b'F' {
    match @elffile.parse_elf(data) {
      Some(reader) =>
        match reader.ehdr.etype {
          t if t == @elfspec.ET_REL =>
            match parse_object(self, path, data) {
              Some(obj) => self.files.push(ObjRef(obj))
              None => ()
            }
          t if t == @elfspec.ET_DYN =>
            match parse_shared(self, path, data) {
              Some(sh) => self.files.push(SharedRef(sh))
              None => ()
            }
          _ =>
            self.diag.error(
              "\{@support.bytes_str(path)}: unsupported ELF file type \{reader.ehdr.etype}",
            )
        }
      None =>
        self.diag.error(
          "\{@support.bytes_str(path)}: not a valid ELF64 LE file",
        )
    }
  } else if data.length() >= 8 &&
    (data[:8] == b"!<arch>\n" || data[:8] == b"!<thin>\n") {
    match parse_archive_file(self, path, data) {
      Some(ar) => self.files.push(ArchiveRef(ar))
      None => ()
    }
  } else {
    self.diag.error("\{@support.bytes_str(path)}: unknown file type")
  }
}

///|
/// Parses one archive member object (lld LazySymbol::extract). Safe to call
/// repeatedly; only the first call parses.
pub fn Ctx::extract_member(
  self : Ctx,
  archive : ArchiveFile,
  member_index : Int32,
) -> Unit {
  if archive.extracted.contains(member_index) {
    return
  }
  guard member_index >= 0 && member_index < archive.archive.members.length() else {
    self.diag.error(
      "\{@support.bytes_str(archive.path)}: bad archive member index",
    )
    return
  }
  let mem = archive.archive.members[member_index]
  let member_path = concat_member_path(archive.path, mem.name)
  let data : Bytes? = if mem.thin {
    @support.read_file(join_member_dir(archive.path, mem.name))
  } else {
    match archive.archive.member_data(mem) {
      Some(sec) => Some(sec.bytes[sec.offset:sec.offset + sec.size].to_owned())
      None => None
    }
  }
  guard data is Some(data) else {
    self.diag.error("cannot read \{@support.bytes_str(member_path)}")
    return
  }
  match parse_object(self, member_path, data) {
    Some(obj) => {
      archive.extracted[member_index] = obj
      self.files.push(ObjRef(obj))
    }
    None => ()
  }
}

///|
fn concat_member_path(archive : Bytes, member : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(archive[:])
  buf.write_byte(b'(')
  buf.write_bytes(member[:])
  buf.write_byte(b')')
  buf.to_bytes()
}

///|
/// Sibling path for thin-archive members.
fn join_member_dir(archive : Bytes, member : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  let mut last = 0
  for i in 0..<archive.length() {
    if archive[i] == b'/' {
      last = i + 1
    }
  }
  buf.write_bytes(archive[:last])
  buf.write_bytes(member[:])
  buf.to_bytes()
}

///|
/// Extracts every member of an archive (--whole-archive).
fn Ctx::extract_all(self : Ctx, archive : ArchiveFile) -> Unit {
  for i in 0..<archive.archive.members.length() {
    Ctx::extract_member(self, archive, i)
  }
}
