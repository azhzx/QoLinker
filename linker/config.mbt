// Command-line configuration: a compatible subset of ld.lld's options.

///|
pub(all) struct Config {
  mut output : Bytes
  mut entry : Bytes
  mut entry_given : Bool
  defsyms : Array[Bytes]
  inputs : Array[Bytes]
  mut shared : Bool
  mut pie : Bool
  mut gc_sections : Bool
  mut image_base : Int64
  page_size : Int64
  library_paths : Array[Bytes]
  mut map_file : Bytes?
  mut script : Bytes?
  mut version_script : Bytes?
  mut build_id : Bool
  mut export_dynamic : Bool
  // toggles for -l resolution / archive semantics
  mut whole_archive : Bool
  mut as_needed : Bool
  mut search_static : Bool
  mut z_separate_code : Bool
  mut print_gc_sections : Bool
}

///|
fn default_config() -> Config {
  {
    output: b"a.out",
    entry: b"_start",
    entry_given: false,
    defsyms: [],
    inputs: [],
    shared: false,
    pie: false,
    gc_sections: false,
    image_base: 0x200000L,
    page_size: 4096L,
    library_paths: [],
    map_file: None,
    script: None,
    version_script: None,
    build_id: false,
    export_dynamic: false,
    whole_archive: false,
    as_needed: false,
    search_static: false,
    z_separate_code: false,
    print_gc_sections: false,
  }
}

///|
/// Options whose next argument is a value we accept and ignore.
let value_ignored_opts : Array[String] = [
  "--script", "--defsym", "-soname", "--exclude-libs", "--lto-O", "--lto-partitions",
  "--thinlto-jobs", "--thinlto-cache-dir", "--lto-cache-dir", "--dependency-file",
  "--symbol-ordering-file", "--call-graph-profile-sort", "--orphan-handling",
  "--section-start", "--spare-dynamic-tags", "--opt-bisect-limit", "--print-memory-usage",
  "-m", "-O", "--hash-style", "-plugin", "--sysroot", "--sort-section", "--icf",
  "--compression-level", "-e", "--entry", "-T",
]

///|
/// Flags accepted and ignored outright.
let flag_ignored_opts : Array[String] = [
  "--start-group", "--end-group", "--no-undefined", "--noinhibit-exec", "--allow-multiple-definition",
  "--fatal-warnings", "--no-fatal-warnings", "--no-demangle", "--demangle", "--color-diagnostics=auto",
  "--enable-new-dtags", "--disable-new-dtags", "--no-undefined-version", "--as-needed",
  "--eh-frame-hdr", "--no-eh-frame-hdr", "-save-temps", "--save-temps",
  "--no-save-temps", "--apply-dynamic-relocs", "--push-state", "--pop-state",
  "--start-lib", "--end-lib", "--nostdlib", "--no-copy-dt-needed-entries",
  "--warn-common", "--no-warn-common", "--no-mmap-output-file", "--full-shutdown",
  "--no-threads", "--thinlto-emit-indexes", "--reverse-sections", "--no-relax",
  "--execute-only", "--no-execute-only", "--separate-code", "--no-separate-code",
  "--rosegment", "--no-rosegment", "--xosegment", "--no-xosegment",
]

///|
fn is_flag_ignored(arg : String) -> Bool {
  for f in flag_ignored_opts {
    if f == arg {
      return true
    }
  }
  false
}

///|
fn starts_with(arg : String, prefix : String) -> Bool {
  if arg.length() < prefix.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if arg[i] != prefix[i] {
      return false
    }
  }
  true
}

