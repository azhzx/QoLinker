# Minimal x86-64 Linux program: write "hi\n" then exit(0), no libc.
  .text
  .globl _start
_start:
  mov $1, %rax          # sys_write
  mov $1, %rdi          # stdout
  lea msg(%rip), %rsi
  mov $msgend - msg, %rdx
  syscall
  mov $60, %rax         # sys_exit
  xor %rdi, %rdi
  syscall
  .section .rodata
msg:
  .ascii "hi\n"
msgend:
