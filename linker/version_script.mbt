// Version script (--version-script) MVP: global/local pattern lists control
// which symbols a -shared output exports. Version definitions themselves
// (verdef) are not emitted yet — unversioned exports remain loadable.

///|
pub struct VersionScript {
  global : Array[Bytes]
  local : Array[Bytes]
}

///|
/// Parses the common `{ global: pat pat; local: pat; };` shape. Anonymous
/// version scripts only; named versions (GLIBC_x { ... }) are accepted and
/// merged into the global/local sets.
pub fn parse_version_script(
  data : Bytes,
  diag : @support.Diag,
) -> VersionScript? {
  let toks = tokenize(data)
  let vs : VersionScript = { global: [], local: [], }
  let mut mode : Int32 = 0 // 0 = outer, 1 = global, 2 = local
  let mut i = 0
  let n = toks.length()
  while i < n {
    let t = @support.bytes_str(toks[i])
    if t == "{" {
      i += 1
    } else if t == "}" {
      i += 1
      // Optional trailing ';'
      if i < n && @support.bytes_str(toks[i]) == ";" {
        i += 1
      }
    } else if t == "global" || t == "global:" {
      mode = 1
      i += if i + 1 < n && @support.bytes_str(toks[i + 1]) == ":" {
        2
      } else {
        1
      }
    } else if t == "local" || t == "local:" {
      mode = 2
      i += if i + 1 < n && @support.bytes_str(toks[i + 1]) == ":" {
        2
      } else {
        1
      }
    } else if t == ";" {
      i += 1
    } else if t == "version" || t == "VERSION_1" || t == "VERSION" {
      // Skip version tag declarations.
      i += 1
    } else {
      // A pattern (possibly `name@version` — MVP: strip the @suffix).
      let raw = toks[i]
      let pat = strip_version_tag(raw)
      match mode {
        1 => vs.global.push(pat)
        2 => vs.local.push(pat)
        _ => {
          diag.error("version script: pattern outside global/local block")
          return None
        }
      }
      i += 1
      // Optional ';'
      if i < n && @support.bytes_str(toks[i]) == ";" {
        i += 1
      }
    }
  }
  Some(vs)
}

///|
fn strip_version_tag(name : Bytes) -> Bytes {
  // "foo@@VER" / "foo@VER" → "foo"
  for i in 0..<name.length() {
    if name[i] == b'@' {
      return name[:i].to_owned()
    }
  }
  name
}

///|
/// Should this symbol be exported from a -shared output, given the version
/// script? No script → export by visibility (lld default).
pub fn version_script_exports(
  vs : VersionScript?,
  name : Bytes,
  default_export : Bool,
) -> Bool {
  match vs {
    None => default_export
    Some(v) => {
      // lld precedence: exact matches beat wildcards; globals beat the
      // catch-all `local: *`.
      for gi in 0..<v.global.length() {
        if v.global[gi] == name {
          return true
        }
      }
      for li in 0..<v.local.length() {
        if v.local[li] == name {
          return false
        }
      }
      for li in 0..<v.local.length() {
        if pattern_match(v.local[li], name) {
          return false
        }
      }
      for gi in 0..<v.global.length() {
        if pattern_match(v.global[gi], name) {
          return true
        }
      }
      false
    }
  }
}
