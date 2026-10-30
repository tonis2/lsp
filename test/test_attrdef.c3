module lsp;

import std::core::dstring;
import std::core::mem;

// User-defined attributes (`attrdef @Component(name) = ...`, `attrmacro @Exposed`)
// navigate like any other symbol: `@Component` is an AT_TYPE_IDENT token.
const String ATTR_SRC = "module game;\n"
	+++ "<* Marks a struct as a component. *>\n"
	+++ "attrdef @Component(name) = @tag(\"component\", name);\n"
	+++ "attrmacro @Exposed(def, desc) = @tag(\"exposed\", def);\n"
	+++ "attrdef @Other;\n"
	+++ "struct Brain @Component(\"means.Brain\")\n"
	+++ "{\n"
	+++ "\tbool flag @Exposed(false, \"\");\n"
	+++ "\tint n @Other;\n"
	+++ "}\n"
	+++ "struct Body @Component(\"means.Body\") {}\n";

fn sz attr_offset(String s, String needle, int nth = 0) @private
{
	sz from = 0;
	for (int i = 0; ; i++)
	{
		sz at = from + s[from..].index_of(needle)!!;
		if (i == nth) return at;
		from = at + 1;
	}
}

fn int attr_count(String haystack, String needle) @private
{
	int count = 0;
	sz pos = 0;
	while (pos < haystack.len)
	{
		sz? found = haystack[pos..].index_of(needle);
		if (catch found) break;
		count++;
		pos += found + 1;
	}
	return count;
}

fn void test_attr_definition_from_struct_and_field() @test {
	// `@Component` on the struct, then on the field's `@Exposed`.
	String r = def_at(ATTR_SRC, "@Component(\"means.Brain", 3);
	assert(starts_at(r, 2, 8), "struct attribute, got: %s", r);
	r = def_at(ATTR_SRC, "@Exposed(false", 2);
	assert(starts_at(r, 3, 10), "attrmacro field attribute, got: %s", r);
	r = def_at(ATTR_SRC, "@Other;", 0, 1);
	assert(starts_at(r, 4, 8), "parameterless attribute, got: %s", r);
}

fn void test_attr_definition_cursor_after_name() @test {
	// On the `(` right after the name, as editors often place the cursor.
	String r = def_at(ATTR_SRC, "(\"means.Body");
	assert(starts_at(r, 2, 8), "got: %s", r);
}

// The parameters of an attribute declaration are its locals: `name` in
// `@tag("component", name)` is the `(name)` of `@Component`.
fn void test_attr_parameter_definition() @test {
	String r = def_at(ATTR_SRC, "name);");
	assert(starts_at(r, 2, 19), "attrdef parameter, got: %s", r);
	r = def_at(ATTR_SRC, "def);");
	assert(starts_at(r, 3, 19), "attrmacro parameter, got: %s", r);
	// A parameter used twice, and declared after another one.
	String src = "attrdef @Pair(a, b) = @tag(\"x\", b), @tag(\"y\", a);\nfn void f(int b) { b = 1; }";
	assert(starts_at(def_at(src, "b), @tag"), 0, 17), "got: %s", def_at(src, "b), @tag"));
	assert(starts_at(def_at(src, "a);"), 0, 14), "got: %s", def_at(src, "a);"));
	// The function's own `b` is not the attribute's.
	assert(starts_at(def_at(src, "b = 1"), 1, 14), "got: %s", def_at(src, "b = 1"));
}

fn void test_attr_parameter_references_and_rename() @test {
	String src = "attrdef @Pair(a, b) = @tag(\"x\", b), @tag(\"y\", a);\nfn void f(int b) { b = 1; }";
	DString out = dstring::temp();
	encode_document_highlights(src, attr_offset(src, "b)"), &out);
	assert(attr_count(out.str_view(), `"range"`) == 2, "got: %s", out.str_view());
	assert(starts_at(out.str_view(), 0, 17) && starts_at(out.str_view(), 0, 32), "got: %s", out.str_view());

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	out.clear();
	encode_rename("file:///p/a.c3", src, attr_offset(src, "b)"), ds, "", "second", &out);
	assert(attr_count(out.str_view(), `"newText":"second"`) == 2, "got: %s", out.str_view());
}

