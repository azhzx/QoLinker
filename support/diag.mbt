// Diagnostics in the style of lld: `error:` / `warning:` / `fatal error:`
// prefixes on stderr, with error counting. Fatal errors terminate the process.

///|
pub struct Diag {
  mut errors : Int32
  mut warnings : Int32
}

///|
pub fn Diag::new() -> Diag {
  { errors: 0, warnings: 0, }
}

///|
pub fn Diag::error(self : Diag, msg : String) -> Unit {
  self.errors += 1
  eprintln("error: \{msg}")
}

///|
pub fn Diag::warn(self : Diag, msg : String) -> Unit {
  self.warnings += 1
  eprintln("warning: \{msg}")
}

///|
/// Prints `fatal error: msg` and terminates immediately (exit code 1).
pub fn Diag::fatal(self : Diag, msg : String) -> Unit {
  let _ = self
  eprintln("fatal error: \{msg}")
  exit(1)
}

///|
/// lld-style post-mortem: if any errors were reported, print the trailing
/// summary and exit non-zero.
pub fn Diag::finish(self : Diag) -> Unit {
  if self.errors > 0 {
    eprintln("\{self.errors} error(s) occurred, output may be invalid")
    exit(1)
  }
}
