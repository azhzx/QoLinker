// The writer: orchestrates layout and emission. Ports lld Writer.cpp's
// no-script pipeline (createPhdrs, fixSectionAlignments, assignAddresses,
// assignFileOffsets, writeSections) with -z separate-code semantics.

///|
pub(all) struct Phdr {
  ptype : Int32
  mut flags : Int32
  mut first : OutSec?
  mut last : OutSec?
  mut memsz_extra : Int64
}

///|
/// The complete no-script link pipeline after all files are parsed.
pub fn link_write(ctx : Ctx) -> Unit {
  // 1. Liveness.
  if ctx.config.gc_sections {
    mark_live(ctx)
  } else {
    set_all_live(ctx)
  }
  // 2. Output sections from live input sections.
  let secs = create_output_sections(ctx)
  // 3. Common symbols allocate into .bss.
  let bss = create_bss_for_commons(ctx)
  match bss {
    Some(b) => secs.push(b)
    None => ()
  }
  // 4. Preemptibility + relocation scan (allocates GOT/PLT slots and
  // dynamic relocations).
  compute_preemptibility(ctx)
  let scan = ScanResult::new()
  scan_relocations(ctx, scan)
  let dyn_output = ctx.config.shared || ctx.config.pie || scan.needs_dyn
  let got = create_got(ctx, scan)
  match got {
    Some(g) => secs.push(g)
    None => ()
  }
  // 5. Synthetic non-alloc sections (order mirrors lld: .comment, .symtab,
  // .shstrtab, .strtab). lld always adds its version comment; so do we.
  let comment = new_synth(b".comment", @elfspec.SHT_PROGBITS, Comment)
  comment.flags = (@elfspec.SHF_MERGE | @elfspec.SHF_STRINGS).to_int64()
  comment.entsize = 1L
  comment.addralign = 1L
  secs.push(comment)
  let symtab = new_synth(b".symtab", @elfspec.SHT_SYMTAB, SymTab)
  let strtab = new_synth(b".strtab", @elfspec.SHT_STRTAB, StrTab)
  let shstrtab = new_synth(b".shstrtab", @elfspec.SHT_STRTAB, ShStrTab)
  secs.push(symtab)
  secs.push(shstrtab)
  secs.push(strtab)
  // 4b. Dynamic synthetic sections (sizes must precede layout).
  let mut interp : OutSec? = None
  let mut dynsym_sec : OutSec? = None
  let mut dynstr_sec : OutSec? = None
  let mut hash_sec : OutSec? = None
  let mut reladyn_sec : OutSec? = None
  let mut relaplt_sec : OutSec? = None
  let mut gotplt : OutSec? = None
  let mut plt : OutSec? = None
  let mut dynamic_sec : OutSec? = None
  if dyn_output {
    let ip = new_synth(b".interp", @elfspec.SHT_PROGBITS, NotSynth)
    ip.flags = @elfspec.SHF_ALLOC.to_int64()
    ip.addralign = 1L
    ip.size = dyn_interp_content().length().to_int64()
    interp = Some(ip)
    let ds = new_synth(b".dynsym", @elfspec.SHT_DYNSYM, DynSymTab)
    ds.flags = @elfspec.SHF_ALLOC.to_int64()
    ds.entsize = 24L
    dynsym_sec = Some(ds)
    let dstr = new_synth(b".dynstr", @elfspec.SHT_STRTAB, DynStrTab)
    dstr.flags = @elfspec.SHF_ALLOC.to_int64()
    dynstr_sec = Some(dstr)
    let hs = new_synth(b".hash", @elfspec.SHT_HASH, NotSynth)
    hs.flags = @elfspec.SHF_ALLOC.to_int64()
    hs.entsize = 4L
    hash_sec = Some(hs)
    let rd = new_synth(b".rela.dyn", @elfspec.SHT_RELA, RelaDyn)
    rd.flags = @elfspec.SHF_ALLOC.to_int64()
    rd.entsize = 24L
    reladyn_sec = Some(rd)
    if scan.plt_syms.length() > 0 {
      let rp = new_synth(b".rela.plt", @elfspec.SHT_RELA, RelaPlt)
      rp.flags = @elfspec.SHF_ALLOC.to_int64()
      rp.entsize = 24L
      relaplt_sec = Some(rp)
      let gp = new_synth(b".got.plt", @elfspec.SHT_PROGBITS, GotPlt)
      gp.flags = (@elfspec.SHF_ALLOC | @elfspec.SHF_WRITE).to_int64()
      gp.addralign = 8L
      gp.size = ((3 + scan.plt_syms.length()) * 8).to_int64()
      gotplt = Some(gp)
      let pl = new_synth(b".plt", @elfspec.SHT_PROGBITS, Plt)
      pl.flags = (@elfspec.SHF_ALLOC | @elfspec.SHF_EXECINSTR).to_int64()
      pl.addralign = 16L
      pl.entsize = 16L
      pl.size = (16 + scan.plt_syms.length() * 16).to_int64()
      plt = Some(pl)
    }
    let dn = new_synth(b".dynamic", @elfspec.SHT_DYNAMIC, Dynamic)
    dn.flags = (@elfspec.SHF_ALLOC | @elfspec.SHF_WRITE).to_int64()
    dn.entsize = 16L
    dynamic_sec = Some(dn)
    // Sizes known before layout: dynsym/dynstr/hash/rela/dynamic.
    let dynsyms = scan_needs_dynsym(ctx, scan)
    ds.size = ((dynsyms.length() + 1) * 24).to_int64()
    // .dynstr content: dynsym names + needed SONAMEs (built once here to
    // fix the size; the writer reuses the same builder result).
    let dstrb = StrTabBuilder::new()
    for ref_ in dynsyms {
      ignore(dstrb.add(ref_.sym.name))
    }
    for fref in ctx.files {
      match fref {
        SharedRef(sf) => ignore(dstrb.add(sf.so_name))
        _ => ()
      }
    }
    dstr.size = dstrb.size().to_int64()
    let nbucket = if dynsyms.length() < 3 { 3 } else { dynsyms.length() }
    hs.size = ((2 + nbucket + 1 + dynsyms.length()) * 4).to_int64()
    rd.size = (scan.reladyn.length() * 24).to_int64()
    match relaplt_sec {
      Some(rp) => rp.size = (scan.relaplt.length() * 24).to_int64()
      None => ()
    }
    // .dynamic entry count: needed + fixed tags; computed via a dry build.
    let needed : Array[Bytes] = []
    for fref in ctx.files {
      match fref {
        SharedRef(sf) => needed.push(sf.so_name)
        _ => ()
      }
    }
    let tags = 8 +
      needed.length() +
      (if scan.plt_syms.length() > 0 { 3 } else { 0 })
    dn.size = (tags * 16).to_int64()
  }

  for
    sec_opt in [
      interp, dynsym_sec, dynstr_sec, hash_sec, reladyn_sec, relaplt_sec, gotplt,
      plt, dynamic_sec,
    ] {
    match sec_opt {
      Some(s) => secs.push(s)
      None => ()
    }
  }

  // 6. Rank + stable sort (lld getSectionRank / compareSections).
  for sec in secs {
    sec.relro = sec.is_alloc() && is_relro_section(sec)
    sec.sort_rank = get_section_rank(sec)
  }
  stable_sort_outsecs(secs)
  // Script-driven re-grouping and ordering (lld processSectionCommands).
  apply_script(ctx, secs)
  // 7. Program headers (pseudos join the front of the ordered list).
  let elfhdr = new_pseudo(b"", @elfspec.SHT_NULL)
  let phdrsec = new_pseudo(b"", @elfspec.SHT_NULL)
  let combined : Array[OutSec] = [elfhdr, phdrsec]
  for sec in secs {
    combined.push(sec)
  }
  let phdrs = create_phdrs(ctx, combined, elfhdr, phdrsec)
  let phnum = phdrs.length()
  phdrsec.size = (phnum * @elfspec.PHDR_SIZE).to_int64()
  // 8. Section header indices first: the symbol table embeds them.
  for i in 0..<secs.length() {
    secs[i].shndx = i + 1
  }
  // 9. Addresses (image base + headers first), then input-section VAs.
  assign_addresses(ctx, combined, phnum)
  assign_input_addrs(combined)
  // 9b. Script symbols (sym = .) need final addresses, and the .symtab
  // content below must see them.
  define_script_symbols(ctx)
  // 10. Build synthetic contents (needs final addresses), then file offsets.
  let pre = build_synthetic_contents(
    ctx, secs, symtab, strtab, shstrtab, got, scan, bss, comment,
  )
  assign_offsets(ctx, combined, phnum)
  // e_shstrndx points at .shstrtab wherever it landed (lld does the same).
  let shstrndx = shstrtab.shndx
  // 11. Entry point + undefined symbol check.
  let entry : Int64 = if ctx.config.shared {
    0L
  } else {
    resolve_entry(ctx, secs)
  }
  check_undefined(ctx)
  ctx.diag.finish()
  // 12. Write everything out.
  write_output(
    ctx, secs, combined, phdrs, pre, scan, symtab, strtab, shstrtab, entry, shstrndx,
    phnum, interp, dynsym_sec, dynstr_sec, hash_sec, reladyn_sec, relaplt_sec, got,
    gotplt, plt, dynamic_sec,
  )
}

