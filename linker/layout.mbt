// OutputSection model and layout ordering, ported from lld's
// OutputSections.{h,cpp} and Writer.cpp getSectionRank/compareSections.

///|
// GNU versioning section types (not present in LLVM's ELF.h enum).
pub const SHT_GNU_versym : Int32 = 0x6fffffff

///|
pub const SHT_GNU_verneed : Int32 = 0x6ffffffe

///|
pub const SHT_GNU_verdef : Int32 = 0x6ffffffc

///|
/// What kind of linker-generated content backs a synthetic section.
pub(all) enum SynthKind {
  NotSynth
  Comment
  SymTab
  StrTab
  ShStrTab
  Bss
  Got
  GotPlt
  Plt
  RelaDyn
  RelaPlt
  DynSymTab
  DynStrTab
  Dynamic
  VerSym
  VerNeed
  GnuHash
}

///|
/// One output section. Pseudo-sections (ELF header, program headers) carry
/// `shndx = -1` and participate only in address/offset assignment.
pub(all) struct OutSec {
  name : Bytes
  mut stype : Int32
  mut flags : Int64
  mut addralign : Int64
  mut entsize : Int64
  mut inputs : Array[InputSection]
  synth : SynthKind
  mut addr : Int64
  mut offset : Int64
  mut size : Int64
  mut shndx : Int32
  mut sort_rank : Int32
  mut relro : Bool
  // PHDR flag set for segment grouping (R/RX/R/RW).
  mut load_flags : Int32
  mut in_load : Bool
  // Which PT_LOAD covers this section (-1 = none); true when first in it.
  mut load_idx : Int32
  mut load_first : Bool
  // Identity for reference comparisons; pseudo sections carry pseudo=true.
  oid : Int32
  pseudo : Bool
}

///|
let outsec_counter : Ref[Int32] = Ref::new(0)

///|
fn alloc_oid() -> Int32 {
  outsec_counter.val = outsec_counter.val + 1
  outsec_counter.val
}

///|
/// Tests an ELF flag bit stored in an Int64 flags word.
pub fn has_flag(flags : Int64, flag : Int32) -> Bool {
  (flags & flag.to_int64()) != 0L
}

///|
fn OutSec::is_alloc(self : OutSec) -> Bool {
  has_flag(self.flags, @elfspec.SHF_ALLOC)
}

///|
/// PHDR flags contribution (lld OutputSection::getPhdrFlags).
fn OutSec::phdr_flags(self : OutSec) -> Int32 {
  let mut f = @elfspec.PF_R
  if has_flag(self.flags, @elfspec.SHF_WRITE) {
    f = f | @elfspec.PF_W
  }
  if has_flag(self.flags, @elfspec.SHF_EXECINSTR) {
    f = f | @elfspec.PF_X
  }
  f
}

///|
/// Port of lld Writer.cpp getSectionRank (x86_64 subset; -T/-z special
/// cases omitted).
fn get_section_rank(sec : OutSec) -> Int32 {
  let rf_not_addr_set = 1 << 27
  let rf_not_alloc = 1 << 26
  let rf_write = 1 << 14
  let rf_exec_write = 1 << 13
  let rf_exec = 1 << 12
  let rf_rodata = 1 << 11
  let rf_not_relro = 1 << 8
  let rf_not_tls = 1 << 7
  let rf_bss = 1 << 6
  let mut rank = rf_not_addr_set
  if !sec.is_alloc() {
    return rank | rf_not_alloc
  }
  let is_exec = has_flag(sec.flags, @elfspec.SHF_EXECINSTR)
  let is_write = has_flag(sec.flags, @elfspec.SHF_WRITE)
  if !is_write && !is_exec {
    if sec.name == b".interp" {
      rank = rank | 1
    } else if sec.stype == @elfspec.SHT_NOTE {
      rank = rank | 2
    } else if sec.stype != @elfspec.SHT_PROGBITS {
      rank = rank | 3
    } else {
      rank = rank | rf_rodata
    }
  } else if is_exec {
    if is_write {
      rank = rank | rf_exec_write
    } else {
      rank = rank | rf_exec
    }
  } else {
    rank = rank | rf_write
    if !has_flag(sec.flags, @elfspec.SHF_TLS) {
      rank = rank | rf_not_tls
    }
    if !sec.relro {
      rank = rank | rf_not_relro
    }
  }
  if sec.stype == @elfspec.SHT_NOBITS {
    rank = rank | rf_bss
  }
  rank
}

///|
/// Port of lld Writer.cpp isRelroSection (subset).
fn is_relro_section(sec : OutSec) -> Bool {
  // MVP: .dynamic, .got, .got.plt (when writable pre-relocation).
  let name = sec.name
  if has_flag(sec.flags, @elfspec.SHF_TLS) {
    return true
  }
  if sec.stype == @elfspec.SHT_NOBITS {
    return false
  }
  if name is b".dynamic" ||
    name is b".got" ||
    name is b".data.rel.ro" ||
    name is b".got.plt" {
    return has_flag(sec.flags, @elfspec.SHF_WRITE)
  }
  false
}

///|
/// Stable sort by (sort_rank, insertion order) — mirrors lld's stable_sort
/// with its rank-only comparison.
pub fn stable_sort_outsecs(sections : Array[OutSec]) -> Unit {
  let n = sections.length()
  if n < 2 {
    return
  }
  // Decorate with original index for stability.
  let items : Array[(Int32, Int32, OutSec)] = []
  for i in 0..<n {
    items.push((sections[i].sort_rank, i, sections[i]))
  }
  // Simple insertion sort is fine for typical section counts (n < 200).
  for i in 1..<items.length() {
    let mut j = i
    while j > 0 && items[j].0 < items[j - 1].0 {
      let tmp = items[j]
      items[j] = items[j - 1]
      items[j - 1] = tmp
      j -= 1
    }
  }
  for i in 0..<n {
    sections[i] = items[i].2
  }
}
