// Symbol table with lld's resolution semantics, ported from
// lld/ELF/SymbolTable.cpp and Symbol::resolve (Symbols.cpp).
//
// Precedence (Symbol::shouldReplace / resolve overloads):
//   strong Defined > weak Defined > Common > Shared > Undefined > Lazy
// with the special cases preserved (weak-undef does not extract archive
// members; common-vs-common merges; first-reference binding sticks).

///|
/// Description of one incoming symbol from a file parse, mirroring the
/// kind-specific constructors lld passes to SymbolTable::addSymbol.
pub(all) struct NewSym {
  name : Bytes
  file : FileRef
  binding : Int32
  stype : Int32
  visibility : Int32
  // Defined payload:
  section : InputSection?
  value : Int64
  size : Int64
  // Common payload:
  alignment : Int64
  // Lazy payload:
  archive : ArchiveFile?
  member_index : Int32
  // Shared payload: version tag ("" unversioned).
  version : Bytes
}

///|
pub struct SymbolTable {
  map : Map[Bytes, SymRef]
  mut next_id : Int32
  // COMDAT dedup: group signature -> file that won it.
  comdat_groups : Map[Bytes, FileRef]
  diag : @support.Diag
  duplicate_reported : Map[Bytes, Unit]
  // The owning link context, needed to extract archive members lazily.
  mut ctx : Ctx?
}

///|
pub fn SymbolTable::new(diag : @support.Diag) -> SymbolTable {
  {
    map: Map([]),
    comdat_groups: Map([]),
    diag,
    duplicate_reported: Map([]),
    ctx: None,
    next_id: 1,
  }
}

///|
/// Returns all interned symbols in insertion order.
pub fn SymbolTable::symbols(self : SymbolTable) -> Array[SymRef] {
  let out : Array[SymRef] = []
  for _, v in self.map {
    out.push(v)
  }
  out
}

///|
/// Finds an existing symbol or creates an unresolved placeholder.
pub fn SymbolTable::insert(self : SymbolTable, name : Bytes) -> SymRef {
  match self.map.get(name) {
    Some(sym) => sym
    None => {
      let fresh : SymRef = {
        sym: {
          aux_id: self.next_id,
          name,
          kind: Undefined({
            file: InternalRef,
            is_weak: true,
            referenced: false,
          }),
          binding: @elfspec.STB_WEAK,
          stype: @elfspec.STT_NOTYPE,
          visibility: @elfspec.STV_DEFAULT,
          is_exported: false,
          is_preemptible: false,
          has_version_suffix: false,
          aux: { has_got: false, got_index: -1, has_plt: false, plt_index: -1, has_dynref: false, },
        },
      }
      self.next_id += 1
      self.map[name] = fresh
      fresh
    }
  }
}

///|
pub fn SymbolTable::find(self : SymbolTable, name : Bytes) -> SymRef? {
  self.map.get(name)
}

///|
/// lld Symbol::mergeProperties: DSO symbols do not affect visibility; the
/// weakest incoming visibility wins.
fn merge_visibility(existing : Symbol, vis : Int32) -> Unit {
  if vis != @elfspec.STV_DEFAULT {
    let v = existing.visibility
    if v == @elfspec.STV_DEFAULT || vis < v {
      existing.visibility = vis
    }
  }
}

///|
/// Reports strong-vs-strong defined duplicates once per name
/// (Symbol::checkDuplicate).
fn SymbolTable::check_duplicate(
  self : SymbolTable,
  existing : Symbol,
  file : FileRef,
) -> Unit {
  if existing.binding != @elfspec.STB_WEAK &&
    !self.duplicate_reported.contains(existing.name) {
    self.duplicate_reported[existing.name] = ()
    let other = @support.bytes_str(FileRef::path_of(symbol_file(existing)))
    let incoming = @support.bytes_str(FileRef::path_of(file))
    self.diag.error(
      "duplicate symbol: \{@support.bytes_str(existing.name)} (defined in \{other} and in \{incoming})",
    )
  }
}

///|
fn symbol_file(sym : Symbol) -> FileRef {
  match sym.kind {
    Defined(d) => d.file
    Undefined(d) => d.file
    Shared(d) => d.file
    Common(d) => d.file
    Lazy(d) => ArchiveRef(d.archive)
  }
}

