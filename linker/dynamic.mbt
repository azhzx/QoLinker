// Dynamic linking synthetic sections: .interp, .dynsym/.dynstr, .hash,
// .rela.dyn/.rela.plt, .got/.got.plt/.plt, .dynamic. Ported from lld
// SyntheticSections.cpp (x86_64 GOT/PLT layout). MVP: no GNU hash, no
// version tables (glibc accepts unversioned refs), no copy relocations.

///|
pub const INTERP_PATH : Bytes = b"/lib64/ld-linux-x86-64.so.2"

///|
fn write_rela(
  buf : @buffer.Buffer,
  offset : Int64,
  symidx : Int32,
  rtype : Int32,
  addend : Int64,
) -> Unit {
  buf.write_int64_le(offset)
  buf.write_int64_le((symidx.to_int64() << 32) | rtype.to_int64())
  buf.write_int64_le(addend)
}

///|
/// SysV ELF hash for the .hash section.
pub fn elf_hash(name : Bytes) -> Int32 {
  let mut h : UInt32 = 0U
  for i in 0..<name.length() {
    h = h.lsl(4).add(name[i].to_uint())
    let g = h & 0xF0000000U
    if g != 0U {
      h = h.lxor(g.lsr(24))
    }
    h = h.land(g.lnot())
  }
  h.reinterpret_as_int()
}

///|
/// Resolves a dynamic relocation's place offset once addresses exist.
pub fn entry_place(e : RelaEntry, got : OutSec?, gotplt : OutSec?) -> Int64 {
  match e.place {
    GotSlot(idx) =>
      match got {
        Some(g) => g.addr + idx.to_int64() * 8L
        None => 0L
      }
    GotPltSlot(idx) =>
      match gotplt {
        Some(g) => g.addr + ((3 + idx) * 8).to_int64()
        None => 0L
      }
    Place(sec, off) => sec.addr + off
  }
}

///|
/// SysV .hash content for the dynamic symbol table (names exclude the null
/// symbol; index i here corresponds to dynsym index i+1).
pub fn dyn_hash_content(names : Array[Bytes]) -> Bytes {
  let n = names.length()
  let nbucket = if n < 3 { 3 } else { n }
  let buckets = FixedArray::make(nbucket, 0L)
  // The chain table has nchain = n+1 entries (one per .dynsym entry,
  // including the null symbol); ld.so indexes it up to nchain-1.
  let chains = FixedArray::make(n + 1, 0L)
  for i in 0..<n {
    let b = elf_hash(names[i]) % nbucket
    chains[i + 1] = buckets[b]
    buckets[b] = (i + 1).to_int64()
  }
  let buf = @buffer.Buffer()
  buf.write_uint_le(nbucket.reinterpret_as_uint())
  buf.write_uint_le((n + 1).reinterpret_as_uint())
  for i in 0..<nbucket {
    buf.write_uint_le(buckets[i].to_int().reinterpret_as_uint())
  }
  for i in 0..<n + 1 {
    buf.write_uint_le(chains[i].to_int().reinterpret_as_uint())
  }
  buf.to_bytes()
}

///|
/// .got content: link-time VAs for non-preemptible slots, zero for slots
/// the loader fills (GLOB_DAT).
pub fn dyn_got_content(ctx : Ctx, scan : ScanResult) -> Bytes {
  let buf = @buffer.Buffer()
  for ref_ in scan.got_syms {
    let sym = ref_.sym
    if sym.is_preemptible || sym_is_strong_undef(sym) {
      buf.write_int64_le(0L)
    } else {
      buf.write_int64_le(sym.get_va(ctx))
    }
  }
  buf.to_bytes()
}

///|
/// .plt content (x86_64, lld layout): 32-byte header + 16-byte entries,
/// with displacements patched once .plt/.got.plt addresses are known.
pub fn dyn_plt_content(entry_count : Int32) -> Bytes {
  let buf = @buffer.Buffer()
  // Header (16 bytes, lld x86_64 layout): pushq GOTPLT[1](%rip);
  // bnd jmpq *GOTPLT[2](%rip); 3 bytes of padding.
  buf.write_bytes(b"\xff\x35\x00\x00\x00\x00"[:])
  buf.write_bytes(b"\xf2\xff\x25\x00\x00\x00\x00"[:])
  buf.write_bytes(b"\x0f\x1f\x00"[:])
  for i in 0..<entry_count {
    // jmpq *GOTPLT[3+i](%rip)
    buf.write_bytes(b"\xff\x25\x00\x00\x00\x00"[:])
    // pushq $i
    buf.write_byte(b'\x68')
    buf.write_int_le(i)
    // jmpq plt[0]
    buf.write_byte(b'\xe9')
    buf.write_int_le(0)
  }
  buf.to_bytes()
}

