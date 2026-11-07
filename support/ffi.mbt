// Native FFI surface over `posix.c`. Private externs; public wrappers live in
// `io.mbt`. All handles are checked in MoonBit before use.

///|
#borrow(path)
extern "c" fn qo_read_file(path : Bytes) -> Bytes? = "qo_read_file"

///|
#borrow(path)
extern "c" fn qo_create_rw(path : Bytes) -> Int32 = "qo_create_rw"

///|
extern "c" fn qo_close(fd : Int32) -> Int32 = "qo_close"

///|
extern "c" fn qo_ftruncate(fd : Int32, size : Int64) -> Int32 = "qo_ftruncate"

///|
#borrow(buf)
extern "c" fn qo_pwrite(fd : Int32, offset : Int64, buf : Bytes) -> Int64 = "qo_pwrite"

///|
extern "c" fn qo_fchmod(fd : Int32, mode : Int32) -> Int32 = "qo_fchmod"

///|
#borrow(buf)
extern "c" fn qo_eprint(buf : Bytes) -> Unit = "qo_eprint"

///|
extern "c" fn qo_exit(code : Int32) -> Unit = "qo_exit"
