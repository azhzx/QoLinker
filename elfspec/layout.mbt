// Fixed byte layouts of ELF64 structures (little-endian inputs only, per MVP
// scope). Field offsets follow the generic ELF64 gABI: see
// https://refspecs.linuxbase.org/elf/gabi4+/ch4.eheader.html

///|
pub const EH_SIZE : Int32 = 64

///|
pub const EH_ENTRY_OFF : Int32 = 24

///|
pub const EH_PHOFF_OFF : Int32 = 32

///|
pub const EH_SHOFF_OFF : Int32 = 40

///|
pub const EH_FLAGS_OFF : Int32 = 48

///|
pub const EH_EHSIZE_OFF : Int32 = 52

///|
pub const EH_PHENTSIZE_OFF : Int32 = 54

///|
pub const EH_PHNUM_OFF : Int32 = 56

///|
pub const EH_SHENTSIZE_OFF : Int32 = 58

///|
pub const EH_SHNUM_OFF : Int32 = 60

///|
pub const EH_SHSTRNDX_OFF : Int32 = 62

///|
pub const SHDR_SIZE : Int32 = 64

///|
pub const SHDR_NAME_OFF : Int32 = 0

///|
pub const SHDR_TYPE_OFF : Int32 = 4

///|
pub const SHDR_FLAGS_OFF : Int32 = 8

///|
pub const SHDR_ADDR_OFF : Int32 = 16

///|
pub const SHDR_OFFSET_OFF : Int32 = 24

///|
pub const SHDR_SIZE_OFF : Int32 = 32

///|
pub const SHDR_LINK_OFF : Int32 = 40

///|
pub const SHDR_INFO_OFF : Int32 = 44

///|
pub const SHDR_ADDRALIGN_OFF : Int32 = 48

///|
pub const SHDR_ENTSIZE_OFF : Int32 = 56

///|
pub const SYM_SIZE : Int32 = 24

///|
pub const SYM_NAME_OFF : Int32 = 0

///|
pub const SYM_INFO_OFF : Int32 = 4

///|
pub const SYM_OTHER_OFF : Int32 = 5

///|
pub const SYM_SHNDX_OFF : Int32 = 6

///|
pub const SYM_VALUE_OFF : Int32 = 8

///|
pub const SYM_SIZE_OFF : Int32 = 16

///|
pub const REL_SIZE : Int32 = 16

///|
pub const RELA_SIZE : Int32 = 24

///|
pub const REL_OFFSET_OFF : Int32 = 0

///|
pub const REL_INFO_OFF : Int32 = 8

///|
pub const RELA_ADDEND_OFF : Int32 = 16

///|
pub const DYN_SIZE : Int32 = 16

///|
pub const DYN_TAG_OFF : Int32 = 0

///|
pub const DYN_VAL_OFF : Int32 = 8

///|
pub const PHDR_SIZE : Int32 = 56

///|
pub const PHDR_TYPE_OFF : Int32 = 0

///|
pub const PHDR_FLAGS_OFF : Int32 = 4

///|
pub const PHDR_OFFSET_OFF : Int32 = 8

///|
pub const PHDR_VADDR_OFF : Int32 = 16

///|
pub const PHDR_PADDR_OFF : Int32 = 24

///|
pub const PHDR_FILESZ_OFF : Int32 = 32

///|
pub const PHDR_MEMSZ_OFF : Int32 = 40

///|
pub const PHDR_ALIGN_OFF : Int32 = 48

///|
pub const VERNEED_SIZE : Int32 = 16

///|
pub const VERNEED_VERSION_OFF : Int32 = 0

///|
pub const VERNEED_CNT_OFF : Int32 = 2

///|
pub const VERNEED_FILE_OFF : Int32 = 4

///|
pub const VERNEED_AUX_OFF : Int32 = 8

///|
pub const VERNEED_NEXT_OFF : Int32 = 12

///|
pub const VERNAUX_SIZE : Int32 = 16

///|
pub const VERNAUX_HASH_OFF : Int32 = 0

///|
pub const VERNAUX_OTHER_OFF : Int32 = 6

///|
pub const VERNAUX_NAME_OFF : Int32 = 8

///|
pub const VERNAUX_NEXT_OFF : Int32 = 12

///|
pub const DEFAULT_PAGE_SIZE : Int32 = 4096

///|
pub const EHDR_ENTRY_SIZE : Int32 = 16

///|
pub const STB_SHIFT : Int32 = 4
