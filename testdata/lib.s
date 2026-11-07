  .text
  .globl shared_func
shared_func:
  ret
  .data
  .globl shared_data
shared_data:
  .quad 42
  # common symbol
  .comm common_var, 8, 8
