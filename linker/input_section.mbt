// InputSection: one section of an input file that participates in linking.
// Mirrors lld's InputSectionBase/InputSection split collapsed into one type
// (MVP carries SHF_MERGE and .eh_frame content unmerged).

///|
pub(all) struct InputSection {
  file : FileRef
  sec_index : Int32
  name : Bytes
  stype : Int32
  flags : Int64
  offset : Int32
  size : Int64
  addralign : Int64
  link : Int32
  info : Int32
  entsize : Int64
  mut relas : FixedArray[@elffile.Rela]
  mut dyn_actions : FixedArray[DynAction]?
  mut out_sec : OutSec?
  mut live : Bool
  mut discarded : Bool
  mut addr : Int64
  mut out_off : Int64
}

///|
fn InputSection::content(self : InputSection) -> @elffile.SecData? {
  if self.stype == @elfspec.SHT_NOBITS {
    return None
  }
  match self.file {
    ObjRef(f) => {
      let len = f.data.length().to_int64()
      if self.offset < 0 ||
        self.size < 0L ||
        self.offset.to_int64() + self.size > len {
        return None
      }
      Some({ bytes: f.data, offset: self.offset, size: self.size.to_int(), })
    }
    _ => None
  }
}

///|
fn InputSection::is_alloc(self : InputSection) -> Bool {
  has_flag(self.flags, @elfspec.SHF_ALLOC)
}

///|
fn InputSection::is_exec(self : InputSection) -> Bool {
  has_flag(self.flags, @elfspec.SHF_EXECINSTR)
}

///|
fn InputSection::is_write(self : InputSection) -> Bool {
  has_flag(self.flags, @elfspec.SHF_WRITE)
}

///|
fn InputSection::is_tls(self : InputSection) -> Bool {
  has_flag(self.flags, @elfspec.SHF_TLS)
}

///|
/// The section's contribution to PHDR flags (lld getPhdrFlags).
fn InputSection::phdr_flags(self : InputSection) -> Int32 {
  let mut f = @elfspec.PF_R
  if self.is_write() {
    f = f | @elfspec.PF_W
  }
  if self.is_exec() {
    f = f | @elfspec.PF_X
  }
  f
}
