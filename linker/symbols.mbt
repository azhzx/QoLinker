// Symbol model. Ported from lld/ELF/Symbols.{h,cpp}:
// lld keeps one `Symbol` per name and replaces its payload in-place
// (placement-new into SymbolUnion) as resolution proceeds. Here a `SymRef`
// cell holds the current `Symbol`; every reference to a symbol is a SymRef,
// so replacing `ref.sym` preserves pointer semantics.

///|
/// Owning file of a symbol or section. `InternalRef` is the linker's
/// pseudo-file for linker-defined symbols.
pub(all) enum FileRef {
  ObjRef(ObjFile)
  SharedRef(SharedFile)
  ArchiveRef(ArchiveFile)
  InternalRef
}

///|
pub(all) struct DefinedData {
  file : FileRef
  section : InputSection?
  // Alternative anchor for linker-provided symbols: final VA is
  // outsec.addr + value (used for _end/_edata etc.).
  mut outsec : OutSec?
  value : Int64
  size : Int64
  mut is_weak : Bool
}

///|
pub(all) struct UndefData {
  file : FileRef
  mut is_weak : Bool
  mut referenced : Bool
}

///|
pub(all) struct SharedData {
  file : FileRef
  size : Int64
}

///|
pub(all) struct CommonData {
  mut file : FileRef
  mut size : Int64
  mut alignment : Int64
}

///|
pub(all) struct LazyData {
  archive : ArchiveFile
  member_index : Int32
}

///|
pub(all) enum SymKind {
  Defined(DefinedData)
  Undefined(UndefData)
  Shared(SharedData)
  Common(CommonData)
  Lazy(LazyData)
}

///|
/// Per-symbol aux storage for GOT/PLT/related allocations. All values start
/// "unset" (indices -1, flags false).
pub(all) struct SymAux {
  mut has_got : Bool
  mut got_index : Int32
  mut has_plt : Bool
  mut plt_index : Int32
  // Referenced by a dynamic relocation in the output (RELATIVE/GLOB_DAT/64).
  mut has_dynref : Bool
}

///|
pub(all) struct Symbol {
  aux_id : Int32
  name : Bytes
  mut kind : SymKind
  mut binding : Int32
  mut stype : Int32
  mut visibility : Int32
  mut is_exported : Bool
  mut is_preemptible : Bool
  mut has_version_suffix : Bool
  aux : SymAux
}

///|
/// The stable handle handed out for a name; resolution swaps `sym` in place.
pub(all) struct SymRef {
  mut sym : Symbol
}

///|
pub fn Symbol::is_defined(self : Symbol) -> Bool {
  match self.kind {
    Defined(_) => true
    _ => false
  }
}

///|
pub fn Symbol::is_common(self : Symbol) -> Bool {
  match self.kind {
    Common(_) => true
    _ => false
  }
}

///|
pub fn Symbol::is_lazy(self : Symbol) -> Bool {
  match self.kind {
    Lazy(_) => true
    _ => false
  }
}

///|
pub fn Symbol::is_undefined(self : Symbol) -> Bool {
  match self.kind {
    Undefined(_) => true
    _ => false
  }
}

///|
fn SymRef::is_defined(self : SymRef) -> Bool {
  match self.sym.kind {
    Defined(_) => true
    _ => false
  }
}

///|
fn SymRef::is_lazy(self : SymRef) -> Bool {
  match self.sym.kind {
    Lazy(_) => true
    _ => false
  }
}

///|
fn SymRef::is_undefined(self : SymRef) -> Bool {
  match self.sym.kind {
    Undefined(_) => true
    _ => false
  }
}

///|
fn SymRef::is_common(self : SymRef) -> Bool {
  match self.sym.kind {
    Common(_) => true
    _ => false
  }
}

///|
/// Final value of a defined/common symbol: section VA + st_value, or the
/// absolute value when unsectioned. Assigned after layout.
fn Symbol::get_va(self : Symbol, ctx : Ctx) -> Int64 {
  match self.kind {
    Defined(d) =>
      match d.section {
        Some(sec) => sec.addr + d.value
        None =>
          match d.outsec {
            Some(os) => os.addr + d.value
            None => ctx.config.image_base + d.value
          }
      }
    Common(_) => common_va(ctx, self.name)
    _ => 0L
  }
}

///|
fn Symbol::file_path(self : Symbol) -> Bytes {
  match self.kind {
    Defined(d) => FileRef::path_of(d.file)
    Undefined(d) => FileRef::path_of(d.file)
    Shared(d) => FileRef::path_of(d.file)
    Common(d) => FileRef::path_of(d.file)
    Lazy(d) => d.archive.path
  }
}

///|
fn FileRef::path_of(self : FileRef) -> Bytes {
  match self {
    ObjRef(f) => f.path
    SharedRef(f) => f.path
    ArchiveRef(f) => f.path
    InternalRef => b"<internal>"
  }
}