///|
/// Symbol::overwrite: replace the payload, preserving identity, name and
/// aux (GOT/PLT) storage.
fn overwrite(ref_ : SymRef, new : NewSym, kind : SymKind) -> Unit {
  let sym = ref_.sym
  sym.kind = kind
  sym.binding = new.binding
  sym.stype = new.stype
}

///|
/// Adds a defined symbol (regular object). Returns the stable ref.
pub fn SymbolTable::add_defined_symbol(
  self : SymbolTable,
  new : NewSym,
) -> SymRef {
  let ref_ = self.insert(new.name)
  merge_visibility(ref_.sym, new.visibility)
  self.resolve_defined(ref_, new)
  ref_
}

///|
/// Adds an undefined reference.
pub fn SymbolTable::add_undefined_symbol(
  self : SymbolTable,
  new : NewSym,
) -> Unit {
  let ref_ = self.insert(new.name)
  merge_visibility(ref_.sym, new.visibility)
  self.resolve_undefined(ref_, new)
}

///|
/// Adds a common definition.
pub fn SymbolTable::add_common_symbol(self : SymbolTable, new : NewSym) -> Unit {
  let ref_ = self.insert(new.name)
  merge_visibility(ref_.sym, new.visibility)
  self.resolve_common(ref_, new)
}

///|
/// Adds a lazy archive-member definition.
pub fn SymbolTable::add_lazy_symbol(self : SymbolTable, new : NewSym) -> Unit {
  let ref_ = self.insert(new.name)
  merge_visibility(ref_.sym, new.visibility)
  self.resolve_lazy(ref_, new)
}

///|
/// Adds a shared-object definition.
pub fn SymbolTable::add_shared_symbol(self : SymbolTable, new : NewSym) -> Unit {
  let ref_ = self.insert(new.name)
  merge_visibility(ref_.sym, new.visibility)
  self.resolve_shared(ref_, new)
}

///|
/// Port of Symbol::resolve(const Defined &).
fn SymbolTable::resolve_defined(
  self : SymbolTable,
  ref_ : SymRef,
  new : NewSym,
) -> Unit {
  let sym = ref_.sym
  let payload : DefinedData = {
    file: new.file,
    section: new.section,
    outsec: None,
    value: new.value,
    size: new.size,
    is_weak: new.binding == @elfspec.STB_WEAK,
  }
  if sym.is_defined() {
    self.check_duplicate(sym, new.file)
    // shouldReplace: incoming STB_GLOBAL overrides STB_WEAK/etc.
    let is_global = new.binding == @elfspec.STB_GLOBAL
    if sym.binding != @elfspec.STB_GLOBAL && is_global {
      overwrite(ref_, new, Defined(payload))
    }
  } else if sym.is_common() {
    // Common is overridden by a non-weak definition.
    if new.binding != @elfspec.STB_WEAK {
      overwrite(ref_, new, Defined(payload))
    }
  } else {
    overwrite(ref_, new, Defined(payload))
  }
}

///|
/// Port of Symbol::resolve(const Undefined &).
fn SymbolTable::resolve_undefined(
  self : SymbolTable,
  ref_ : SymRef,
  new : NewSym,
) -> Unit {
  let sym = ref_.sym
  let payload : UndefData = {
    file: new.file,
    is_weak: new.binding == @elfspec.STB_WEAK,
    referenced: true,
  }
  match sym.kind {
    Lazy(l) =>
      if payload.is_weak {
        // A weak undefined will not extract archive members.
        sym.binding = @elfspec.STB_WEAK
        sym.stype = new.stype
        sym.kind = Undefined(payload)
        let _ = l
      } else {
        // Strong reference: pull in the archive member now.
        self.extract_member(l.archive, l.member_index)
      }
    Shared(_) => {
      // Existing shared definition: only the binding rule applies.
      if !payload.is_weak || !undefined_referenced(sym) {
        sym.binding = if payload.is_weak {
          @elfspec.STB_WEAK
        } else {
          @elfspec.STB_GLOBAL
        }
      }
      // Mark the shared file as needed (referenced by a regular object).
      mark_shared_needed(self, sym)
    }
    Undefined(d) => {
      if !payload.is_weak || !d.referenced {
        sym.binding = if payload.is_weak {
          @elfspec.STB_WEAK
        } else {
          @elfspec.STB_GLOBAL
        }
        sym.stype = if sym.stype == @elfspec.STT_NOTYPE {
          new.stype
        } else {
          sym.stype
        }
      }
      if d.file is InternalRef {
        sym.kind = Undefined(payload)
      }
    }
    Defined(_) | Common(_) => ()
  }
}

