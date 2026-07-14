module lsp;

import std::core::mem;

fn void test_module_covers() @test {
	assert(module_covers("std::io", "std::io"), "exact match");
	assert(module_covers("std::io", "std::io::path"), "submodule");
	assert(!module_covers("std::io", "std::iox"), "must be segment-aligned");
	assert(!module_covers("std::io::path", "std::io"), "parent is not covered by child");
	assert(!module_covers("", "std::io"), "empty prefix covers nothing");
}

fn void test_module_ctx_build_and_can_see() @test {
	String content = "module myapp::core;\nimport std::io, other::geom;\nimport foo;\nfn void t() {}";
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	ModuleCtx ctx;
	ctx.build(&stream.tokens);
	assert(ctx.own_count == 1, "own_count: %d", ctx.own_count);
	assert(ctx.own[0] == "myapp::core", "own: %s", ctx.own[0]);
	assert(ctx.import_count == 3, "import_count: %d", ctx.import_count);

	assert(ctx.can_see("myapp::core"), "same module");
	assert(ctx.can_see("myapp"), "parent module");
	assert(ctx.can_see("myapp::core::sub"), "submodule");
	assert(ctx.can_see("std::io::path"), "recursive import: std::io covers std::io::path");
	assert(ctx.can_see("other::geom"), "comma-separated import");
	assert(ctx.can_see("foo"), "second import statement");
	assert(ctx.can_see("std::core::mem"), "std::core is implicitly imported");
	assert(ctx.can_see(""), "module-less declarations are always visible");
	assert(!ctx.can_see("std::math"), "not imported");
	assert(!ctx.can_see("unrelated"), "unrelated module");
}

fn void test_module_ctx_no_module_info_is_permissive() @test {
	String content = "struct Foo { int x; }\nfn void t() {}";
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	ModuleCtx ctx;
	ctx.build(&stream.tokens);
	assert(ctx.can_see("anything::at::all"), "snippet files without module info see everything");
}

fn void test_module_ctx_attribute_ends_paths() @test {
	String content = "module myapp @private;\nimport foo @public;\nfn void t() {}";
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	ModuleCtx ctx;
	ctx.build(&stream.tokens);
	assert(ctx.own_count == 1 && ctx.own[0] == "myapp", "attribute must not extend module path, got: %s", ctx.own[0]);
	assert(ctx.import_count == 1 && ctx.imports[0] == "foo", "attribute must not extend import path, got: %s", ctx.imports[0]);
}