///|
/// Patches PLT cross-references after address assignment.
pub fn patch_plt(
  content : FixedArray[Byte],
  plt_addr : Int64,
  gotplt_addr : Int64,
  entry_count : Int32,
) -> Unit {
  // pushq GOTPLT[1]: disp at 2, next instr at 6.
  FixedArray::unsafe_write_uint32_le(
    content,
    2,
    (gotplt_addr + 8L - (plt_addr + 6L)).to_int().reinterpret_as_uint(),
  )
  // bnd jmpq *GOTPLT[2]: prefix f2 ff 25 ends at 9, disp at 9, next at 13.
  FixedArray::unsafe_write_uint32_le(
    content,
    9,
    (gotplt_addr + 16L - (plt_addr + 13L)).to_int().reinterpret_as_uint(),
  )
  for i in 0..<entry_count {
    let ebase = (16 + i * 16).to_int64()
    let slot = gotplt_addr + ((3 + i) * 8).to_int64()
    FixedArray::unsafe_write_uint32_le(
      content,
      (ebase + 2L).to_int(),
      (slot - (plt_addr + ebase + 6L)).to_int().reinterpret_as_uint(),
    )
    FixedArray::unsafe_write_uint32_le(
      content,
      (ebase + 12L).to_int(),
      (plt_addr - (plt_addr + ebase + 16L)).to_int().reinterpret_as_uint(),
    )
  }
}

///|
/// .got.plt content: [0]=&_DYNAMIC, [1]/[2] loader-reserved, then one slot
/// per PLT entry (lazy back-point for bound symbols, 0 for JUMP_SLOT).
pub fn dyn_gotplt_content(
  ctx : Ctx,
  scan : ScanResult,
  dynamic_addr : Int64,
  plt_addr : Int64,
) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_int64_le(dynamic_addr)
  buf.write_int64_le(0L)
  buf.write_int64_le(0L)
  for i in 0..<scan.plt_syms.length() {
    let sym = scan.plt_syms[i].sym
    if sym.is_preemptible || sym_is_strong_undef(sym) {
      buf.write_int64_le(0L)
    } else {
      buf.write_int64_le(plt_addr + 16L + i.to_int64() * 16L + 6L)
    }
  }
  let _ = ctx
  buf.to_bytes()
}

///|
/// Everything dynamic the writer emits, built after addresses are known.
pub(all) struct DynOut {
  interp : Bytes
  dynsym : Bytes
  dynstr : Bytes
  hash : Bytes
  reladyn : Bytes
  relaplt : Bytes
  got : Bytes
  gotplt : Bytes
  plt : Bytes
  dynamic : Bytes
  needed_names : Array[Bytes]
}

