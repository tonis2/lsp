module lsp;

import std::core::dstring;
import std::core::mem;

// Go-to-definition tests for the type inference in src/analysis/type_infer.c3: scope,
// `foreach` bindings, indexing, anonymous unions, aliases of builtin vectors, and
// struct initializers. Each snippet is self-contained — with no project.json above
// "file:///test.c3" the search never leaves the file — so a hit proves the inference,
// not the file scan.

// Offset of `sub` within the first occurrence of `needle`. Hand-counted offsets go
// stale the moment a snippet is edited; this keeps the cursor pinned to the text.
fn sz ti_offset(String content, String needle, String sub) @private
{
	sz? at = content.index_of(needle);
	if (catch at) unreachable("needle not in content: %s", needle);
	sz? rel = needle.index_of(sub);
	if (catch rel) unreachable("sub not in needle: %s", sub);
	return at + rel;
}

fn String ti_define(String content, sz offset) @private
{
	DString out      = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	encode_definition("file:///test.c3", content, offset, ds, "", &out);
	return out.str_view();
}

// Assert the definition found for the cursor is on `line` (0-based).
fn void ti_expect_line(String content, String needle, String sub, sz line) @private
{
	String result = ti_define(content, ti_offset(content, needle, sub));
	DString want  = dstring::temp();
	want.appendf(`"line":%d`, line);
	assert(result.contains(want.str_view()), "expected %s, got: %s", want.str_view(), result);
}

fn void ti_expect_none(String content, String needle, String sub) @private
{
	String result = ti_define(content, ti_offset(content, needle, sub));
	assert(result.len == 0, "expected no definition, got: %s", result);
}

fn void test_infer_local_beats_same_name_in_earlier_function() @test
{
	// Without scoping the file-wide scan finds `Alpha* src` first and every member
	// access on the parameter resolves against the wrong struct.
	String content = "module p;\n"                    // 0
		"struct Alpha { int ax; }\n"                  // 1
		"struct Beta { int bx; }\n"                   // 2
		"fn void one() { Alpha* src = null; }\n"      // 3
		"fn void two(Beta* src) { src.bx; }\n";       // 4
	ti_expect_line(content, "src.bx", "bx", 2);
}

fn void test_infer_nearest_declaration_wins() @test
{
	String content = "module p;\n"                    // 0
		"struct Alpha { int ax; }\n"                  // 1
		"struct Beta { int ax; }\n"                   // 2
		"fn void one()\n"                             // 3
		"{\n"                                         // 4
		"\tAlpha v;\n"                                // 5
		"\tBeta v2;\n"                                // 6
		"\tv2.ax;\n"                                  // 7
		"}\n";                                        // 8
	ti_expect_line(content, "v2.ax", "ax", 2);
}

fn void test_infer_foreach_ref_binding_method() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void Item.ping(&self) {}\n"                              // 2
		"struct Bag { List{Item} items; }\n"                         // 3
		"fn void go(Bag* b)\n"                                       // 4
		"{\n"                                                        // 5
		"\tforeach (&it : b.items) { it.ping(); }\n"                 // 6
		"}\n";                                                       // 7
	ti_expect_line(content, "it.ping()", "ping", 2);
}

fn void test_infer_foreach_indexed_binding_field() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"struct Bag { List{Item} items; }\n"                         // 2
		"fn void go(Bag* b)\n"                                       // 3
		"{\n"                                                        // 4
		"\tforeach (i, &it : b.items) { int v = it.value; }\n"       // 5
		"}\n";                                                       // 6
	ti_expect_line(content, "it.value", "value", 1);
}

fn void test_infer_foreach_over_slice_parameter() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void go(Item[] xs)\n"                                    // 2
		"{\n"                                                        // 3
		"\tforeach (x : xs) { int v = x.value; }\n"                  // 4
		"}\n";                                                       // 5
	ti_expect_line(content, "x.value", "value", 1);
}

fn void test_infer_foreach_explicit_element_type() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void go(Item[] xs)\n"                                    // 2
		"{\n"                                                        // 3
		"\tforeach (Item it : xs) { int v = it.value; }\n"           // 4
		"}\n";                                                       // 5
	ti_expect_line(content, "it.value", "value", 1);
}

