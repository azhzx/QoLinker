// Top-level driver: mirrors lld's linkerMain for the static MVP subset.

///|
/// Runs the full link. Returns normally even on errors (diagnostics have
/// been reported); the process exit code is derived from diag.
pub fn run_link(args : Array[Bytes]) -> Unit {
  let diag = @support.Diag::new()
  guard parse_args(args, diag) is Some(config) else {
    diag.finish()
    return
  }
  let ctx = Ctx::new(config, diag)
  // Linker script (-T): parse before linking; ENTRY/`. =` feed the config.
  match config.script {
    Some(path) =>
      match @support.read_file(path) {
        Some(data) =>
          match parse_script(data, diag) {
            Some(s) => {
              match s.image_base {
                Some(base) => config.image_base = base
                None => ()
              }
              match s.entry {
                Some(e) => config.entry = e
                None => ()
              }
              ctx.script = Some(s)
            }
            None => ()
          }
        None => diag.error("cannot read linker script")
      }
    None => ()
  }
  match config.version_script {
    Some(path) =>
      match @support.read_file(path) {
        Some(data) =>
          match parse_version_script(data, diag) {
            Some(vs) => ctx.version_script = Some(vs)
            None => ()
          }
        None => diag.error("cannot read version script")
      }
    None => ()
  }
  // Load all inputs (archive members may be extracted recursively).
  for path in config.inputs {
    Ctx::load_file(ctx, path)
  }
  if diag.errors > 0 {
    diag.finish()
    return
  }
  link_write(ctx)
  diag.finish()
}
