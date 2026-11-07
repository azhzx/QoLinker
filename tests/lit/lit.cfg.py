# lit.site.cfg.py for running lld's official test suite against QoLinker.
# Copied into the lld test directory by tests/lit/run_lit.sh; lit loads it
# before lld's own lit.cfg.py, which then resolves %ld.lld etc. from
# config.lld_tools_dir (our bin/ with ld.lld symlinked to the QoLinker
# binary).

import os
import platform
import sys

repo_root = "@@REPO@@"
lld_test_dir = "@@LLD_TEST_DIR@@"

config.llvm_src_root = os.path.dirname(lld_test_dir)
config.llvm_obj_root = config.llvm_src_root
config.llvm_tools_dir = "@@LLVM_TOOLS@@"
config.llvm_libs_dir = config.llvm_tools_dir
config.llvm_shlib_dir = config.llvm_tools_dir
config.llvm_shlib_ext = ".dylib" if platform.system() == "Darwin" else ".so"
config.lit_tools_dir = ""
config.enable_backtrace = False
config.lld_obj_root = os.environ.get("QO_LIT_OBJ_ROOT", "/tmp/qolinker-lit-obj")
config.lld_libs_dir = config.llvm_tools_dir
config.lld_tools_dir = os.path.join(repo_root, "tests", "lit", "bin")
config.host_triple = (
    "aarch64-apple-darwin" if platform.system() == "Darwin" else "x86_64-linux-gnu"
)
config.target_triple = "x86_64-unknown-linux-gnu"
config.python_executable = sys.executable
config.have_zlib = True
config.have_zstd = False
config.have_libxml2 = False
config.sizeof_void_p = 8
config.has_plugins = False
config.build_examples = False
config.linked_bye_extension = False
config.have_dia_sdk = False
config.enable_threads = True
config.ld_lld_default_mingw = False
config.ld_lld_default_posix = True

import lit.llvm

lit.llvm.initialize(lit_config, config)

# Load lld's own lit.cfg.py: it sets test_source_root to the lld test tree
# and registers all substitutions (use_lld resolves ld.lld from
# config.lld_tools_dir, i.e. our QoLinker symlink).
lit_config.load_config(config, os.path.join(lld_test_dir, "lit.cfg.py"))
