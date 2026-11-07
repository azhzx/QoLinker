# Dynamic hello: calls printf through the PLT, then exits via syscall.
  .text
  .globl _start
_start:
  lea msg(%rip), %rsi
  lea fmt(%rip), %rdi
  xor %eax, %eax
  call printf                # PLT32 -> PLT
  mov $60, %rax
  xor %rdi, %rdi
  syscall
  .section .rodata
fmt:
  .asciz "hello %s\n"
msg:
  .asciz "dynamic"
