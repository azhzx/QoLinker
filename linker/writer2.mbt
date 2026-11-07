// Writer part 2: program headers, address/offset assignment, and output
// emission. Ports of the corresponding lld Writer.cpp routines. The
// "combined" section list is [elfHeader pseudo, programHeaders pseudo,
// ...real sorted sections]; pseudo sections take no part in the section
// header table and get hardcoded header addresses.

///|
/// Smallest value >= off with value ≡ addr (mod align) — lld
/// alignTo(off, align, addr).
fn align_congruent(off : Int64, align : Int64, addr : Int64) -> Int64 {
  let skew = addr % align
  let diff = off - skew
  if diff <= 0L {
    skew
  } else {
    skew + @support.align_to(diff, align)
  }
}

///|
/// Port of Writer::createPhdrs (static-link subset: interp/dynamic/TLS
/// segments arrive with dynamic linking).
fn create_phdrs(
  ctx : Ctx,
  combined : Array[OutSec],
  elfhdr : OutSec,
  phdrsec : OutSec,
) -> Array[Phdr] {
  let phdrs : Array[Phdr] = []
  // PT_PHDR covers the program headers themselves.
  phdrs.push({
    ptype: @elfspec.PT_PHDR,
    flags: @elfspec.PF_R,
    first: Some(phdrsec),
    last: Some(phdrsec),
    memsz_extra: 0L,
  })
  // First PT_LOAD carries the ELF + program headers; real R sections join.
  phdrs.push({
    ptype: @elfspec.PT_LOAD,
    flags: @elfspec.PF_R,
    first: Some(elfhdr),
    last: Some(phdrsec),
    memsz_extra: 0L,
  })
  // PT_INTERP must be the second entry if .interp exists (lld).
  let mut interp_sec : OutSec? = None
  let mut dynamic_sec : OutSec? = None
  for sec in combined {
    if sec.name == b".interp" {
      interp_sec = Some(sec)
    } else if sec.name == b".dynamic" {
      dynamic_sec = Some(sec)
    }
  }
  match interp_sec {
    Some(ip) =>
      phdrs.push({
        ptype: @elfspec.PT_INTERP,
        flags: @elfspec.PF_R,
        first: Some(ip),
        last: Some(ip),
        memsz_extra: 0L,
      })
    None => ()
  }
  // Sections after a RELRO run start a fresh LOAD (lld relroEnds).
  let relro_ends : Map[Bytes, Unit] = Map([])
  let mut in_relro = false
  for sec in combined {
    if !sec.is_alloc() {
      continue
    }
    if sec.relro {
      in_relro = true
    } else if in_relro {
      in_relro = false
      relro_ends[sec.name] = ()
    }
  }
  let mut cur_flags = @elfspec.PF_R
  let mut last_was_nobits = false
  // The current PT_LOAD is tracked separately from phdrs[]: entries like
  // PT_INTERP may sit after it in the array (lld keeps a `load` pointer).
  let mut load_idx = 1 // LOAD1
  for sec in combined {
    if !sec.is_alloc() {
      continue
    }
    let new_flags = sec.phdr_flags()
    let mut incompatible = new_flags != cur_flags
    if last_was_nobits && sec.stype != @elfspec.SHT_NOBITS {
      incompatible = true
    }
    if relro_ends.contains(sec.name) {
      incompatible = true
    }
    if incompatible {
      phdrs.push({
        ptype: @elfspec.PT_LOAD,
        flags: new_flags,
        first: Some(sec),
        last: Some(sec),
        memsz_extra: 0L,
      })
      cur_flags = new_flags
      load_idx = phdrs.length() - 1
    } else {
      let cur = phdrs[load_idx]
      cur.flags = cur.flags | new_flags
      cur.last = Some(sec)
    }
    let cur = phdrs[load_idx]
    sec.load_idx = load_idx
    sec.load_first = same_outsec(cur.first, sec)
    last_was_nobits = sec.stype == @elfspec.SHT_NOBITS
  }
  // PT_TLS: one segment covering all TLS sections.
  let mut tls : Phdr? = None
  for sec in combined {
    if sec.is_alloc() && has_flag(sec.flags, @elfspec.SHF_TLS) {
      match tls {
        None => {
          let p : Phdr = {
            ptype: @elfspec.PT_TLS,
            flags: @elfspec.PF_R,
            first: Some(sec),
            last: Some(sec),
            memsz_extra: 0L,
          }
          phdrs.push(p)
          tls = Some(p)
        }
        Some(p) => p.last = Some(sec)
      }
    }
  }
  // PT_DYNAMIC.
  match dynamic_sec {
    Some(dn) =>
      phdrs.push({
        ptype: @elfspec.PT_DYNAMIC,
        flags: dn.phdr_flags(),
        first: Some(dn),
        last: Some(dn),
        memsz_extra: 0L,
      })
    None => ()
  }
  // RELRO entries (p_align = 1).
  let mut active : Phdr? = None
  let relros : Array[Phdr] = []
  for sec in combined {
    if !sec.is_alloc() {
      continue
    }
    if sec.relro {
      match active {
        None => {
          let p : Phdr = {
            ptype: @elfspec.PT_GNU_RELRO,
            flags: @elfspec.PF_R,
            first: Some(sec),
            last: Some(sec),
            memsz_extra: 0L,
          }
          relros.push(p)
          active = Some(p)
        }
        Some(p) => p.last = Some(sec)
      }
    } else {
      active = None
    }
  }
  for p in relros {
    phdrs.push(p)
  }
  // PT_GNU_STACK (non-executable by default, like lld).
  phdrs.push({
    ptype: @elfspec.PT_GNU_STACK,
    flags: @elfspec.PF_R | @elfspec.PF_W,
    first: None,
    last: None,
    memsz_extra: 0L,
  })
  let _ = ctx
  phdrs
}

///|
fn same_outsec(a : OutSec?, b : OutSec) -> Bool {
  match a {
    Some(x) => x.oid == b.oid
    None => false
  }
}

///|
/// Fixes segment-start addresses (lld fixSectionAlignments: page-align dot
/// on exec/non-exec segment transitions under -z separate-code) and assigns
/// every output section a virtual address.
fn assign_addresses(ctx : Ctx, combined : Array[OutSec], phnum : Int32) -> Unit {
  let page = ctx.config.page_size
  let elfhdr = combined[0]
  let phdrsec = combined[1]
  elfhdr.addr = ctx.config.image_base
  elfhdr.size = 64L
  elfhdr.offset = 0L
  phdrsec.addr = ctx.config.image_base + 64L
  phdrsec.offset = 64L
  let mut dot = ctx.config.image_base +
    64L +
    (phnum * @elfspec.PHDR_SIZE).to_int64()
  // Script mode (`. = base`): the first section starts exactly at base —
  // headers stay unmapped and no page jumps between segments (lld keeps
  // the script dot flowing; file offsets stay congruent).
  let script_mode = match ctx.script {
    Some(s) => s.image_base is Some(_)
    None => false
  }
  let mut first_real = true
  for sec in combined {
    if !sec.is_alloc() || sec.pseudo {
      continue
    }
    if script_mode && first_real {
      dot = ctx.config.image_base
      first_real = false
    }
    if sec.load_first && sec.load_idx > 1 && !script_mode {
      // New segment beyond LOAD1 (lld fixSectionAlignments default branch):
      // advance to the next page while preserving the in-page position, to
      // avoid padding in file contents.
      dot = @support.align_to(dot, page) + dot % page
    }
    let addr = @support.align_to(
      dot,
      if sec.addralign > 1L {
        sec.addralign
      } else {
        1L
      },
    )
    sec.addr = addr
    dot = addr + sec.size
  }
}

///|
/// Propagates output-section addresses down to input sections
/// (lld: InputSection::getVA = outSec->addr + outOffset).
fn assign_input_addrs(combined : Array[OutSec]) -> Unit {
  for sec in combined {
    if sec.pseudo {
      continue
    }
    for input in sec.inputs {
      input.addr = sec.addr + input.out_off
    }
  }
}

///|
/// Prebuilt synthetic section contents, produced after address assignment
/// and before offset assignment (sizes must be known for layout).
pub(all) struct Prebuilt {
  symtab_content : Bytes
  local_count : Int32
  strtab_content : Bytes
  shstr_content : Bytes
  name_off : Map[Bytes, Int32]
  got_content : Bytes?
  got_sec : OutSec?
  comment_content : Bytes?
}

