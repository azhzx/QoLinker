// Black-box tests for the lld-faithful symbol resolution rules.

///|
fn test_ctx() -> Ctx {
  let diag = @support.Diag::new()
  let cfg = {
    output: b"/dev/null",
    entry: b"_start",
    entry_given: false,
    inputs: [],
    shared: false,
    pie: false,
    gc_sections: false,
    image_base: 0x200000L,
    page_size: 4096L,
    library_paths: [],
    map_file: None,
    script: None,
    version_script: None,
    build_id: false,
    export_dynamic: false,
    whole_archive: false,
    as_needed: true,
    search_static: false,
    z_separate_code: false,
    defsyms: [],
    print_gc_sections: false,
  }
  Ctx::new(cfg, diag)
}

///|
fn new_sym(ctx : Ctx, name~ : String, binding~ : Int32) -> NewSym {
  let _ = ctx
  {
    name: @utf8.encode(name),
    file: InternalRef,
    binding,
    stype: @elfspec.STT_NOTYPE,
    visibility: @elfspec.STV_DEFAULT,
    section: None,
    value: 0L,
    size: 0L,
    alignment: 1L,
    archive: None,
    member_index: -1,
    version: b"",
  }
}

///|
test "strong defined beats weak defined and common" {
  let ctx = test_ctx()
  let s = ctx.symtab.insert(b"foo")
  // weak defined first
  let weak = new_sym(ctx, name="foo", binding=@elfspec.STB_WEAK)
  ignore(ctx.symtab.add_defined_symbol(weak))
  assert_true(s.sym.is_defined())
  assert_eq(s.sym.binding, @elfspec.STB_WEAK)
  // strong defined overrides
  let strong = new_sym(ctx, name="foo", binding=@elfspec.STB_GLOBAL)
  ignore(ctx.symtab.add_defined_symbol(strong))
  assert_eq(s.sym.binding, @elfspec.STB_GLOBAL)
  // common does NOT override a strong definition
  let common = {
    ..new_sym(ctx, name="foo", binding=@elfspec.STB_GLOBAL),
    size: 16L,
  }
  ignore(ctx.symtab.add_common_symbol(common))
  assert_true(s.sym.is_defined())
}

///|
test "common symbols merge to max size and alignment" {
  let ctx = test_ctx()
  let s = ctx.symtab.insert(b"bar")
  ignore(
    ctx.symtab.add_common_symbol({
      ..new_sym(ctx, name="bar", binding=@elfspec.STB_GLOBAL),
      size: 8L,
      alignment: 4L,
    }),
  )
  ignore(
    ctx.symtab.add_common_symbol({
      ..new_sym(ctx, name="bar", binding=@elfspec.STB_GLOBAL),
      size: 32L,
      alignment: 16L,
    }),
  )
  match s.sym.kind {
    Common(c) => {
      assert_eq(c.size, 32L)
      assert_eq(c.alignment, 16L)
    }
    _ => fail("expected common")
  }
}

///|
test "duplicate strong symbols are reported once" {
  let ctx = test_ctx()
  ignore(
    ctx.symtab.add_defined_symbol(
      new_sym(ctx, name="dup", binding=@elfspec.STB_GLOBAL),
    ),
  )
  ignore(
    ctx.symtab.add_defined_symbol(
      new_sym(ctx, name="dup", binding=@elfspec.STB_GLOBAL),
    ),
  )
  assert_eq(ctx.diag.errors, 1)
  // Weak + strong pair is not an error.
  let ctx2 = test_ctx()
  ignore(
    ctx2.symtab.add_defined_symbol(
      new_sym(ctx2, name="dup2", binding=@elfspec.STB_WEAK),
    ),
  )
  ignore(
    ctx2.symtab.add_defined_symbol(
      new_sym(ctx2, name="dup2", binding=@elfspec.STB_GLOBAL),
    ),
  )
  assert_eq(ctx2.diag.errors, 0)
}

///|
test "lazy loses to defined without extraction" {
  let ctx = test_ctx()
  let s = ctx.symtab.insert(b"zed")
  // A defined symbol wins over a later lazy archive symbol.
  ignore(
    ctx.symtab.add_defined_symbol(
      new_sym(ctx, name="zed", binding=@elfspec.STB_GLOBAL),
    ),
  )
  ignore(
    ctx.symtab.add_lazy_symbol({
      ..new_sym(ctx, name="zed", binding=@elfspec.STB_GLOBAL),
      member_index: 3,
    }),
  )
  assert_true(s.sym.is_defined())
}

///|
test "undefined-first-reference binding sticks" {
  let ctx = test_ctx()
  let s = ctx.symtab.insert(b"uref")
  // First reference is weak.
  ignore(
    ctx.symtab.add_undefined_symbol(
      new_sym(ctx, name="uref", binding=@elfspec.STB_WEAK),
    ),
  )
  assert_eq(s.sym.binding, @elfspec.STB_WEAK)
  // A later strong reference upgrades the binding.
  ignore(
    ctx.symtab.add_undefined_symbol(
      new_sym(ctx, name="uref", binding=@elfspec.STB_GLOBAL),
    ),
  )
  assert_eq(s.sym.binding, @elfspec.STB_GLOBAL)
}
