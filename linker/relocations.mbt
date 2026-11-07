// Relocation scanning and application for x86-64, ported from lld
// RelocScan.h/Relocations.cpp.
//
// Two-phase design: `classify_reloc` (scan, before layout) decides per
// relocation how it is handled — applied statically, routed via GOT/PLT,
// or turned into a dynamic relocation — and allocates GOT/PLT slots so
// that synthetic section sizes are known before addresses are assigned.
// `apply_reloc` (write phase) then computes final values and patches
// content, filling dynamic-relocation addends/offsets now that addresses
// are known.

///|
/// How the dynamic loader finds a dynamic relocation's place.
pub(all) enum DynPlace {
  /// .got slot for GOT symbol index i (.got + 8*i).
  GotSlot(Int32)
  /// .got.plt slot for PLT index i (.got.plt + 8*(3+i)).
  GotPltSlot(Int32)
  /// Inside an input section (final place = sec.addr + off).
  Place(InputSection, Int64)
}

///|
pub(all) struct RelaEntry {
  rtype : Int32
  sym : SymRef?
  addend : Int64
  place : DynPlace
}

///|
/// Per-relocation decision recorded by the scan phase.
pub(all) enum DynAction {
  /// Write S+A (or S+A-P) statically.
  Static
  /// Write PLT entry VA + A - P.
  PltCall
  /// PC-relative GOT reference: write slot VA + A - P (GOTPCREL family).
  GotPcRel
  /// GOT slot resolved by the loader (GLOB_DAT recorded): same code
  /// computation, slot content filled at runtime.
  GotDynamicPc
  /// Absolute GOT slot address (GOT64): write slot VA + A.
  GotAbs
  /// A dynamic relocation is recorded; content is zeroed.
  DynRela(RelaEntry)
}

///|
pub struct ScanResult {
  got_syms : Array[SymRef]
  got_index : Map[Int32, Int32]
  mut needs_got : Bool
  plt_syms : Array[SymRef]
  plt_index : Map[Int32, Int32]
  mut needs_plt : Bool
  reladyn : Array[RelaEntry]
  relaplt : Array[RelaEntry]
  mut needs_dyn : Bool
}

///|
pub fn ScanResult::new() -> ScanResult {
  {
    got_syms: [],
    got_index: Map([]),
    needs_got: false,
    plt_syms: [],
    plt_index: Map([]),
    needs_plt: false,
    reladyn: [],
    relaplt: [],
    needs_dyn: false,
  }
}

///|
fn ScanResult::got_slot(self : ScanResult, ref_ : SymRef) -> Int32 {
  match self.got_index.get(ref_.sym.aux_identity()) {
    Some(idx) => idx
    None => {
      let idx = self.got_syms.length()
      self.got_syms.push(ref_)
      self.got_index[ref_.sym.aux_identity()] = (idx : Int32)
      ref_.sym.aux.has_got = true
      ref_.sym.aux.got_index = idx
      self.needs_got = true
      idx
    }
  }
}

///|
fn ScanResult::plt_slot(self : ScanResult, ref_ : SymRef) -> Int32 {
  match self.plt_index.get(ref_.sym.aux_identity()) {
    Some(idx) => idx
    None => {
      let idx = self.plt_syms.length()
      self.plt_syms.push(ref_)
      self.plt_index[ref_.sym.aux_identity()] = (idx : Int32)
      ref_.sym.aux.has_plt = true
      ref_.sym.aux.plt_index = idx
      self.needs_plt = true
      self.needs_dyn = true
      self.relaplt.push({
        rtype: @elfspec.R_X86_64_JUMP_SLOT,
        sym: Some(ref_),
        addend: 0L,
        place: GotPltSlot(idx),
      })
      idx
    }
  }
}

///|
fn Symbol::got_va(self : Symbol, got : OutSec) -> Int64 {
  got.addr + self.aux.got_index.to_int64() * 8L
}

///|
fn Symbol::plt_va(self : Symbol, plt : OutSec) -> Int64 {
  plt.addr + 16L + self.aux.plt_index.to_int64() * 16L
}

///|
fn Symbol::aux_identity(self : Symbol) -> Int32 {
  self.aux_id
}

///|
fn sym_is_strong_undef(sym : Symbol) -> Bool {
  match sym.kind {
    Undefined(d) => !d.is_weak
    _ => false
  }
}

///|
/// True when accesses to this symbol must go through the GOT/PLT.
fn sym_needs_dyn_access(sym : Symbol) -> Bool {
  sym.is_preemptible || sym_is_strong_undef(sym)
}