///|
/// Builds all synthetic contents and sets their OutSec sizes.
fn build_synthetic_contents(
  ctx : Ctx,
  secs : Array[OutSec],
  symtab : OutSec,
  strtab_sec : OutSec,
  shstrtab : OutSec,
  got : OutSec?,
  scan : ScanResult,
  bss : OutSec?,
  comment : OutSec,
) -> Prebuilt {
  let shstr = StrTabBuilder::new()
  let name_off : Map[Bytes, Int32] = Map([])
  for sec in secs {
    name_off[sec.name] = shstr.add(sec.name)
  }
  let strb = StrTabBuilder::new()
  let (symtab_content, local_count) = build_symtab(ctx, strb, bss)
  symtab.size = symtab_content.length().to_int64()
  symtab.entsize = 24L
  strtab_sec.size = strb.size().to_int64()
  shstrtab.size = shstr.size().to_int64()
  let mut got_content : Bytes? = None
  match got {
    Some(g) => {
      let buf = @buffer.Buffer()
      for ref_ in scan.got_syms {
        buf.write_int64_le(ref_.sym.get_va(ctx))
      }
      let content = buf.to_bytes()
      g.size = content.length().to_int64()
      got_content = Some(content)
    }
    None => ()
  }
  let comment_content : Bytes? = if comment.oid == 0 {
    None
  } else {
    let buf = @buffer.Buffer()
    buf.write_bytes(b"Linker: QoLinker MVP\x00"[:])
    comment.size = buf.length().to_int64()
    Some(buf.to_bytes())
  }
  {
    symtab_content,
    local_count,
    strtab_content: strb.to_bytes(),
    shstr_content: shstr.to_bytes(),
    name_off,
    got_content,
    got_sec: got,
    comment_content,
  }
}

///|
/// Port of Writer::assignFileOffsets + computeFileOffset.
fn assign_offsets(ctx : Ctx, combined : Array[OutSec], phnum : Int32) -> Unit {
  let mut off = 64L + (phnum * @elfspec.PHDR_SIZE).to_int64()
  let load_first_off : Map[Int32, Int64] = Map([])
  let load_first_addr : Map[Int32, Int64] = Map([])
  // LOAD1 (phdr index 1) starts with the ELF header pseudo-section.
  load_first_off[1] = 0L
  load_first_addr[1] = ctx.config.image_base
  for sec in combined {
    if !sec.is_alloc() || sec.pseudo {
      continue
    }
    if sec.load_idx >= 0 && sec.load_first {
      // First real section of a PT_LOAD: congruent offset/address.
      off = align_congruent(off, 4096L, sec.addr)
      load_first_off[sec.load_idx] = off
      load_first_addr[sec.load_idx] = sec.addr
      sec.offset = off
      if sec.stype != @elfspec.SHT_NOBITS {
        off += sec.size
      }
    } else if sec.load_idx >= 0 && sec.stype == @elfspec.SHT_NOBITS {
      // NOBITS keeps the file offset monotonically increasing.
      sec.offset = off
    } else if sec.load_idx >= 0 {
      let base_off = load_first_off.get(sec.load_idx).unwrap_or(0L)
      let base_addr = load_first_addr.get(sec.load_idx).unwrap_or(0L)
      off = base_off + (sec.addr - base_addr)
      sec.offset = off
      off += sec.size
    } else {
      sec.offset = off
      off += sec.size
    }
  }
  // Non-alloc sections follow, uncovered by any PT_LOAD.
  for sec in combined {
    if sec.is_alloc() || sec.pseudo {
      continue
    }
    sec.offset = @support.align_to(
      off,
      if sec.addralign > 1L {
        sec.addralign
      } else {
        1L
      },
    )
    off = sec.offset + sec.size
  }
}