fn void test_infer_foreach_alias_of_generic_list() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"alias ItemList = List{Item};\n"                             // 2
		"struct Bag { ItemList items; }\n"                           // 3
		"fn void go(Bag* b)\n"                                       // 4
		"{\n"                                                        // 5
		"\tforeach (&it : b.items) { int v = it.value; }\n"          // 6
		"}\n";                                                       // 7
	ti_expect_line(content, "it.value", "value", 1);
}

fn void test_infer_index_expression_element_field() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void go(Item[] xs) { int v = xs[0].value; }\n";          // 2
	ti_expect_line(content, "xs[0].value", "value", 1);
}

fn void test_infer_index_into_generic_container_field() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"struct Bag { List{Item} items; }\n"                         // 2
		"fn void go(Bag* b) { int v = b.items[0].value; }\n";        // 3
	ti_expect_line(content, "b.items[0].value", "value", 1);
}

fn void test_infer_anonymous_union_member() @test
{
	// C3 inlines an anonymous union into its parent, so `m` is a member of Mat.
	String content = "module p;\n"                                   // 0
		"struct Mat\n"                                               // 1
		"{\n"                                                        // 2
		"\tunion\n"                                                  // 3
		"\t{\n"                                                      // 4
		"\t\tstruct { float a, b; }\n"                               // 5
		"\t\tfloat[4] m;\n"                                          // 6
		"\t}\n"                                                      // 7
		"}\n"                                                        // 8
		"fn void go(Mat mm) { float f = mm.m[0]; }\n";               // 9
	ti_expect_line(content, "mm.m[0]", "m[0]", 6);
}

fn void test_infer_anonymous_struct_member() @test
{
	String content = "module p;\n"                                   // 0
		"struct Mat\n"                                               // 1
		"{\n"                                                        // 2
		"\tunion\n"                                                  // 3
		"\t{\n"                                                      // 4
		"\t\tstruct { float a, b; }\n"                               // 5
		"\t\tfloat[4] m;\n"                                          // 6
		"\t}\n"                                                      // 7
		"}\n"                                                        // 8
		"fn void go(Mat mm) { float f = mm.a; }\n";                  // 9
	ti_expect_line(content, "mm.a", "a", 5);
}

fn void test_infer_named_nested_struct_is_not_inlined() @test
{
	// A *named* nested struct declares a member of its own; its fields are not the
	// outer type's, so `outer.inner_field` must not resolve.
	String content = "module p;\n"                                   // 0
		"struct Outer\n"                                             // 1
		"{\n"                                                        // 2
		"\tstruct Inner { int hidden; }\n"                           // 3
		"\tint shown;\n"                                             // 4
		"}\n"                                                        // 5
		"fn void go(Outer o) { int v = o.hidden; }\n";               // 6
	ti_expect_none(content, "o.hidden", "hidden");
}

fn void test_infer_alias_of_builtin_vector_method() @test
{
	// `Vec3` and friends are aliases of `float[<3>]`, and the members every float
	// vector has are declared on the wildcard receiver `float[<*>]`.
	String content = "module p;\n"                                   // 0
		"alias Vec3 @weak = float[<3>];\n"                             // 1
		"macro float float[<*>].mag(float[<*>] x) => x;\n"           // 2
		"fn void go(Vec3 v) { float f = v.mag(); }\n";                 // 3
	ti_expect_line(content, "v.mag()", "mag", 2);
}

fn void test_infer_scalar_does_not_match_vector_method() @test
{
	// A plain `float` receiver must not reach a method declared on `float[<*>]`.
	String content = "module p;\n"                                   // 0
		"macro float float[<*>].mag(float[<*>] x) => x;\n"           // 1
		"fn void go(float v) { float f = v.mag(); }\n";              // 2
	ti_expect_none(content, "v.mag()", "mag");
}

fn void test_infer_alias_through_attribute_to_struct() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"alias Thing @weak = Item;\n"                                // 2
		"fn void go(Thing t) { int v = t.value; }\n";                // 3
	ti_expect_line(content, "t.value", "value", 1);
}

fn void test_infer_initializer_designator() @test
{
	String content = "module p;\n"                                   // 0
		"struct Conf { int width; }\n"                               // 1
		"fn void go() { Conf c = { .width = 4 }; }\n";               // 2
	ti_expect_line(content, ".width = 4", "width", 1);
}

