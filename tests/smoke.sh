#!/bin/bash
# Execution smoke tests: link fixtures and RUN the products (Linux only —
# the static fixtures use raw syscalls; the dynamic one needs glibc).
set -e
cd "$(dirname "$0")/.."
if [ "$(uname)" != "Linux" ]; then
  echo "SKIP: execution smoke requires a Linux host (CI runs this)."
  exit 0
fi
QO="_build/native/release/build/cmd/main/main.exe"
FX=/tmp/qolinker-smoke
rm -rf "$FX" && mkdir -p "$FX"

llvm-mc -filetype=obj -triple=x86_64-unknown-linux -o "$FX/hello.o" testdata/hello.s
llvm-mc -filetype=obj -triple=x86_64-unknown-linux -o "$FX/main.o" testdata/main.s
llvm-mc -filetype=obj -triple=x86_64-unknown-linux -o "$FX/lib.o" testdata/lib.s
llvm-ar --format=gnu rcs "$FX/libhello.a" "$FX/lib.o"

"$QO" -o "$FX/hello" "$FX/hello.o"
out=$("$FX/hello"); code=$?
[ "$code" = 0 ] && [ "$out" = "hi" ] || { echo "FAIL hello: code=$code out=$out"; exit 1; }
echo "PASS run hello"

"$QO" -o "$FX/multi" "$FX/main.o" "$FX/lib.o"
"$FX/multi" && echo "PASS run multi"

"$QO" -o "$FX/fromarch" "$FX/main.o" "$FX/libhello.a"
"$FX/fromarch" && echo "PASS run archive member"

"$QO" --gc-sections -o "$FX/gc" "$FX/hello.o"
"$FX/gc" && echo "PASS run gc-sections"

LIBC=$(ldd /bin/true 2>/dev/null | grep libc.so.6 | awk '{print $3}' | head -1)
if [ -n "$LIBC" ]; then
  llvm-mc -filetype=obj -triple=x86_64-unknown-linux -o "$FX/hello_dyn.o" testdata/hello_dyn.s
  "$QO" -o "$FX/dyn" "$FX/hello_dyn.o" "$LIBC"
  # Diagnostics: does ld.so survive startup relocation processing?
  if LD_TRACE_LOADED_OBJECTS=1 "$FX/dyn" > "$FX/trace.txt" 2>&1; then
    echo "ld.so trace ok:"; head -3 "$FX/trace.txt"
  else
    echo "FAIL: ld.so crashed during startup (trace). LD_DEBUG tail:"
    LD_DEBUG=all "$FX/dyn" 2>&1 | tail -12 || true
    exit 1
  fi
  if LD_BIND_NOW=1 "$FX/dyn" > "$FX/dyn_now.txt" 2>&1; then
    echo "PASS run dynamic (BIND_NOW non-lazy)"
  else
    echo "FAIL dynamic BIND_NOW: exit $?"; exit 1
  fi
  out=$("$FX/dyn"); code=$?
  [ "$code" = 0 ] && [ "$out" = "hello dynamic" ] || { echo "FAIL dyn lazy: code=$code out=$out"; exit 1; }
  echo "PASS run dynamic (glibc via PLT, lazy binding)"
else
  echo "SKIP dynamic (no libc.so.6 found)"
fi
echo "smoke done."
