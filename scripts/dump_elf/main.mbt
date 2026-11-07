// Dump sections/symbols of an ELF file using the QoLinker reader.
// M0 acceptance check: output must match llvm-readelf for the same file.
//
// Usage: moon run --target native scripts/dump_elf -- <path.o>

///|
fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    println("usage: dump_elf <path>")
    return
  }
  let path = @utf8.encode(args[1])
  guard @support.read_file(path) is Some(data) else {
    println("cannot read \{args[1]}")
    return
  }
  guard @elffile.parse_elf(data) is Some(reader) else {
    println("not a parseable ELF64 LE file: \{args[1]}")
    return
  }
  println("sections: \{reader.shdrs.length()}")
  for i in 0..<reader.shdrs.length() {
    let s = reader.shdrs[i]
    println(
      "  [\{i}] \{@support.bytes_str(reader.section_name(s))} type=\{s.stype} flags=0x\{@support.hex_u64(s.flags)} off=\{s.offset} size=\{s.size} align=\{s.addralign} link=\{s.link} info=\{s.info}",
    )
  }
  // Dump the first SHT_SYMTAB found.
  for i in 0..<reader.shdrs.length() {
    let s = reader.shdrs[i]
    if s.stype == @elfspec.SHT_SYMTAB {
      guard reader.section_data(s) is Some(sec) else { continue }
      guard reader.section_data(reader.shdrs[s.link]) is Some(strs) else {
        continue
      }
      guard @elffile.read_syms(sec) is Some(syms) else { continue }
      println("symbols: \{syms.length()}")
      for j in 0..<syms.length() {
        let sym = syms[j]
        println(
          "  [\{j}] \{@support.bytes_str(@elffile.sym_name(strs, sym.name_off))} bind=\{sym.binding} type=\{sym.stype} shndx=\{sym.shndx} value=0x\{@support.hex_u64(sym.value)} size=\{sym.size}",
        )
      }
      break
    }
  }
}
