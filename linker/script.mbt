// Linker script support, ported from lld ScriptParser.cpp/LinkerScript.cpp
// — MVP subset: ENTRY, `. = addr;` (image base), symbol assignment,
// PROVIDE, and SECTIONS with wildcard input placement. Missing: PHDRS,
// MEMORY, expressions beyond +/-, AT/ALIGN beyond section alignment.

///|
pub(all) enum ScriptElem {
  Entry(Bytes)
  DotAssign(Int64)
  Assign(Bytes, Int64, Bool)
  Outsec(Bytes, Array[Bytes])
}

///|
pub struct Script {
  elems : Array[ScriptElem]
  mut image_base : Int64?
  mut entry : Bytes?
}

///|
/// Tokenizes and parses a linker script. Returns None on syntax errors
/// (diagnostics are reported through `diag`).
pub fn parse_script(data : Bytes, diag : @support.Diag) -> Script? {
  let toks = tokenize(data)
  let s : Script = { elems: [], image_base: None, entry: None, }
  let mut i = 0
  let n = toks.length()
  fn is_kw(t : Bytes, k : String) -> Bool {
    @support.bytes_str(t) == k
  }
  while i < n {
    let t = toks[i]
    if is_kw(t, "ENTRY") {
      guard i + 3 < n && is_kw(toks[i + 1], "(") else {
        diag.error("script: malformed ENTRY")
        return None
      }
      let name = toks[i + 2]
      s.elems.push(Entry(name))
      s.entry = Some(name)
      i += 4
    } else if is_kw(t, "PROVIDE") || is_kw(t, "PROVIDE_HIDDEN") {
      // PROVIDE(sym = expr); — MVP: symbol = dot.
      guard i + 5 < n && is_kw(toks[i + 1], "(") else {
        diag.error("script: malformed PROVIDE")
        return None
      }
      let name = toks[i + 2]
      s.elems.push(Assign(name, 0L, true))
      i += 6 // PROVIDE ( sym = . ) ;
    } else if is_kw(t, "SECTIONS") {
      i += 1
      guard i < n && is_kw(toks[i], "{") else {
        diag.error("script: expected { after SECTIONS")
        return None
      }
      i += 1
      guard parse_sections_body(s, toks, i, diag) is Some(next_i) else {
        return None
      }
      i = next_i
    } else if is_kw(t, "OUTPUT_FORMAT") ||
      is_kw(t, "OUTPUT_ARCH") ||
      is_kw(t, "TARGET") ||
      is_kw(t, "SEARCH_DIR") ||
      is_kw(t, "STARTUP") ||
      is_kw(t, "INPUT") ||
      is_kw(t, "GROUP") {
      // Accepted and skipped: single parenthesized argument.
      i += 4
    } else {
      diag.error("script: unexpected token \{@support.bytes_str(t)}")
      return None
    }
  }
  Some(s)
}

///|
/// Parses the inside of `SECTIONS { ... }`; returns the index after `}`.
fn parse_sections_body(
  s : Script,
  toks : Array[Bytes],
  start : Int32,
  diag : @support.Diag,
) -> Int32? {
  let mut i = start
  let n = toks.length()
  fn is_kw(t : Bytes, k : String) -> Bool {
    @support.bytes_str(t) == k
  }
  while i < n {
    let t = toks[i]
    if is_kw(t, "}") {
      return Some(i + 1)
    }
    if is_kw(t, ".") {
      // `. = 0xN ;` — image base (first occurrence) or ignored re-assignments.
      guard i + 3 < n && is_kw(toks[i + 1], "=") else {
        diag.error("script: malformed dot assignment")
        return None
      }
      match parse_number(toks[i + 2]) {
        Some(v) =>
          if s.image_base is None {
            s.image_base = Some(v)
            s.elems.push(DotAssign(v))
          }
        None => {
          diag.error("script: unsupported dot expression")
          return None
        }
      }
      i += 4
    } else if is_kw(t, "PROVIDE") || is_kw(t, "PROVIDE_HIDDEN") {
      guard i + 5 < n && is_kw(toks[i + 1], "(") else {
        diag.error("script: malformed PROVIDE")
        return None
      }
      s.elems.push(Assign(toks[i + 2], 0L, true))
      i += 6
    } else if i + 1 < n && is_kw(toks[i + 1], "=") {
      // sym = . ;
      s.elems.push(Assign(t, 0L, false))
      i += 4
    } else if i + 1 < n && is_kw(toks[i + 1], ":") {
      // output section: NAME : { patterns }
      let name = t
      i += 2
      guard i < n && is_kw(toks[i], "{") else {
        diag.error("script: expected { in output section")
        return None
      }
      i += 1
      let patterns : Array[Bytes] = []
      while i < n && !is_kw(toks[i], "}") {
        let p = toks[i]
        if is_kw(p, "KEEP") {
          i += 1
        } else if is_kw(p, "*") {
          // `*(...)`: wildcard file spec — skip the parens, keep inner
          // patterns; a bare `*` (no following paren) matches everything.
          if i + 1 < n && is_kw(toks[i + 1], "(") {
            i += 2
          } else {
            patterns.push(p)
            i += 1
          }
        } else if is_kw(p, "(") || is_kw(p, ")") {
          i += 1
        } else {
          patterns.push(p)
          i += 1
        }
      }
      guard i < n else {
        diag.error("script: unterminated output section")
        return None
      }
      i += 1 // consume }
      s.elems.push(Outsec(name, patterns))
    } else {
      diag.error(
        "script: unexpected token \{@support.bytes_str(t)} in SECTIONS",
      )
      return None
    }
  }
  diag.error("script: unterminated SECTIONS")
  return None
}

