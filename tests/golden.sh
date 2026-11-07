#!/bin/sh
# Golden regression: link each testdata fixture with ld.lld and QoLinker,
# then compare program headers, section layout and symbol tables.
#
# Known-benign differences that are normalized away:
#  - .comment: each linker records its own version string (different length),
#    so the .comment row and the file offsets of the non-alloc tail sections
#    shift. Alloc-section layout, program headers and symbol tables are
#    compared strictly.
# Usage: sh tests/golden.sh
set -e
cd "$(dirname "$0")/.."
QO="_build/native/debug/build/cmd/main/main.exe"
FX=/tmp/qolinker-golden
mkdir -p "$FX"

if [ ! -x "$QO" ]; then
  echo "building qolink..."
  moon build --target native cmd/main >/dev/null
fi

mc() {
  llvm-mc -filetype=obj -triple=x86_64-unknown-linux -o "$1" "$2"
}

mc "$FX/hello.o" testdata/hello.s
mc "$FX/main.o" testdata/main.s
mc "$FX/lib.o" testdata/lib.s
rm -f "$FX/libhello.a"
llvm-ar --format=gnu rcs "$FX/libhello.a" "$FX/lib.o"
mc "$FX/dead.o" testdata/gc.s

compare() {
  name="$1"; shift
  ld.lld -o "$FX/lld_$name" "$@" >/dev/null
  "$QO" -o "$FX/qo_$name" "$@" >/dev/null

  llvm-readelf -l "$FX/lld_$name" > "$FX/lld_$name-l.txt" 2>/dev/null
  llvm-readelf -l "$FX/qo_$name" > "$FX/qo_$name-l.txt" 2>/dev/null

  norm_s() {
    grep -v '\.comment ' | awk '
      /starting at offset/ { sub(/starting at offset .*/, "starting at offset X"); print; next }
      (/\.symtab/ || /\.shstrtab/ || /\.strtab/) {
        sub(/ [0-9a-f]+ [0-9a-f]+ /, " OFF SIZE "); print; next
      }
      { print }
    '
  }
  llvm-readelf -S "$FX/lld_$name" 2>/dev/null | norm_s > "$FX/lld_$name-S.txt"
  llvm-readelf -S "$FX/qo_$name" 2>/dev/null | norm_s > "$FX/qo_$name-S.txt"

  llvm-readelf -s "$FX/lld_$name" 2>/dev/null | awk '{print $2,$3,$4,$5,$6,$7,$8}' | tail -n +4 > "$FX/lld_$name.sym.txt"
  llvm-readelf -s "$FX/qo_$name" 2>/dev/null | awk '{print $2,$3,$4,$5,$6,$7,$8}' | tail -n +4 > "$FX/qo_$name.sym.txt"

  for view in -l -S; do
    if diff -q "$FX/lld_$name$view.txt" "$FX/qo_$name$view.txt" >/dev/null; then
      echo "PASS  $name $view (identical)"
    else
      echo "DIFF  $name $view"
      diff "$FX/lld_$name$view.txt" "$FX/qo_$name$view.txt" | head -8
    fi
  done
  if diff -q "$FX/lld_$name.sym.txt" "$FX/qo_$name.sym.txt" >/dev/null; then
    echo "PASS  $name symtab (identical)"
  else
    echo "DIFF  $name symtab"
    diff "$FX/lld_$name.sym.txt" "$FX/qo_$name.sym.txt" | head -8
  fi
}

compare hello "$FX/hello.o"
compare multi "$FX/main.o" "$FX/lib.o"
compare archive "$FX/main.o" "$FX/libhello.a"
compare gc --gc-sections "$FX/dead.o"

echo "done."