///|
/// Computes is_preemptible for every symbol (lld
/// parseVersionAndComputeIsPreemptible, MVP subset).
pub fn compute_preemptibility(ctx : Ctx) -> Unit {
  let dyn_output = ctx.config.pie || ctx.config.shared
  for ref_ in ctx.symtab.symbols() {
    let sym = ref_.sym
    sym.is_preemptible = match sym.kind {
      Shared(_) => true
      Defined(_) =>
        dyn_output &&
        sym.visibility == @elfspec.STV_DEFAULT &&
        version_script_exports(ctx.version_script, sym.name, true)
      Common(_) =>
        dyn_output &&
        sym.visibility == @elfspec.STV_DEFAULT &&
        version_script_exports(ctx.version_script, sym.name, true)
      _ => false
    }
  }
}

///|
/// Resolves a relocation symbol reference to its final virtual address.
pub fn reloc_sym_va(ctx : Ctx, file : ObjFile, sym_index : Int32) -> Int64? {
  guard sym_index >= 0 && sym_index < file.raw_syms.length() else {
    ctx.diag.error(
      "\{@support.bytes_str(file.path)}: relocation symbol index out of range",
    )
    return None
  }
  let raw = file.raw_syms[sym_index]
  if raw.binding == @elfspec.STB_LOCAL ||
    raw.stype == @elfspec.STT_SECTION ||
    raw.stype == @elfspec.STT_FILE {
    if raw.stype == @elfspec.STT_SECTION {
      guard raw.shndx > 0 && raw.shndx < file.sections.length() else {
        return None
      }
      guard file.sections[raw.shndx] is Some(sec) else { return None }
      if sec.discarded {
        ctx.diag.error(
          "\{@support.bytes_str(file.path)}: relocation refers to a discarded section",
        )
        return None
      }
      return Some(sec.addr)
    }
    if raw.shndx == @elfspec.SHN_ABS {
      return Some(raw.value)
    }
    guard raw.shndx > 0 && raw.shndx < file.sections.length() else {
      return None
    }
    guard file.sections[raw.shndx] is Some(sec) else { return None }
    if sec.discarded {
      ctx.diag.error(
        "\{@support.bytes_str(file.path)}: relocation refers to a discarded section",
      )
      return None
    }
    return Some(sec.addr + raw.value)
  }
  guard file.sym_refs[sym_index] is Some(ref_) else { return None }
  let sym = ref_.sym
  match sym.kind {
    Defined(d) =>
      match d.section {
        Some(sec) => {
          if sec.discarded {
            ctx.diag.error(
              "\{@support.bytes_str(file.path)}: relocation refers to a symbol in a discarded section",
            )
            return None
          }
          Some(sec.addr + d.value)
        }
        None => Some(ctx.config.image_base + d.value)
      }
    Common(_) => Some(common_va(ctx, sym.name))
    Undefined(d) =>
      if d.is_weak {
        Some(0L)
      } else {
        ctx.diag.error("undefined symbol: \{@support.bytes_str(sym.name)}")
        None
      }
    Shared(_) => {
      ctx.diag.error(
        "\{@support.bytes_str(file.path)}: direct access to preemptible symbol \{@support.bytes_str(sym.name)} (needs GOT)",
      )
      None
    }
    Lazy(_) => Some(0L)
  }
}

