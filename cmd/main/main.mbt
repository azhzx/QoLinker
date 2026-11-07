///|
/// QoLinker entry point: an ld.lld-compatible ELF linker (MVP).
fn main {
  let args = @env.args()
  let argv : Array[Bytes] = []
  for a in args[1:] {
    argv.push(@utf8.encode(a))
  }
  @linker.run_link(argv)
}
