# --gc-sections fixture: live code + dead code + cross references.
  .text
  .globl _start
_start:
  mov kept_data(%rip), %rax
  mov $60, %rax
  xor %rdi, %rdi
  syscall
  .globl kept_func
kept_func:
  ret
  .section .dead_code,"ax",@progbits
dead_func:
  mov dead_data(%rip), %rax
  ret
  .data
  .globl kept_data
kept_data:
  .quad 7
  .section .dead_data,"aw",@progbits
dead_data:
  .quad 8