///|
/// Scan: decides how one relocation is realized. Returns the DynAction and
/// stores it on the input section (`idx` is the reloc's index).
pub fn classify_reloc(
  ctx : Ctx,
  scan : ScanResult,
  file : ObjFile,
  input : InputSection,
  r : @elffile.Rela,
  idx : Int32,
  dyn_output : Bool,
) -> DynAction? {
  let ref_ : SymRef? = if r.sym >= 0 && r.sym < file.sym_refs.length() {
    file.sym_refs[r.sym]
  } else {
    None
  }
  let action : DynAction? = match r.rtype {
    t if t == @elfspec.R_X86_64_64 =>
      if ref_ is Some(ref_) && sym_needs_dyn_access(ref_.sym) {
        ref_.sym.aux.has_dynref = true
        let e : RelaEntry = {
          rtype: @elfspec.R_X86_64_64,
          sym: Some(ref_),
          addend: r.addend,
          place: Place(input, r.offset),
        }
        scan.reladyn.push(e)
        scan.needs_dyn = true
        Some(DynRela(e))
      } else if dyn_output {
        let e : RelaEntry = {
          rtype: @elfspec.R_X86_64_RELATIVE,
          sym: None,
          addend: 0L,
          place: Place(input, r.offset),
        }
        scan.reladyn.push(e)
        scan.needs_dyn = true
        Some(DynRela(e))
      } else {
        Some(Static)
      }
    t if t == @elfspec.R_X86_64_PC32 || t == @elfspec.R_X86_64_PLT32 =>
      if ref_ is Some(ref_) && sym_needs_dyn_access(ref_.sym) {
        ignore(scan.plt_slot(ref_))
        Some(PltCall)
      } else {
        Some(Static)
      }
    t if t == @elfspec.R_X86_64_32 =>
      if ref_ is Some(ref_) && sym_needs_dyn_access(ref_.sym) {
        let e : RelaEntry = {
          rtype: @elfspec.R_X86_64_32,
          sym: Some(ref_),
          addend: r.addend,
          place: Place(input, r.offset),
        }
        scan.reladyn.push(e)
        scan.needs_dyn = true
        Some(DynRela(e))
      } else if dyn_output {
        ctx.diag.error(
          "\{@support.bytes_str(file.path)}: R_X86_64_32 against a local symbol in a dynamic output (recompile with -fPIC)",
        )
        None
      } else {
        Some(Static)
      }
    t if t == @elfspec.R_X86_64_32S =>
      if ref_ is Some(ref_) && sym_needs_dyn_access(ref_.sym) {
        let e : RelaEntry = {
          rtype: @elfspec.R_X86_64_32S,
          sym: Some(ref_),
          addend: r.addend,
          place: Place(input, r.offset),
        }
        scan.reladyn.push(e)
        scan.needs_dyn = true
        Some(DynRela(e))
      } else if dyn_output {
        ctx.diag.error(
          "\{@support.bytes_str(file.path)}: R_X86_64_32S against a local symbol in a dynamic output (recompile with -fPIC)",
        )
        None
      } else {
        Some(Static)
      }
    t if t == @elfspec.R_X86_64_GOTPCREL ||
      t == @elfspec.R_X86_64_GOTPCRELX ||
      t == @elfspec.R_X86_64_REX_GOTPCRELX ||
      t == @elfspec.R_X86_64_GOT64 => {
      guard ref_ is Some(ref_) else { return None }
      ignore(scan.got_slot(ref_))
      if sym_needs_dyn_access(ref_.sym) {
        let e : RelaEntry = {
          rtype: @elfspec.R_X86_64_GLOB_DAT,
          sym: Some(ref_),
          addend: 0L,
          place: GotSlot(ref_.sym.aux.got_index),
        }
        scan.reladyn.push(e)
        scan.needs_dyn = true
        Some(GotDynamicPc)
      } else if t == @elfspec.R_X86_64_GOT64 {
        Some(GotAbs)
      } else {
        Some(GotPcRel)
      }
    }
    t if t == @elfspec.R_X86_64_GOTPC32 || t == @elfspec.R_X86_64_GOTPC64 =>
      Some(Static)
    t if t == @elfspec.R_X86_64_GOTOFF64 => Some(Static)
    t if t == @elfspec.R_X86_64_16 ||
      t == @elfspec.R_X86_64_PC16 ||
      t == @elfspec.R_X86_64_8 ||
      t == @elfspec.R_X86_64_PC8 ||
      t == @elfspec.R_X86_64_PC64 => Some(Static)
    _ => {
      ctx.diag.error(
        "\{@support.bytes_str(file.path)}: unsupported relocation type \{r.rtype}",
      )
      None
    }
  }
  match action {
    Some(a) => {
      match input.dyn_actions {
        Some(arr) => arr[idx] = a
        None => ()
      }
      Some(a)
    }
    None => None
  }
}

///|
/// Scan phase: classifies every relocation of every live input section.
/// Must run after `compute_preemptibility` and before layout.
pub fn scan_relocations(ctx : Ctx, scan : ScanResult) -> Unit {
  let dyn_output = ctx.config.shared || ctx.config.pie
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for sec_opt in f.sections {
          guard sec_opt is Some(sec) else { continue }
          if !sec.live || sec.discarded {
            continue
          }
          sec.dyn_actions = Some(
            (
              FixedArray::make(sec.relas.length(), Static) :
              FixedArray[DynAction]),
          )
          for k in 0..<sec.relas.length() {
            let r = sec.relas[k]
            ignore(classify_reloc(ctx, scan, f, sec, r, k, dyn_output))
          }
        }
      _ => ()
    }
  }
}

