// Synthetic section content builders: string tables, .symtab/.strtab,
// common allocation (.bss). Ported from lld SyntheticSections.cpp
// (SymtabSection/StrTabSection subset) and Writer's common allocation.

///|
/// Deduplicating string table builder (lld StringTableSection).
pub struct StrTabBuilder {
  buf : @buffer.Buffer
  map : Map[Bytes, Int32]
}

///|
pub fn StrTabBuilder::new() -> StrTabBuilder {
  let b = { buf: @buffer.Buffer(), map: Map([]), }
  // The first byte is the empty string.
  b.buf.write_byte(b'\x00')
  b.map[b""] = 0
  b
}

///|
pub fn StrTabBuilder::add(self : StrTabBuilder, name : Bytes) -> Int32 {
  match self.map.get(name) {
    Some(off) => off
    None => {
      let off = self.buf.length()
      self.buf.write_bytes(name[:])
      self.buf.write_byte(b'\x00')
      self.map[name] = off
      off
    }
  }
}

///|
pub fn StrTabBuilder::to_bytes(self : StrTabBuilder) -> Bytes {
  self.buf.to_bytes()
}

///|
pub fn StrTabBuilder::size(self : StrTabBuilder) -> Int32 {
  self.buf.length()
}

///|
/// Allocates SHN_COMMON symbols into a NOBITS .bss output section
/// (lld Writer's common-symbol allocation). Fills ctx.common_alloc with
/// final VAs and grows `bss`.
pub fn allocate_commons(ctx : Ctx, bss : OutSec) -> Unit {
  let mut dot = bss.size
  for ref_ in ctx.symtab.symbols() {
    let sym = ref_.sym
    match sym.kind {
      Common(c) => {
        let align = if c.alignment > 1L { c.alignment } else { 1L }
        let aligned = @support.align_to(dot, align)
        ctx.common_alloc[sym.name] = aligned
        dot = aligned + c.size
      }
      _ => ()
    }
  }
  bss.size = dot
}

///|
/// Basename of a path (for STT_FILE symbols).
pub fn file_basename(path : Bytes) -> Bytes {
  let mut last = 0
  for i in 0..<path.length() {
    if path[i] == b'/' {
      last = i + 1
    }
  }
  path[last:].to_owned()
}

///|
/// Emits one 24-byte Elf64_Sym record.
fn write_sym(
  buf : @buffer.Buffer,
  strtab : StrTabBuilder,
  name : Bytes,
  binding : Int32,
  stype : Int32,
  visibility : Int32,
  shndx : Int32,
  value : Int64,
  size : Int64,
) -> Unit {
  let name_off = strtab.add(name)
  buf.write_uint_le(name_off.reinterpret_as_uint())
  buf.write_byte(((binding << 4) | stype).to_byte())
  buf.write_byte(visibility.to_byte())
  buf.write_uint16_le(shndx.to_uint16())
  buf.write_int64_le(value)
  buf.write_int64_le(size)
}

///|
/// Builds .symtab content. Layout mirrors lld: null symbol, then per input
/// file an STT_FILE symbol followed by its local definitions, then all
/// global/weak symbols in symbol-table order.
pub fn build_symtab(
  ctx : Ctx,
  strtab : StrTabBuilder,
  bss : OutSec?,
) -> (Bytes, Int32) {
  let buf = @buffer.Buffer()
  // Null symbol.
  for _ in 0..<3 {
    buf.write_int64_le(0L)
  }
  // Per-file FILE + local symbols.
  for fref in ctx.files {
    match fref {
      ObjRef(f) =>
        for j in 0..<f.raw_syms.length() {
          let raw = f.raw_syms[j]
          if raw.binding != @elfspec.STB_LOCAL {
            continue
          }
          if raw.stype == @elfspec.STT_FILE {
            // Propagate input FILE symbols (lld does not synthesize them).
            write_sym(
              buf,
              strtab,
              @elffile.sym_name(strtab_of(f), raw.name_off),
              @elfspec.STB_LOCAL,
              @elfspec.STT_FILE,
              raw.visibility,
              @elfspec.SHN_ABS,
              0L,
              0L,
            )
            continue
          }
          if raw.stype == @elfspec.STT_SECTION {
            continue
          }
          if raw.shndx == @elfspec.SHN_UNDEF {
            continue
          }
          let shndx : Int32 = if raw.shndx == @elfspec.SHN_ABS {
            @elfspec.SHN_ABS
          } else if raw.shndx > 0 &&
            raw.shndx < f.sections.length() &&
            f.sections[raw.shndx] is Some(sec) {
            if sec.discarded {
              continue
            }
            match sec.out_sec {
              Some(os) => os.shndx
              None => continue
            }
          } else {
            continue
          }
          let value : Int64 = if raw.shndx == @elfspec.SHN_ABS {
            raw.value
          } else {
            match f.sections[raw.shndx] {
              Some(sec) => sec.addr + raw.value
              None => 0L
            }
          }
          write_sym(
            buf,
            strtab,
            @elffile.sym_name(strtab_of(f), raw.name_off),
            @elfspec.STB_LOCAL,
            raw.stype,
            raw.visibility,
            shndx,
            value,
            raw.size,
          )
        }
      _ => ()
    }
  }
  let nlocals = buf.length() / @elfspec.SYM_SIZE
  // Globals in symbol-table insertion order.
  for ref_ in ctx.symtab.symbols() {
    let sym = ref_.sym
    match sym.kind {
      Defined(d) => {
        let shndx : Int32 = match d.section {
          Some(sec) =>
            match sec.out_sec {
              Some(os) => os.shndx
              None => @elfspec.SHN_ABS
            }
          None => @elfspec.SHN_ABS
        }
        write_sym(
          buf,
          strtab,
          sym.name,
          sym.binding,
          sym.stype,
          sym.visibility,
          shndx,
          sym.get_va(ctx),
          d.size,
        )
      }
      Undefined(_) =>
        write_sym(
          buf,
          strtab,
          sym.name,
          sym.binding,
          sym.stype,
          sym.visibility,
          @elfspec.SHN_UNDEF,
          0L,
          0L,
        )
      Common(_) => {
        let va = common_va(ctx, sym.name)
        let shndx = match bss {
          Some(b) => b.shndx
          None => @elfspec.SHN_ABS
        }
        write_sym(
          buf,
          strtab,
          sym.name,
          sym.binding,
          sym.stype,
          sym.visibility,
          shndx,
          va,
          sym.size_of_common(),
        )
      }
      Shared(_) | Lazy(_) => ()
    }
  }
  let _ = nlocals
  (buf.to_bytes(), nlocals)
}

///|
fn strtab_of(f : ObjFile) -> @elffile.SecData {
  match f.reader.section_data(f.reader.shdrs[f.strtab_idx]) {
    Some(s) => s
    None => { bytes: f.data, offset: 0, size: 0, }
  }
}

///|
/// Absolute VA of a common symbol: .bss base + allocated offset.
pub fn common_va(ctx : Ctx, name : Bytes) -> Int64 {
  let off = match ctx.common_alloc.get(name) {
    Some(v) => v
    None => 0L
  }
  match ctx.common_bss {
    Some(b) => b.addr + off
    None => off
  }
}

///|
fn Symbol::size_of_common(self : Symbol) -> Int64 {
  match self.kind {
    Common(c) => c.size
    _ => 0L
  }
}