///|
fn new_synth(name : Bytes, stype : Int32, kind : SynthKind) -> OutSec {
  {
    name,
    stype,
    flags: 0L,
    addralign: if kind is SymTab ||
      kind is Got ||
      kind is RelaDyn ||
      kind is RelaPlt ||
      kind is DynSymTab ||
      kind is GnuHash {
      8L
    } else {
      1L
    },
    inputs: [],
    synth: kind,
    addr: 0L,
    offset: 0L,
    size: 0L,
    entsize: 0L,
    shndx: -1,
    sort_rank: 0,
    relro: false,
    load_flags: 0,
    in_load: false,
    load_idx: -1,
    load_first: false,
    oid: alloc_oid(),
    pseudo: false,
  }
}

///|
fn new_pseudo(name : Bytes, stype : Int32) -> OutSec {
  {
    name,
    stype,
    flags: @elfspec.SHF_ALLOC.to_int64(),
    addralign: 8L,
    inputs: [],
    synth: NotSynth,
    addr: 0L,
    offset: 0L,
    size: 0L,
    entsize: 0L,
    shndx: -1,
    sort_rank: 0,
    relro: false,
    load_flags: 0,
    in_load: false,
    load_idx: -1,
    load_first: false,
    oid: alloc_oid(),
    pseudo: true,
  }
}