///|
/// Write phase: applies one classified relocation into the content buffer.
pub fn apply_reloc(
  ctx : Ctx,
  scan : ScanResult,
  file : ObjFile,
  input : InputSection,
  base : FixedArray[Byte],
  r : @elffile.Rela,
  action : DynAction,
  got : OutSec?,
  plt : OutSec?,
) -> Bool {
  let p = input.addr + r.offset
  let a = r.addend
  fn write(value : Int64, width : Int32) -> Bool {
    let off = r.offset.to_int()
    match width {
      8 => {
        base.unsafe_write_uint64_le(off, value.reinterpret_as_uint64())
        true
      }
      4 => {
        base.unsafe_write_uint32_le(off, value.to_int().reinterpret_as_uint())
        true
      }
      2 => {
        base.unsafe_write_uint16_le(off, value.to_int().to_uint16())
        true
      }
      1 => {
        base[off] = value.to_int().to_byte()
        true
      }
      _ => false
    }
  }
  match action {
    Static =>
      match r.rtype {
        t if t == @elfspec.R_X86_64_64 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a, 8)
            None => false
          }
        t if t == @elfspec.R_X86_64_PC32 || t == @elfspec.R_X86_64_PLT32 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a - p, 4)
            None => false
          }
        t if t == @elfspec.R_X86_64_32 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a, 4)
            None => false
          }
        t if t == @elfspec.R_X86_64_32S =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a, 4)
            None => false
          }
        t if t == @elfspec.R_X86_64_16 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a, 2)
            None => false
          }
        t if t == @elfspec.R_X86_64_PC16 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a - p, 2)
            None => false
          }
        t if t == @elfspec.R_X86_64_8 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a, 1)
            None => false
          }
        t if t == @elfspec.R_X86_64_PC8 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a - p, 1)
            None => false
          }
        t if t == @elfspec.R_X86_64_PC64 =>
          match reloc_sym_va(ctx, file, r.sym) {
            Some(s) => write(s + a - p, 8)
            None => false
          }
        t if t == @elfspec.R_X86_64_GOTPC32 || t == @elfspec.R_X86_64_GOTPC64 =>
          match got {
            Some(g) =>
              write(
                g.addr + a - p,
                if t == @elfspec.R_X86_64_GOTPC32 {
                  4
                } else {
                  8
                },
              )
            None => false
          }
        t if t == @elfspec.R_X86_64_GOTOFF64 =>
          match got {
            Some(g) =>
              match reloc_sym_va(ctx, file, r.sym) {
                Some(s) => write(s + a - g.addr, 8)
                None => false
              }
            None => false
          }
        _ => {
          ctx.diag.error(
            "\{@support.bytes_str(file.path)}: unsupported relocation type \{r.rtype}",
          )
          false
        }
      }
    PltCall =>
      match plt {
        Some(psec) =>
          match file.sym_refs[r.sym] {
            Some(ref_) => write(ref_.sym.plt_va(psec) + a - p, 4)
            None => false
          }
        None => false
      }
    GotPcRel =>
      match got {
        Some(gsec) =>
          match file.sym_refs[r.sym] {
            Some(ref_) => write(ref_.sym.got_va(gsec) + a - p, 4)
            None => false
          }
        None => false
      }
    GotDynamicPc =>
      match got {
        Some(gsec) =>
          match file.sym_refs[r.sym] {
            Some(ref_) => write(ref_.sym.got_va(gsec) + a - p, 4)
            None => false
          }
        None => false
      }
    GotAbs =>
      match got {
        Some(gsec) =>
          match file.sym_refs[r.sym] {
            Some(ref_) => write(ref_.sym.got_va(gsec) + a, 8)
            None => false
          }
        None => false
      }
    DynRela(_) => true // content stays zero; the loader fills it
  }
}

///|
/// Applies all classified relocations of one input section.
pub fn apply_relocs(
  ctx : Ctx,
  scan : ScanResult,
  file : ObjFile,
  input : InputSection,
  base : FixedArray[Byte],
  got : OutSec?,
  plt : OutSec?,
) -> Bool {
  let actions = input.dyn_actions
  let mut ok = true
  for k in 0..<input.relas.length() {
    let action = match actions {
      Some(arr) => arr[k]
      None => Static
    }
    if !apply_reloc(
        ctx,
        scan,
        file,
        input,
        base,
        input.relas[k],
        action,
        got,
        plt,
      ) {
      ok = false
    }
  }
  ok
}