///|
/// Builds all dynamic content. `needed` is the ordered list of SONAMEs for
/// DT_NEEDED; their offsets in .dynstr must match the order of the
/// `needed` strings added to the .dynstr builder by the caller.
pub fn build_dyn_out(
  ctx : Ctx,
  scan : ScanResult,
  needed : Array[Bytes],
  dynstr : StrTabBuilder,
  dynstr_sec : OutSec,
  dynsym_sec : OutSec,
  hash_sec : OutSec,
  reladyn_sec : OutSec,
  relaplt_sec : OutSec?,
  got : OutSec?,
  gotplt : OutSec?,
  plt : OutSec?,
  combined : Array[OutSec],
) -> DynOut {
  // dynsym (null + entries)
  let dynsyms = scan_needs_dynsym(ctx, scan)
  let ds = @buffer.Buffer()
  for _ in 0..<3 {
    ds.write_int64_le(0L)
  }
  for ref_ in dynsyms {
    let sym = ref_.sym
    let name_off = dynstr.add(sym.name)
    let shndx : Int32 = match sym.kind {
      Defined(d) =>
        match d.section {
          Some(sec) =>
            match sec.out_sec {
              Some(os) => os.shndx
              None => @elfspec.SHN_ABS
            }
          None => @elfspec.SHN_ABS
        }
      Common(_) =>
        match ctx.common_bss {
          Some(b) => b.shndx
          None => @elfspec.SHN_ABS
        }
      _ => 0
    }
    let value : Int64 = match sym.kind {
      Undefined(_) | Shared(_) => 0L
      _ => sym.get_va(ctx)
    }
    let size : Int64 = match sym.kind {
      Defined(d) => d.size
      Common(c) => c.size
      _ => 0L
    }
    ds.write_uint_le(name_off.reinterpret_as_uint())
    ds.write_byte(((sym.binding << 4) | sym.stype).to_byte())
    ds.write_byte(sym.visibility.to_byte())
    ds.write_uint16_le(shndx.to_uint16())
    ds.write_int64_le(value)
    ds.write_int64_le(size)
  }
  // hash over dynsym names (in order)
  let names : Array[Bytes] = []
  for ref_ in dynsyms {
    names.push(ref_.sym.name)
  }
  fn dynsym_idx_of(ref_ : SymRef) -> Int32 {
    for i in 0..<dynsyms.length() {
      if dynsyms[i].sym.aux_identity() == ref_.sym.aux_identity() {
        return i + 1
      }
    }
    0
  }
  // rela.dyn (RELATIVE first) + rela.plt
  let rd = @buffer.Buffer()
  for e in scan.reladyn {
    if e.rtype == @elfspec.R_X86_64_RELATIVE {
      write_rela(rd, entry_place(e, got, gotplt), 0, e.rtype, e.addend)
    }
  }
  for e in scan.reladyn {
    if e.rtype != @elfspec.R_X86_64_RELATIVE {
      let idx = match e.sym {
        Some(ref_) => dynsym_idx_of(ref_)
        None => 0
      }
      write_rela(rd, entry_place(e, got, gotplt), idx, e.rtype, e.addend)
    }
  }
  let rp = @buffer.Buffer()
  for e in scan.relaplt {
    let idx = match e.sym {
      Some(ref_) => dynsym_idx_of(ref_)
      None => 0
    }
    write_rela(rp, entry_place(e, got, gotplt), idx, e.rtype, e.addend)
  }
  // .dynamic: every DT_ value references final section addresses.
  let dynbuf = @buffer.Buffer()
  let add = (t : Int32, v : Int64) => {
    dynbuf.write_int64_le(t.to_int64())
    dynbuf.write_int64_le(v)
  }
  for n in needed {
    add(@elfspec.DT_NEEDED, dynstr.add(n).to_int64())
  }
  match gotplt {
    Some(g) => add(@elfspec.DT_PLTGOT, g.addr)
    None => ()
  }
  add(@elfspec.DT_STRTAB, dynstr_sec.addr)
  add(@elfspec.DT_STRSZ, dynstr_sec.size)
  add(@elfspec.DT_SYMTAB, dynsym_sec.addr)
  add(@elfspec.DT_SYMENT, 24L)
  add(@elfspec.DT_HASH, hash_sec.addr)
  if reladyn_sec.size > 0L {
    add(@elfspec.DT_RELA, reladyn_sec.addr)
    add(@elfspec.DT_RELASZ, reladyn_sec.size)
    add(@elfspec.DT_RELAENT, 24L)
    let rel_count = count_relatives(scan)
    if rel_count > 0 {
      add(@elfspec.DT_RELACOUNT, rel_count.to_int64())
    }
  }
  if scan.plt_syms.length() > 0 {
    match relaplt_sec {
      Some(r) => {
        add(@elfspec.DT_JMPREL, r.addr)
        add(@elfspec.DT_PLTRELSZ, r.size)
        add(@elfspec.DT_PLTREL, @elfspec.DT_RELA.to_int64())
      }
      None => ()
    }
  }
  add(@elfspec.DT_DEBUG, 0L)
  if ctx.config.pie {
    add(@elfspec.DT_FLAGS_1, @elfspec.DF_1_PIE.to_int64())
  }
  add(@elfspec.DT_NULL, 0L)
  let plt_addr = match plt {
    Some(p) => p.addr
    None => 0L
  }
  let dbg_dynsym = ds.to_bytes()
  {
    interp: dyn_interp_content(),
    dynsym: dbg_dynsym,
    dynstr: dynstr.to_bytes(),
    hash: dyn_hash_content(names),
    reladyn: rd.to_bytes(),
    relaplt: rp.to_bytes(),
    got: dyn_got_content(ctx, scan),
    gotplt: dyn_gotplt_content(
      ctx,
      scan,
      dynamic_addr_of(ctx, combined),
      plt_addr,
    ),
    plt: dyn_plt_content(scan.plt_syms.length()),
    dynamic: dynbuf.to_bytes(),
    needed_names: needed,
  }
}

///|
/// DT_PLTGOT[0] holds &_DYNAMIC; the writer supplies .dynamic's address.
fn dynamic_addr_of(ctx : Ctx, combined : Array[OutSec]) -> Int64 {
  for sec in combined {
    if sec.synth is Dynamic {
      return sec.addr
    }
  }
  let _ = ctx
  0L
}

///|
pub fn dyn_interp_content() -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(INTERP_PATH[:])
  buf.write_byte(b'\x00')
  buf.to_bytes()
}

///|
/// Symbols that must appear in .dynsym: imports (GOT/PLT/dynamic refs) and
/// exports (preemptible definitions), in symtab insertion order.
pub fn scan_needs_dynsym(ctx : Ctx, scan : ScanResult) -> Array[SymRef] {
  let out : Array[SymRef] = []
  for ref_ in ctx.symtab.symbols() {
    let sym = ref_.sym
    let mut include = false
    if sym.aux.has_plt || sym.aux.has_got {
      match sym.kind {
        Shared(_) => include = true
        Undefined(d) => if !d.is_weak { include = true }
        Defined(_) | Common(_) => include = sym.is_preemptible
        Lazy(_) => ()
      }
    }
    if !include && (ctx.config.shared || ctx.config.pie) && sym.is_preemptible {
      match sym.kind {
        Defined(_) | Common(_) => include = true
        _ => ()
      }
    }
    if include {
      out.push(ref_)
    }
  }
  let _ = scan
  out
}

///|
fn count_relatives(scan : ScanResult) -> Int32 {
  let mut n = 0
  for e in scan.reladyn {
    if e.rtype == @elfspec.R_X86_64_RELATIVE {
      n += 1
    }
  }
  n
}
