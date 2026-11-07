# Calls shared_func (defined in lib.s), reads shared_data, writes via common.
  .text
  .globl _start
_start:
  call shared_func        # PLT32 cross-object
  mov shared_data(%rip), %rax   # PC32-ish data ref
  add common_var(%rip), %rax    # reference to a COMMON symbol
  mov $60, %rax
  xor %rdi, %rdi
  syscall
  .section .rodata
str:
  .ascii "multi\n"