///|
/// Computes program header fields from section coverage. Returns the tuple
/// (offset, vaddr, filesz, memsz, align).
fn phdr_values(
  ctx : Ctx,
  combined : Array[OutSec],
  p : Phdr,
  phnum : Int32,
) -> (Int64, Int64, Int64, Int64, Int64) {
  if p.ptype == @elfspec.PT_PHDR {
    let size = (phnum * @elfspec.PHDR_SIZE).to_int64()
    return (64L, ctx.config.image_base + 64L, size, size, 8L)
  }
  if p.ptype == @elfspec.PT_GNU_STACK {
    return (0L, 0L, 0L, p.memsz_extra, 0L)
  }
  match (p.first, p.last) {
    (Some(first), Some(last)) => {
      let start = index_of_oid(combined, first.oid)
      let stop = index_of_oid(combined, last.oid)
      let mut f_end : Int64 = 0L
      let mut m_end : Int64 = 0L
      let mut any = false
      let mut i = start
      while i >= 0 && i <= stop {
        let sec = combined[i]
        if !any {
          any = true
          f_end = sec.offset
          m_end = sec.addr
        }
        if sec.stype != @elfspec.SHT_NOBITS {
          let e = sec.offset + sec.size
          if e > f_end {
            f_end = e
          }
        }
        let e2 = sec.addr + sec.size
        if e2 > m_end {
          m_end = e2
        }
        i += 1
      }
      if !any {
        return (0L, 0L, 0L, 0L, 1L)
      }
      let align = if p.ptype == @elfspec.PT_LOAD { 4096L } else { 1L }
      (
        first.offset,
        first.addr,
        f_end - first.offset,
        m_end - first.addr,
        align,
      )
    }
    _ => (0L, 0L, 0L, 0L, 1L)
  }
}

///|
fn index_of_oid(combined : Array[OutSec], oid : Int32) -> Int32 {
  for i in 0..<combined.length() {
    if combined[i].oid == oid {
      return i
    }
  }
  -1
}