///|
/// Hex/decimal number literals (with optional K/M suffix).
fn parse_number(t : Bytes) -> Int64? {
  let s = @support.bytes_str(t)
  let s = if s.ends_with("K") || s.ends_with("k") {
    s.substring(start=0, end=s.length() - 1) + "*1024"
  } else if s.ends_with("M") || s.ends_with("m") {
    s.substring(start=0, end=s.length() - 1) + "*1048576"
  } else {
    s
  }
  if starts_with_str(s, "0x") || starts_with_str(s, "0X") {
    parse_hex(s.substring(start=2))
  } else {
    parse_dec(s)
  }
}

///|
fn parse_hex(s : String) -> Int64? {
  let mut v : Int64 = 0L
  for c in s {
    let d = match c {
      '0'..<='9' => c.to_int() - '0'.to_int()
      'a'..<='f' => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' => c.to_int() - 'A'.to_int() + 10
      _ => return None
    }
    v = v * 16L + d.to_int64()
  }
  Some(v)
}

///|
fn parse_dec(s : String) -> Int64? {
  let mut v : Int64 = 0L
  for c in s {
    guard c is ('0'..<='9') else { return None }
    v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(v)
}

///|
/// Whitespace/comment tokenizer: identifiers, numbers, punctuation.
fn tokenize(data : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let buf : Array[Byte] = []
  let flush = () => {
    if buf.length() > 0 {
      out.push(Bytes::from_array(buf[:]))
      buf.clear()
    }
  }
  let mut i = 0
  let n = data.length()
  let mut in_comment = false
  while i < n {
    let c = data[i]
    if in_comment {
      if c == b'\n' {
        in_comment = false
      }
      i += 1
      continue
    }
    if c == b'/' && i + 1 < n && data[i + 1] == b'*' {
      in_comment = true
      i += 2
      continue
    }
    let is_ws = c == b' ' || c == b'\t' || c == b'\n' || c == b'\r'
    let is_punct = c == b'{' ||
      c == b'}' ||
      c == b':' ||
      c == b';' ||
      c == b'(' ||
      c == b')' ||
      c == b'=' ||
      c == b','
    if is_ws {
      flush()
      i += 1
    } else if is_punct {
      flush()
      out.push(Bytes::from_array([c][:]))
      i += 1
    } else {
      buf.push(c)
      i += 1
    }
  }
  flush()
  out
}

///|
/// Wildcard match supporting a single leading/trailing '*'.
pub fn pattern_match(pattern : Bytes, name : Bytes) -> Bool {
  if pattern == b"*" {
    return true
  }
  let p = @support.bytes_str(pattern)
  let s = @support.bytes_str(name)
  if p.ends_with("*") {
    let prefix = p.substring(start=0, end=p.length() - 1)
    return starts_with_str(s, prefix)
  }
  if starts_with_str(p, "*") {
    let suffix = p.substring(start=1)
    return ends_with_str(s, suffix)
  }
  p == s
}

///|
fn starts_with_str(s : String, prefix : String) -> Bool {
  if s.length() < prefix.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if s[i] != prefix[i] {
      return false
    }
  }
  true
}

///|
fn ends_with_str(s : String, suffix : String) -> Bool {
  if s.length() < suffix.length() {
    return false
  }
  let off = s.length() - suffix.length()
  for i in 0..<suffix.length() {
    if s[off + i] != suffix[i] {
      return false
    }
  }
  true
}