///|
/// Parses argv (already expanded from response files). Returns None after
/// printing diagnostics for unsupported or malformed options.
pub fn parse_args(args : Array[Bytes], diag : @support.Diag) -> Config? {
  let cfg = default_config()
  // Expand @response files first.
  let argv : Array[Bytes] = []
  for arg in args {
    if arg.length() > 1 && arg[0] == b'@' {
      expand_response_file(arg[1:].to_owned(), argv, diag)
    } else {
      argv.push(arg)
    }
  }
  let count = argv.length()
  let mut i = 0
  let mut ok = true
  while i < count && ok {
    let a = argv[i]
    let arg = @support.bytes_str(a)
    if arg == "-o" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.output = argv[i + 1]
        i += 2
      }
    } else if arg == "-e" || arg == "--entry" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.entry = argv[i + 1]
        cfg.entry_given = true
        i += 2
      }
    } else if starts_with(arg, "-e:") {
      cfg.entry = a[3:].to_owned()
      cfg.entry_given = true
      i += 1
    } else if arg == "-shared" || arg == "--shared" || arg == "-Bshareable" {
      cfg.shared = true
      i += 1
    } else if arg == "-pie" || arg == "--pie" {
      cfg.pie = true
      i += 1
    } else if arg == "--no-pie" {
      cfg.pie = false
      i += 1
    } else if arg == "-static" || arg == "--static" || arg == "-dn" {
      cfg.search_static = true
      i += 1
    } else if arg == "--print-gc-sections" {
      cfg.print_gc_sections = true
      i += 1
    } else if arg == "--gc-sections" {
      cfg.gc_sections = true
      i += 1
    } else if arg == "--no-gc-sections" {
      cfg.gc_sections = false
      i += 1
    } else if arg == "-L" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.library_paths.push(argv[i + 1])
        i += 2
      }
    } else if starts_with(arg, "-L") {
      cfg.library_paths.push(a[2:].to_owned())
      i += 1
    } else if arg == "--no-as-needed" {
      cfg.as_needed = false
      i += 1
    } else if arg == "--whole-archive" {
      cfg.whole_archive = true
      i += 1
    } else if arg == "--no-whole-archive" {
      cfg.whole_archive = false
      i += 1
    } else if arg == "-Bstatic" || arg == "-dn_" {
      cfg.search_static = true
      i += 1
    } else if arg == "-Bdynamic" || arg == "--dynamic-lib" {
      cfg.search_static = false
      i += 1
    } else if arg == "-T" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.script = Some(argv[i + 1])
        i += 2
      }
    } else if arg == "--version-script" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.version_script = Some(argv[i + 1])
        i += 2
      }
    } else if arg == "-Map" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.map_file = Some(argv[i + 1])
        i += 2
      }
    } else if arg == "--build-id" || arg == "--build-id=sha1" {
      cfg.build_id = true
      i += 1
    } else if arg == "--build-id=none" {
      cfg.build_id = false
      i += 1
    } else if arg == "--export-dynamic" || arg == "-E" {
      cfg.export_dynamic = true
      i += 1
    } else if arg == "-z" {
      if i + 1 < count {
        let z = @support.bytes_str(argv[i + 1])
        if z == "separate-code" {
          cfg.z_separate_code = true
        } else if z == "noseparate-code" {
          cfg.z_separate_code = false
        }
        i += 2
      } else {
        i += 1
      }
    } else if arg == "-v" || arg == "--version" || arg == "-V" {
      println("QoLinker (ld.lld-compatible subset), MVP build")
      i += 1
    } else if arg == "--help" {
      println("usage: qolink [-o out] [files|.a|.so] [-Ldir] [-l lib] ...")
      i += 1
    } else if arg == "-l" {
      if i + 1 >= count {
        missing(diag, arg)
        ok = false
      } else {
        cfg.inputs.push(resolve_library(cfg, argv[i + 1], diag))
        i += 2
      }
    } else if starts_with(arg, "-l") {
      cfg.inputs.push(resolve_library(cfg, a[2:].to_owned(), diag))
      i += 1
    } else if starts_with(arg, "--script=") {
      cfg.script = Some(a[9:].to_owned())
      i += 1
    } else if starts_with(arg, "-soname=") || starts_with(arg, "--soname=") {
      ignore(a) // SONAME of -shared outputs: recorded with -shared emit later
      i += 1
    } else if starts_with(arg, "--defsym=") {
      // sym=value: MVP accepts and defines the symbol at link time via the
      // script symbol walker; value expressions other than numbers are not
      // supported yet.
      cfg.defsyms.push(a[9:].to_owned())
      i += 1
    } else if starts_with(arg, "--hash-style=") || starts_with(arg, "--icf=") ||
    starts_with(arg, "--opt-bisect-limit=") || starts_with(arg, "-O") ||
    starts_with(arg, "--lto-O") || starts_with(arg, "--plugin-opt=") ||
    starts_with(arg, "-melf") || starts_with(arg, "--build-id=") ||
    starts_with(arg, "--orphan-handling=") || starts_with(arg, "--sort-section=") ||
    starts_with(arg, "--exclude-libs=") || starts_with(arg, "--spare-dynamic-tags=") ||
    starts_with(arg, "--section-start=") {
      i += 1
    } else if is_flag_ignored(arg) || is_value_ignored(arg) {
      i += if is_value_ignored(arg) { 2 } else { 1 }
    } else if arg == "-r" || arg == "--relocatable" {
      diag.error("-r (relocatable output) is not supported in MVP")
      ok = false
    } else if arg.length() > 1 && arg[0] == '-' && arg[1] == '-' {
      diag.error("unknown option: \{arg}")
      ok = false
    } else if arg.length() > 1 && arg[0] == '-' {
      diag.error("unknown option: \{arg}")
      ok = false
    } else {
      cfg.inputs.push(a)
      i += 1
    }
  }
  if ok {
    // PIE/shared outputs are position-independent: lld defaults base 0.
    if cfg.shared || cfg.pie {
      cfg.image_base = 0L
    }
    Some(cfg)
  } else {
    None
  }
}