///|
/// Builds the final file: headers, section contents, section header table.
fn write_output(
  ctx : Ctx,
  secs : Array[OutSec],
  combined : Array[OutSec],
  phdrs : Array[Phdr],
  pre : Prebuilt,
  scan : ScanResult,
  symtab : OutSec,
  strtab_sec : OutSec,
  shstrtab : OutSec,
  entry : Int64,
  shstrndx : Int32,
  phnum : Int32,
  interp : OutSec?,
  dynsym_sec : OutSec?,
  dynstr_sec : OutSec?,
  hash_sec : OutSec?,
  reladyn_sec : OutSec?,
  relaplt_sec : OutSec?,
  got : OutSec?,
  gotplt : OutSec?,
  plt : OutSec?,
  dynamic_sec : OutSec?,
) -> Unit {
  let symtab_content = pre.symtab_content
  let local_count = pre.local_count
  let name_off = pre.name_off
  // File layout summary.
  let mut max_end : Int64 = 0L
  for sec in secs {
    if sec.stype != @elfspec.SHT_NOBITS && sec.shndx >= 0 {
      let end = sec.offset + sec.size
      if end > max_end {
        max_end = end
      }
    }
  }
  // Dynamic content (needs final addresses).
  let dynout : DynOut? = if dynsym_sec is Some(dsym) {
    match (dynstr_sec, hash_sec, reladyn_sec) {
      (Some(dstr), Some(hsec), Some(rdn)) => {
        let dynstrb = StrTabBuilder::new()
        let dynsyms = scan_needs_dynsym(ctx, scan)
        for ref_ in dynsyms {
          ignore(dynstrb.add(ref_.sym.name))
        }
        let needed : Array[Bytes] = []
        for fref in ctx.files {
          match fref {
            SharedRef(sf) => {
              needed.push(sf.so_name)
              ignore(dynstrb.add(sf.so_name))
            }
            _ => ()
          }
        }
        let out = build_dyn_out(
          ctx, scan, needed, dynstrb, dstr, dsym, hsec, rdn, relaplt_sec, got, gotplt,
          plt, combined,
        )
        // .dynsym content built here must match the size computed at layout
        // time; the list is deterministic so both agree.
        dsym.size = out.dynsym.length().to_int64()
        dstr.size = out.dynstr.length().to_int64()
        hsec.size = out.hash.length().to_int64()
        rdn.size = out.reladyn.length().to_int64()
        match relaplt_sec {
          Some(rpl) => rpl.size = out.relaplt.length().to_int64()
          None => ()
        }
        Some(out)
      }
      _ => None
    }
  } else {
    None
  }
  let shoff = @support.align_to(max_end, 8L)
  let shnum = secs.length() + 1
  let file_size = shoff + (shnum * @elfspec.SHDR_SIZE).to_int64()
  // Write out.
  let out_path = ctx.config.output
  guard @support.create_file(out_path) is Some(fd) else {
    ctx.diag.error("cannot open output file \{@support.bytes_str(out_path)}")
    return
  }
  let _ = @support.set_file_size(fd, file_size)
  // ELF header.
  let eh = @buffer.Buffer()
  eh.write_bytes(b"\x7fELF\x02\x01\x01\x00"[:])
  for _ in 0..<8 {
    eh.write_byte(b'\x00')
  }
  eh.write_uint16_le(
    (if ctx.config.shared || ctx.config.pie {
      @elfspec.ET_DYN
    } else {
      @elfspec.ET_EXEC
    }).to_uint16(),
  )
  eh.write_uint16_le(@elfspec.EM_X86_64.to_uint16())
  eh.write_uint_le(1)
  eh.write_int64_le(entry)
  eh.write_int64_le(64L) // e_phoff
  eh.write_int64_le(shoff)
  eh.write_uint_le(0) // e_flags
  eh.write_uint16_le(64) // e_ehsize
  eh.write_uint16_le(@elfspec.PHDR_SIZE.to_uint16())
  eh.write_uint16_le(phnum.to_uint16())
  eh.write_uint16_le(@elfspec.SHDR_SIZE.to_uint16())
  eh.write_uint16_le(shnum.to_uint16())
  eh.write_uint16_le(shstrndx.to_uint16()) // e_shstrndx
  let _ = @support.write_at(fd, 0L, eh.to_bytes())
  // Program headers.
  let phbuf = @buffer.Buffer()
  for p in phdrs {
    let (offset, vaddr, filesz, memsz, align) = phdr_values(
      ctx, combined, p, phnum,
    )
    phbuf.write_uint_le(p.ptype.reinterpret_as_uint())
    phbuf.write_uint_le(p.flags.reinterpret_as_uint())
    phbuf.write_int64_le(offset)
    phbuf.write_int64_le(vaddr)
    phbuf.write_int64_le(vaddr) // p_paddr
    phbuf.write_int64_le(filesz)
    phbuf.write_int64_le(memsz)
    phbuf.write_int64_le(align)
  }
  let _ = @support.write_at(fd, 64L, phbuf.to_bytes())
  // Section contents.
  for sec in secs {
    if sec.shndx < 0 || sec.stype == @elfspec.SHT_NOBITS || sec.size == 0L {
      continue
    }
    let content : Bytes? = match dynout {
      Some(d) =>
        if got is Some(g) && sec.oid == g.oid {
          Some(d.got)
        } else if gotplt is Some(gp) && sec.oid == gp.oid {
          Some(d.gotplt)
        } else if plt is Some(pl) && sec.oid == pl.oid {
          Some(d.plt)
        } else if dynsym_sec is Some(t) && sec.oid == t.oid {
          Some(d.dynsym)
        } else if dynstr_sec is Some(t) && sec.oid == t.oid {
          Some(d.dynstr)
        } else if hash_sec is Some(t) && sec.oid == t.oid {
          Some(d.hash)
        } else if reladyn_sec is Some(t) && sec.oid == t.oid {
          Some(d.reladyn)
        } else if relaplt_sec is Some(t) && sec.oid == t.oid {
          Some(d.relaplt)
        } else if dynamic_sec is Some(t) && sec.oid == t.oid {
          Some(d.dynamic)
        } else if interp is Some(t) && sec.oid == t.oid {
          Some(d.interp)
        } else {
          match sec.synth {
            SymTab => Some(symtab_content)
            StrTab => Some(pre.strtab_content)
            ShStrTab => Some(pre.shstr_content)
            Comment => pre.comment_content
            Got => pre.got_content
            NotSynth => build_regular_content(ctx, sec, scan, got, plt)
            _ => None
          }
        }
      None =>
        match sec.synth {
          SymTab => Some(symtab_content)
          StrTab => Some(pre.strtab_content)
          ShStrTab => Some(pre.shstr_content)
          Comment => pre.comment_content
          Got => pre.got_content
          NotSynth => build_regular_content(ctx, sec, scan, got, plt)
          _ => None
        }
    }
    match content {
      Some(c) => {
        if plt is Some(pl) && sec.oid == pl.oid {
          if gotplt is Some(gp) {
            let arr = FixedArray::make(c.length(), b'\x00')
            for i in 0..<c.length() {
              arr[i] = c[i]
            }
            patch_plt(arr, pl.addr, gp.addr, scan.plt_syms.length())
            let _ = @support.write_at(fd, sec.offset, Bytes::from_array(arr[:]))
            continue
          }
        }
        if !@support.write_at(fd, sec.offset, c) {
          ctx.diag.error("write failed for \{@support.bytes_str(sec.name)}")
        }
      }
      None => ()
    }
  }
  // Section header table: [null] + one per real section (list order).
  let shb = @buffer.Buffer()
  for _ in 0..<(@elfspec.SHDR_SIZE / 8) {
    shb.write_int64_le(0L)
  }
  for sec in secs {
    write_shdr(
      shb,
      sec,
      name_off.get(sec.name).unwrap_or(0),
      strtab_sec,
      local_count,
      dynsym_sec,
      dynstr_sec,
      gotplt,
    )
  }
  let _ = @support.write_at(fd, shoff, shb.to_bytes())
  if !ctx.config.shared {
    @support.make_executable(fd)
  }
  @support.close_fd(fd)
}