fn void test_infer_initializer_designator_after_comma() @test
{
	String content = "module p;\n"                                   // 0
		"struct Conf { int width; int height; }\n"                   // 1
		"fn void go() { Conf c = { .width = 4, .height = 8 }; }\n";  // 2
	ti_expect_line(content, ".height = 8", "height", 1);
}

fn void test_infer_initializer_designator_in_call_argument() @test
{
	// `Elem` is the module's generic parameter, so the parameter type is whatever
	// the receiver was instantiated with — here `Thing`.
	String content = "module cont <Elem>;\n"                         // 0
		"struct Thing { int value; }\n"                              // 1
		"struct Box { int n; }\n"                                    // 2
		"fn void Box.put(&self, Elem v) {}\n"                        // 3
		"fn void go(Box{Thing}* b) { b.put({ .value = 1 }); }\n";    // 4
	ti_expect_line(content, ".value = 1", "value", 1);
}

fn void test_infer_initializer_designator_in_later_call_argument() @test
{
	String content = "module p;\n"                                   // 0
		"struct Conf { int width; }\n"                               // 1
		"fn void take(int a, Conf c) {}\n"                           // 2
		"fn void go() { take(1, { .width = 4 }); }\n";               // 3
	ti_expect_line(content, ".width = 4", "width", 1);
}

fn void test_infer_designator_is_not_a_member_of_the_previous_token() @test
{
	// `{ .name` used to resolve as a member of whatever preceded the brace; a
	// designator names a field of the type being initialized and nothing else.
	String content = "module p;\n"                                   // 0
		"struct Conf { int width; }\n"                               // 1
		"fn void go() { int width = 0; take(1, { .width = 4 }); }\n";// 2
	ti_expect_none(content, ".width = 4", "width");
}

fn void test_infer_chained_call_return_type() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"struct Bag { int n; }\n"                                    // 2
		"fn Item Bag.first(&self) { Item i; return i; }\n"           // 3
		"fn void go(Bag* b) { int v = b.first().value; }\n";         // 4
	ti_expect_line(content, "b.first().value", "value", 1);
}

fn void test_infer_parenthesised_expression_keeps_its_type() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void go(Item it) { int v = (it).value; }\n";             // 2
	ti_expect_line(content, "(it).value", "value", 1);
}

fn void test_infer_cast_names_the_type() @test
{
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"fn void go(void* raw) { int v = ((Item*)raw).value; }\n";   // 2
	ti_expect_line(content, "raw).value", "value", 1);
}

fn void test_infer_typed_constant_receiver() @test
{
	String content = "module p;\n"                                   // 0
		"struct Conf { int width; }\n"                               // 1
		"const Conf DEFAULTS = { .width = 1 };\n"                    // 2
		"fn void go() { int v = DEFAULTS.width; }\n";                // 3
	ti_expect_line(content, "DEFAULTS.width", "width", 1);
}

fn void test_infer_control_flow_header_is_not_a_cast() @test
{
	// `)` before an identifier also ends an `if`/`foreach` header; only a group
	// holding exactly a type is a cast.
	String content = "module p;\n"                                   // 0
		"struct Item { int value; }\n"                               // 1
		"struct Other { int value; }\n"                              // 2
		"fn void go(Other o, bool c) { if (c) { int v = o.value; } }\n"; // 3
	ti_expect_line(content, "o.value", "value", 2);
}

fn void test_infer_generic_container_field_is_substituted() @test
{
	// `Type* entries` inside a generic module is not a type of its own — indexing it
	// through a `Bag{Item}` receiver yields an Item.
	String content = "module cont <Type>;\n"                             // 0
		"struct Item { int value; }\n"                                   // 1
		"struct Bag { Type* entries; sz size; }\n"                       // 2
		"fn void go(Bag{Item}* b) { int v = b.entries[0].value; }\n";    // 3
	ti_expect_line(content, "b.entries[0].value", "value", 1);
}

fn void test_infer_generic_container_through_alias() @test
{
	String content = "module cont <Type>;\n"                             // 0
		"struct Item { int value; }\n"                                   // 1
		"struct Bag { Type* entries; }\n"                                // 2
		"alias ItemBag = Bag{Item};\n"                                   // 3
		"fn void go(ItemBag* b) { int v = b.entries[0].value; }\n";      // 4
	ti_expect_line(content, "b.entries[0].value", "value", 1);
}
