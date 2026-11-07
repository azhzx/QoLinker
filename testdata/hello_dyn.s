# Dynamic hello: calls printf through the PLT, then libc exit (flushes stdio).
  .text
  .globl _start
_start:
  lea msg(%rip), %rsi
  lea fmt(%rip), %rdi
  xor %eax, %eax
  call printf
  xor %edi, %edi
  call exit
  .section .rodata
fmt:
  .asciz "hello %s\n"
msg:
  .asciz "dynamic"