///|
/// Concatenates input section contents, applying relocations (lld
/// InputSection::writeTo + relocateOne).
fn build_regular_content(
  ctx : Ctx,
  sec : OutSec,
  scan : ScanResult,
  got : OutSec?,
  plt : OutSec?,
) -> Bytes? {
  let buf = @buffer.Buffer()
  for input in sec.inputs {
    match input.content() {
      Some(d) => {
        let base = FixedArray::make(d.size, b'\x00')
        for i in 0..<d.size {
          base[i] = d.bytes[d.offset + i]
        }
        if !apply_relocs(ctx, scan, input_file_of(input), input, base, got, plt) {
          return None
        }
        // Alignment padding before this input section.
        let target = input.out_off
        let cur = buf.length().to_int64()
        if target > cur {
          let pad = (target - cur).to_int()
          for _ in 0..<pad {
            buf.write_byte(b'\x00')
          }
        }
        buf.write_bytes(Bytes::from_array(base[:])[:])
      }
      None => ()
    }
  }
  Some(buf.to_bytes())
}

///|
fn input_file_of(sec : InputSection) -> ObjFile {
  match sec.file {
    ObjRef(f) => f
    _ => abort("input section without object file")
  }
}

///|
/// Serializes one section header.
fn write_shdr(
  buf : @buffer.Buffer,
  sec : OutSec,
  name_off : Int32,
  strtab_sec : OutSec,
  local_count : Int32,
  dynsym_sec : OutSec?,
  dynstr_sec : OutSec?,
  gotplt : OutSec?,
) -> Unit {
  let mut link = 0
  let mut info = 0
  let mut entsize = sec.entsize
  if sec.synth is SymTab {
    link = strtab_sec.shndx
    info = local_count
    entsize = 24L
  }
  if sec.synth is DynSymTab {
    link = match dynstr_sec {
      Some(s) => s.shndx
      None => 0
    }
    info = 1
    entsize = 24L
  }
  if sec.synth is RelaDyn {
    link = match dynsym_sec {
      Some(s) => s.shndx
      None => 0
    }
    entsize = 24L
  }
  if sec.synth is RelaPlt {
    link = match dynsym_sec {
      Some(s) => s.shndx
      None => 0
    }
    info = match gotplt {
      Some(g) => g.shndx
      None => 0
    }
    entsize = 24L
  }
  if sec.synth is ShStrTab || sec.synth is StrTab || sec.synth is DynStrTab {
    entsize = 0L
  }
  buf.write_uint_le(name_off.reinterpret_as_uint())
  buf.write_uint_le(sec.stype.reinterpret_as_uint())
  buf.write_int64_le(sec.flags)
  buf.write_int64_le(sec.addr)
  buf.write_int64_le(sec.offset)
  buf.write_int64_le(sec.size)
  buf.write_uint_le(link.reinterpret_as_uint())
  buf.write_uint_le(info.reinterpret_as_uint())
  buf.write_int64_le(sec.addralign)
  buf.write_int64_le(entsize)
}
