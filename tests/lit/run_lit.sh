#!/bin/sh
# Runs lld's official lit test suite against QoLinker.
#
# Setup: symlinks ld.lld/ld64.lld/lld-link/wasm-ld to the QoLinker binary and
# drops a fake llvm-config (features: x86, asserts) into tests/lit/bin, then
# loads lld's own lit.cfg.py with our lit.site.cfg.py.
#
# Usage: sh tests/lit/run_lit.sh [lit args...]
#   e.g. sh tests/lit/run_lit.sh ELF/basic.s ELF/entry.s
#        sh tests/lit/run_lit.sh --filter basic
set -e
cd "$(dirname "$0")/../.."

LLD_TEST_DIR="${QO_LLD_TEST_DIR:-/tmp/qolinker-investigation/llvm-project/lld/test}"
LLVM_TOOLS_DIR="${QO_LLVM_TOOLS_DIR:-$HOME/.homebrew/opt/llvm@21/bin}"

QO="_build/native/release/build/cmd/main/main.exe"
if [ ! -x "$QO" ]; then
  echo "building qolink (release)..."
  moon build --target native --release cmd/main >/dev/null
fi

# Prepare the tool directory lit will search first (config.lld_tools_dir).
BIN=tests/lit/bin
mkdir -p "$BIN"
for t in ld.lld ld64.lld lld-link wasm-ld; do
  ln -sf "$(pwd)/$QO" "$BIN/$t"
done
cat > "$BIN/llvm-config" <<'EOF'
#!/bin/sh
case "$1" in
  --targets-built) echo "X86" ;;
  --assertion-mode) echo "ON" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$BIN/llvm-config"

# Our site config (which loads lld's own lit.cfg.py at the end) takes
# precedence over lld's bare lit.cfg.py in discovery.
OBJ=tests/lit/obj
mkdir -p "$OBJ" /tmp/qolinker-lit-obj
python3 -c "
import os
data = open('tests/lit/lit.cfg.py').read()
data = data.replace('@@REPO@@', '$(pwd)').replace('@@LLD_TEST_DIR@@', '$LLD_TEST_DIR').replace('@@LLVM_TOOLS@@', '$LLVM_TOOLS_DIR')
open('$LLD_TEST_DIR/lit.site.cfg.py', 'w').write(data)
"

exec "$HOME/miniconda3/bin/lit" "$@" "$LLD_TEST_DIR/ELF"