///|
// GNU-specific flag not present in LLVM's ELF.h enum.
const SHF_GNU_RETAIN : Int32 = 0x200000

///|
/// Marks every input section live (no --gc-sections).
fn set_all_live(ctx : Ctx) -> Unit {
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for sec_opt in f.sections {
          guard sec_opt is Some(sec) else { continue }
          sec.live = true
        }
      _ => ()
    }
  }
}

///|
/// --gc-sections: BFS from roots (entry, SHF_RETAIN, non-alloc sections),
/// following relocation references; SHF_LINK_ORDER sections track their
/// sh_link targets.
fn mark_live(ctx : Ctx) -> Unit {
  let work : Array[InputSection] = []
  let enqueue = (sec : InputSection) => {
    if !sec.live && sec.is_alloc() {
      sec.live = true
      work.push(sec)
    }
  }
  // Reset: alloc sections start dead; non-alloc content is always kept.
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for sec_opt in f.sections {
          guard sec_opt is Some(sec) else { continue }
          if !sec.is_alloc() {
            sec.live = true
          } else {
            sec.live = false
          }
        }
      _ => ()
    }
  }
  // Roots: SHF_GNU_RETAIN sections and the entry symbol's section.
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for sec_opt in f.sections {
          guard sec_opt is Some(sec) else { continue }
          if has_flag(sec.flags, SHF_GNU_RETAIN) {
            enqueue(sec)
          }
        }
      _ => ()
    }
  }
  // Entry symbol's section is a root.
  match ctx.symtab.find(ctx.config.entry) {
    Some(ref_) =>
      match ref_.sym.kind {
        Defined(d) =>
          match d.section {
            Some(sec) => enqueue(sec)
            None => ()
          }
        _ => ()
      }
    None => ()
  }
  while work.length() > 0 {
    let sec = work.pop().unwrap()
    // Follow relocations.
    match sec.file {
      ObjRef(f) => {
        for k in 0..<sec.relas.length() {
          let r = sec.relas[k]
          guard r.sym >= 0 && r.sym < f.raw_syms.length() else { continue }
          let raw = f.raw_syms[r.sym]
          if raw.binding == @elfspec.STB_LOCAL ||
            raw.stype == @elfspec.STT_SECTION {
            if raw.shndx > 0 && raw.shndx < f.sections.length() {
              guard f.sections[raw.shndx] is Some(t) else { continue }
              enqueue(t)
            }
          } else if f.sym_refs[r.sym] is Some(ref_) {
            match ref_.sym.kind {
              Defined(d) =>
                match d.section {
                  Some(t) => enqueue(t)
                  None => ()
                }
              _ => ()
            }
          }
        }
        // LINK_ORDER coupling: keep ordered companions alive.
        for sib_opt in f.sections {
          guard sib_opt is Some(sib) else { continue }
          if has_flag(sib.flags, @elfspec.SHF_LINK_ORDER) &&
            sib.link == sec.sec_index {
            enqueue(sib)
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// Groups live input sections into output sections keyed by
/// (name, type, flags), preserving input order (lld OutputSectionFactory).
fn create_output_sections(ctx : Ctx) -> Array[OutSec] {
  let out : Array[OutSec] = []
  let index : Map[Bytes, OutSec] = Map([])
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for sec_opt in f.sections {
          guard sec_opt is Some(sec) else { continue }
          if !sec.live || sec.discarded {
            continue
          }
          let key = section_key(sec.name, sec.stype, sec.flags)
          match index.get(key) {
            Some(os) => {
              sec.out_sec = Some(os)
              os.inputs.push(sec)
              if sec.addralign > os.addralign {
                os.addralign = sec.addralign
              }
              let in_off = align_up64(os.size, sec.addralign)
              sec.out_off = in_off
              os.size = in_off + sec.size
            }
            None => {
              let os : OutSec = {
                name: sec.name,
                stype: sec.stype,
                flags: sec.flags,
                addralign: sec.addralign,
                inputs: [sec],
                synth: NotSynth,
                addr: 0L,
                offset: 0L,
                size: sec.size,
                entsize: sec.entsize,
                shndx: -1,
                sort_rank: 0,
                relro: false,
                load_flags: 0,
                in_load: false,
                load_idx: -1,
                load_first: false,
                oid: alloc_oid(),
                pseudo: false,
              }
              sec.out_sec = Some(os)
              index[key] = os
              out.push(os)
            }
          }
        }
      _ => ()
    }
  }
  out
}

///|
fn section_key(name : Bytes, stype : Int32, flags : Int64) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(name[:])
  buf.write_byte(b'\x01')
  buf.write_int64_le(stype.to_int64())
  buf.write_byte(b'\x01')
  buf.write_int64_le(flags)
  buf.to_bytes()
}

///|
/// Rounds `off` up to `align` relative to a section start, returning the
/// padding size (helper for accumulating input offsets).
fn align_up64(value : Int64, align : Int64) -> Int64 {
  @support.align_to(value, if align > 1L { align } else { 1L })
}

///|
/// Creates .bss if any SHN_COMMON symbols survived resolution.
fn create_bss_for_commons(ctx : Ctx) -> OutSec? {
  let mut has_common = false
  for ref_ in ctx.symtab.symbols() {
    match ref_.sym.kind {
      Common(_) => has_common = true
      _ => ()
    }
  }
  if !has_common {
    return None
  }
  let bss : OutSec = {
    name: b".bss",
    stype: @elfspec.SHT_NOBITS,
    flags: (@elfspec.SHF_ALLOC | @elfspec.SHF_WRITE).to_int64(),
    addralign: 1L,
    inputs: [],
    synth: Bss,
    addr: 0L,
    offset: 0L,
    size: 0L,
    entsize: 0L,
    shndx: -1,
    sort_rank: 0,
    relro: false,
    load_flags: 0,
    in_load: false,
    load_idx: -1,
    load_first: false,
    oid: alloc_oid(),
    pseudo: false,
  }
  ctx.common_bss = Some(bss)
  allocate_commons(ctx, bss)
  if bss.addralign < 1L {
    bss.addralign = 1L
  }
  // Track the max common alignment for correct layout.
  for ref_ in ctx.symtab.symbols() {
    match ref_.sym.kind {
      Common(c) =>
        if c.alignment > bss.addralign {
          bss.addralign = c.alignment
        }
      _ => ()
    }
  }
  Some(bss)
}

///|
/// Creates .got if the scan allocated any slots (static MVP: slots hold the
/// resolved symbol VA).
fn create_got(ctx : Ctx, scan : ScanResult) -> OutSec? {
  if !scan.needs_got {
    return None
  }
  let got = new_synth(b".got", @elfspec.SHT_PROGBITS, Got)
  got.flags = (@elfspec.SHF_ALLOC | @elfspec.SHF_WRITE).to_int64()
  got.size = (scan.got_syms.length() * 8).to_int64()
  let _ = ctx
  Some(got)
}

///|
/// Applies the parsed linker script: merges input sections into the
/// script's named output sections, reorders them, and defines script
/// symbols after layout.
fn apply_script(ctx : Ctx, secs : Array[OutSec]) -> Unit {
  guard ctx.script is Some(s) else { return }
  // Collect script outsec elements in order.
  let script_secs : Array[(Bytes, Array[Bytes])] = []
  for elem in s.elems {
    match elem {
      Outsec(name, patterns) => script_secs.push((name, patterns))
      _ => ()
    }
  }
  if script_secs.length() == 0 {
    return
  }
  let consumed : Map[Int32, Unit] = Map([])
  let ordered : Array[OutSec] = []
  let synthetic_tail : Array[OutSec] = []
  for pair in script_secs {
    let name = pair.0
    let patterns = pair.1
    let merged_inputs : Array[InputSection] = []
    let mut align = 1L
    let mut stype = @elfspec.SHT_PROGBITS
    let mut flags : Int64 = 0L
    let mut found = false
    let mut bss_like = false
    let mut bss_size : Int64 = 0L
    for sec in secs {
      if consumed.contains(sec.oid) ||
        sec.pseudo ||
        ((sec.synth is NotSynth) == false && (sec.synth is Bss) == false) {
        continue
      }
      let mut m = false
      for pi in 0..<patterns.length() {
        if pattern_match(patterns[pi], sec.name) {
          m = true
        }
      }
      if m {
        found = true
        if sec.synth is Bss {
          // Synthetic .bss (COMMON allocation) carries size but no inputs.
          bss_size = if sec.size > bss_size { sec.size } else { bss_size }
        }
        if merged_inputs.length() == 0 {
          stype = sec.stype
          flags = sec.flags
          if sec.synth is Bss {
            bss_like = true
          }
        }
        if sec.synth is Bss {
          bss_like = true
        }
        for input in sec.inputs {
          merged_inputs.push(input)
        }
        if sec.addralign > align {
          align = sec.addralign
        }
        consumed[sec.oid] = ()
      }
    }
    if !found {
      continue
    }
    let ns : OutSec = {
      name,
      stype,
      flags,
      addralign: align,
      inputs: [],
      synth: if bss_like {
        Bss
      } else {
        NotSynth
      },
      addr: 0L,
      offset: 0L,
      size: 0L,
      entsize: 0L,
      shndx: -1,
      sort_rank: 0,
      relro: false,
      load_flags: 0,
      in_load: false,
      load_idx: -1,
      load_first: false,
      oid: alloc_oid(),
      pseudo: false,
    }
    // Re-parent inputs with fresh offsets.
    let mut dot : Int64 = 0L
    for input in merged_inputs {
      let aligned = @support.align_to(dot, input.addralign)
      input.out_off = aligned
      input.out_sec = Some(ns)
      dot = aligned + input.size
    }
    if bss_like && dot < bss_size {
      dot = bss_size
    }
    ns.inputs = merged_inputs
    ns.size = dot
    ctx.script_outsecs[name] = ns
    ordered.push(ns)
  }
  // Orphans: real sections not consumed, keep their sorted order.
  let orphans : Array[OutSec] = []
  for sec in secs {
    if consumed.contains(sec.oid) {
      continue
    }
    if sec.pseudo || !(sec.synth is NotSynth) {
      synthetic_tail.push(sec)
      continue
    }
    orphans.push(sec)
  }
  // Final ordering: script sections, orphans, then synthetic tails
  // (comment/symtab/shstrtab/strtab and dynamic sections keep order).
  let mut w = 0
  for sec in ordered {
    secs[w] = sec
    w += 1
  }
  for sec in orphans {
    secs[w] = sec
    w += 1
  }
  for sec in synthetic_tail {
    secs[w] = sec
    w += 1
  }
  // Drop any leftovers beyond w (there are none by construction).
}

///|
/// Defines script symbols (sym = . / PROVIDE) after layout.
fn define_script_symbols(ctx : Ctx) -> Unit {
  guard ctx.script is Some(s) else { return }
  // dot walks the script element order; Outsec elements advance it.
  let by_name : Map[Bytes, OutSec] = Map([])
  let _ = by_name
  let mut dot : Int64 = ctx.config.image_base
  for elem in s.elems {
    match elem {
      Outsec(_, _) =>
        // Find the (possibly merged) output section carrying this name.
        match ctx.script_outsecs.get(elem_name(elem)) {
          Some(os) => dot = os.addr + os.size
          None => ()
        }
      Assign(name, _, provide) => {
        let ref_ = ctx.symtab.insert(name)
        // PROVIDE only defines symbols that are actually referenced.
        if provide && ref_.sym.file_is_internal() {
          continue
        }
        let payload : DefinedData = {
          file: InternalRef,
          section: None,
          value: dot - ctx.config.image_base,
          size: 0L,
          is_weak: false,
        }
        ref_.sym.kind = Defined(payload)
        ref_.sym.binding = @elfspec.STB_GLOBAL
        ref_.sym.stype = @elfspec.STT_NOTYPE
      }
      DotAssign(base) => dot = base
      Entry(_) => ()
    }
  }
}

///|

///|
/// Placeholder symbols (created by insert) carry the internal file.
fn Symbol::file_is_internal(self : Symbol) -> Bool {
  match self.kind {
    Undefined(d) =>
      match d.file {
        InternalRef => true
        _ => false
      }
    _ => false
  }
}

///|
fn elem_name(e : ScriptElem) -> Bytes {
  match e {
    Outsec(name, _) => name
    _ => b""
  }
}

///|
/// Resolves the entry symbol to a VA. Errors when it cannot be found.
fn resolve_entry(ctx : Ctx, secs : Array[OutSec]) -> Int64 {
  let _ = secs
  match ctx.symtab.find(ctx.config.entry) {
    Some(ref_) =>
      match ref_.sym.kind {
        Defined(_) => ref_.sym.get_va(ctx)
        Common(_) =>
          match ctx.common_alloc.get(ref_.sym.name) {
            Some(va) => va
            None => 0L
          }
        _ => {
          ctx.diag.error(
            "undefined entry symbol: \{@support.bytes_str(ctx.config.entry)}",
          )
          0L
        }
      }
    None => {
      ctx.diag.error(
        "undefined entry symbol: \{@support.bytes_str(ctx.config.entry)}",
      )
      0L
    }
  }
}

///|
/// Reports strong undefined symbols (lld's reportUndefinedSymbols).
fn check_undefined(ctx : Ctx) -> Unit {
  let seen : Map[Bytes, Unit] = Map([])
  for ref_ in ctx.symtab.symbols() {
    let sym = ref_.sym
    match sym.kind {
      Undefined(d) =>
        if !d.is_weak && !seen.contains(sym.name) {
          seen[sym.name] = ()
          ctx.diag.error(
            "undefined symbol: \{@support.bytes_str(sym.name)} (referenced by \{@support.bytes_str(FileRef::path_of(d.file))})",
          )
        }
      _ => ()
    }
  }
}