///|
fn is_value_ignored(arg : String) -> Bool {
  for f in value_ignored_opts {
    if f == arg {
      return true
    }
  }
  false
}

///|
fn missing(diag : @support.Diag, arg : String) -> Unit {
  diag.error("missing argument to \{arg}")
}

///|
/// Resolves -l<name> against library paths: libX.so first, then libX.a.
fn resolve_library(cfg : Config, name : Bytes, diag : @support.Diag) -> Bytes {
  let so = concat3(b"lib", name, b".so")
  let ar = concat3(b"lib", name, b".a")
  for dir in cfg.library_paths {
    if cfg.search_static {
      if try_readable(dir, ar) {
        return join_path(dir, ar)
      }
    } else {
      if try_readable(dir, so) {
        return join_path(dir, so)
      }
      if try_readable(dir, ar) {
        return join_path(dir, ar)
      }
    }
  }
  diag.warn("unable to find library -l\{@support.bytes_str(name)}")
  ar
}

///|
fn try_readable(dir : Bytes, name : Bytes) -> Bool {
  @support.read_file(join_path(dir, name)) is Some(_)
}

///|
fn join_path(dir : Bytes, name : Bytes) -> Bytes {
  concat3(dir, b"/", name)
}

///|
fn concat3(a : Bytes, b : Bytes, c : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(a[:])
  buf.write_bytes(b[:])
  buf.write_bytes(c[:])
  buf.to_bytes()
}

///|
/// Expands `@file` response files (whitespace-separated arguments).
fn expand_response_file(
  path : Bytes,
  out : Array[Bytes],
  diag : @support.Diag,
) -> Unit {
  guard @support.read_file(path) is Some(data) else {
    diag.error("cannot read response file \{@support.bytes_str(path)}")
    return
  }
  // Tokenize on ASCII whitespace.
  let buf : Array[Byte] = []
  let flush = () => {
    if buf.length() > 0 {
      out.push(Bytes::from_array(buf[:]))
      buf.clear()
    }
  }
  for i in 0..<data.length() {
    let c = data[i]
    if c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' {
      flush()
    } else {
      buf.push(c)
    }
  }
  flush()
}