///|
fn undefined_referenced(sym : Symbol) -> Bool {
  match sym.kind {
    Undefined(d) => d.referenced
    _ => false
  }
}

///|
/// Flags the shared object owning `sym` as needed (used by --as-needed).
fn mark_shared_needed(tab : SymbolTable, sym : Symbol) -> Unit {
  match sym.kind {
    Shared(d) =>
      match d.file {
        SharedRef(f) => f.is_needed = true
        _ => ()
      }
    _ => ()
  }
  let _ = tab
}

///|
/// Port of Symbol::resolve(const CommonSymbol &).
fn SymbolTable::resolve_common(
  self : SymbolTable,
  ref_ : SymRef,
  new : NewSym,
) -> Unit {
  let sym = ref_.sym
  let payload : CommonData = {
    file: new.file,
    size: new.size,
    alignment: new.alignment,
  }
  match sym.kind {
    Defined(d) =>
      // A strong definition overrides a common.
      if d.is_weak {
        overwrite(ref_, new, Common(payload))
        sym.binding = @elfspec.STB_GLOBAL
      }
    Common(old) => {
      if old.alignment < payload.alignment {
        old.alignment = payload.alignment
      }
      if old.size < payload.size {
        old.file = payload.file
        old.size = payload.size
      }
    }
    Shared(s) => {
      // Keep the larger st_size across the shared/common pair.
      let size = if s.size > payload.size { s.size } else { payload.size }
      overwrite(ref_, new, Common({ ..payload, size, }))
      sym.binding = @elfspec.STB_GLOBAL
    }
    Undefined(_) | Lazy(_) => {
      overwrite(ref_, new, Common(payload))
      sym.binding = @elfspec.STB_GLOBAL
    }
  }
}

///|
/// Port of Symbol::resolve(const LazySymbol &).
fn SymbolTable::resolve_lazy(
  self : SymbolTable,
  ref_ : SymRef,
  new : NewSym,
) -> Unit {
  let sym = ref_.sym
  match sym.kind {
    Undefined(d) => {
      let payload : LazyData = {
        archive: new.archive.unwrap(),
        member_index: new.member_index,
      }
      if d.is_weak {
        // Do not extract for weak references; remember the lazy source.
        overwrite(ref_, new, Lazy(payload))
        sym.binding = @elfspec.STB_WEAK
      } else {
        self.extract_member(new.archive.unwrap(), new.member_index)
      }
    }
    Defined(_) | Common(_) | Shared(_) | Lazy(_) => ()
  }
}

///|
/// Port of Symbol::resolve(const SharedSymbol &).
fn SymbolTable::resolve_shared(
  self : SymbolTable,
  ref_ : SymRef,
  new : NewSym,
) -> Unit {
  let sym = ref_.sym
  sym.is_exported = true
  let payload : SharedData = { file: new.file, size: new.size, }
  match sym.kind {
    Defined(_) | Shared(_) => ()
    Common(old) =>
      // Keep the larger st_size.
      if new.size > old.size {
        old.size = new.size
      }
    Undefined(d) => {
      let bind = sym.binding
      overwrite(ref_, new, Shared(payload))
      sym.binding = bind
      let _ = d
    }
    Lazy(_) =>
      // A lazy archive member loses to a shared definition (lld keeps lazy
      // only until referenced; shared definition wins at insert time).
      overwrite(ref_, new, Shared(payload))
  }
}

///|
/// Parses an archive member file and resolves its symbols (lld
/// LazySymbol::extract). Re-entrant: nested extractions are fine.
fn SymbolTable::extract_member(
  self : SymbolTable,
  archive : ArchiveFile,
  member_index : Int32,
) -> Unit {
  guard self.ctx is Some(ctx) else { return }
  Ctx::extract_member(ctx, archive, member_index)
}