fn void test_attr_definition_across_files() @test {
	String lib = "module game::attrs;\nattrdef @Component(name) = @tag(\"component\", name);\n";
	String app = "module game;\nimport game::attrs;\nstruct Brain @Component(\"x\") {}\n";
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///p/attrs.c3", lib, 1);
	defer ds.close("file:///p/attrs.c3");

	DString out = dstring::temp();
	encode_definition("file:///p/app.c3", app, attr_offset(app, "@Component") + 2, ds, "", &out);
	String r = out.str_view();
	assert(r.contains("attrs.c3"), "got: %s", r);
	assert(starts_at(r, 1, 8), "got: %s", r);
}

fn void test_attr_references_and_highlights() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_references("file:///p/a.c3", ATTR_SRC, attr_offset(ATTR_SRC, "@Component", 1), ds, "", true, &out);
	String r = out.str_view();
	// The declaration plus the two uses; `@Exposed`/`@Other` stay out.
	assert(attr_count(r, `"range"`) == 3, "got: %s", r);
	assert(starts_at(r, 2, 8) && starts_at(r, 5, 13) && starts_at(r, 10, 12), "got: %s", r);

	out.clear();
	encode_document_highlights(ATTR_SRC, attr_offset(ATTR_SRC, "@Component") + 1, &out);
	assert(attr_count(out.str_view(), `"range"`) == 3, "got: %s", out.str_view());
}

fn void test_attr_rename() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_rename("file:///p/a.c3", ATTR_SRC, attr_offset(ATTR_SRC, "@Component", 2), ds, "", "@Part", &out);
	String r = out.str_view();
	assert(attr_count(r, `"newText":"@Part"`) == 3, "got: %s", r);
}

fn void test_attr_hover_shows_declaration_and_docs() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_hover("file:///p/a.c3", ATTR_SRC, attr_offset(ATTR_SRC, "@Component", 1) + 1, ds, "", &out);
	String r = out.str_view();
	assert(r.contains("attrdef @Component(name)"), "got: %s", r);
	assert(r.contains("Marks a struct as a component."), "got: %s", r);

	out.clear();
	encode_hover("file:///p/a.c3", ATTR_SRC, attr_offset(ATTR_SRC, "@Exposed", 1) + 1, ds, "", &out);
	assert(out.str_view().contains("attrmacro @Exposed(def, desc)"), "got: %s", out.str_view());
}

fn void test_attr_semantic_tokens_are_decorators() @test {
	SemTok decl = sem_token(ATTR_SRC, "@Component");
	assert(decl.type == SemanticCategory.DECORATOR.index, "declaration type %d", decl.type);
	assert(decl.mods & MOD_DECLARATION, "declaration modifier missing: %d", decl.mods);
	SemTok use = sem_token(ATTR_SRC, "@Component", 1);
	assert(use.type == SemanticCategory.DECORATOR.index, "use type %d", use.type);
	assert(!(use.mods & MOD_DECLARATION), "use is no declaration: %d", use.mods);
}

fn void test_attr_parameters_are_parameters() @test {
	SemTok decl = sem_token(ATTR_SRC, "name");
	assert(decl.type == SemanticCategory.PARAMETER.index && (decl.mods & MOD_DECLARATION), "decl %d/%d", decl.type, decl.mods);
	SemTok use = sem_token(ATTR_SRC, "name", 1);
	assert(use.type == SemanticCategory.PARAMETER.index && !(use.mods & MOD_DECLARATION), "use %d/%d", use.type, use.mods);
}

fn void test_attr_document_symbols() @test {
	DString out = dstring::temp();
	encode_document_symbols(ATTR_SRC, &out);
	String r = out.str_view();
	assert(r.contains(`"name":"@Component"`), "got: %s", r);
	assert(r.contains(`"name":"@Exposed"`), "got: %s", r);
}

fn void test_attr_completion_after_at() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = ATTR_SRC +++ "struct Legs @Co";
	DString out = dstring::temp();
	encode_completions("", content, content.len, ds, "", &out);
	String r = out.str_view();
	assert(r.contains(`"label":"@Component"`), "got: %s", r);

	// Not offered as a plain identifier.
	String plain = ATTR_SRC +++ "fn void f() { Co";
	out.clear();
	encode_completions("", plain, plain.len, ds, "", &out);
	assert(!out.str_view().contains(`"label":"@Component"`), "got: %s", out.str_view());
}
