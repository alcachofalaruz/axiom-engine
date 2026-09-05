package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import ast "core:odin/ast"
import parser "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Meta_Fixed_Declaration :: struct {
	name:          string,
	storage:       string,
	fraction_bits: u32,
	rounding:      string,
	overflow:      string,
}

Meta_Vector_Declaration :: struct {
	name:   string,
	scalar: string,
	fields: []string,
}

Meta_Access_Type :: enum {
	R,
	RW,
}

Meta_Property :: struct {
	type:   string,
	name:   string,
	access: Meta_Access_Type,
}

Meta_Component_Declaration :: struct {
	name:       string,
	properties: []Meta_Property,
}

Meta_System_Declaration :: struct {
	name:   string,
	inputs: [dynamic]Meta_Property,
}

Meta_Schema :: struct {
	fixed:      [dynamic]Meta_Fixed_Declaration,
	vectors:    [dynamic]Meta_Vector_Declaration,
	components: [dynamic]Meta_Component_Declaration,
	Systems:    [dynamic]Meta_System_Declaration,

	// Names and finalized field/property slices live until schema_destroy.
	storage:    vmem.Arena,
	names:      strings.Intern,
}

Meta_Block_Kind :: enum {
	None,
	Fixed,
	Vector,
	Component,
}

Meta_File_Type :: enum {
	None,
	AxMeta,
	Cpp,
	Odin,
}

schema_init :: proc(
	schema: ^Meta_Schema,
	allocator := context.allocator,
) -> runtime.Allocator_Error {
	schema.storage.default_commit_size = 4 * mem.Kilobyte
	vmem.arena_init_growing(&schema.storage, 64 * mem.Kilobyte) or_return
	schema.names.allocator = vmem.arena_allocator(&schema.storage)
	schema.names.entries.allocator = allocator
	schema.fixed.allocator = allocator
	schema.vectors.allocator = allocator
	schema.components.allocator = allocator
	schema.Systems.allocator = allocator
	return nil
}

schema_destroy :: proc(schema: ^Meta_Schema) {
	for system in schema.Systems {
		delete(system.inputs)
	}
	delete(schema.Systems)
	delete(schema.components)
	delete(schema.vectors)
	delete(schema.fixed)
	delete(schema.names.entries)
	vmem.arena_destroy(&schema.storage)
	schema^ = {}
}

is_primitive_type :: proc(name: string) -> bool {
	switch name {
	case "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "string":
		return true
	}
	return false
}

has_attribute :: proc(decl: ^ast.Value_Decl, name: string) -> bool {
	for attribute in decl.attributes {
		for element in attribute.elems {
			if identifier, ok := element.derived.(^ast.Ident); ok && identifier.name == name {
				return true
			}
		}
	}

	return false
}

parse_odin_file :: proc(schema: ^Meta_Schema, path: string) -> bool {
	arena: vmem.Arena
	err := vmem.arena_init_growing(&arena)
	ensure(err == nil, "failed to allocatee odin parser arena")
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	context.temp_allocator = context.allocator

	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		fmt.eprintln("Could not read", path, read_error)
		return false
	}

	file := ast.File {
		fullpath = path,
		src      = string(bytes),
	}
	p := parser.default_parser()
	parsed := parser.parse_file(&p, &file)
	if !parsed || file.syntax_error_count != 0 || p.tok.error_count != 0 {
		return false
	}
	alloc_err: runtime.Allocator_Error
	for statement in file.decls {
		declaration, ok := statement.derived.(^ast.Value_Decl)
		if !ok || !has_attribute(declaration, "axiom_system") {
			continue
		}

		if len(declaration.names) != 1 || len(declaration.values) != 1 || declaration.is_mutable {
			fmt.eprintln("expeccted one named system procedure", path)
			return false
		}

		name, name_ok := declaration.names[0].derived.(^ast.Ident)
		literal, literal_ok := declaration.values[0].derived.(^ast.Proc_Lit)
		if !name_ok || !literal_ok || literal.body == nil || literal.type.generic {
			fmt.eprintln("Expected a non-generic system procedure with a body", path)
			return false
		}
		system_index := len(schema.Systems)
		_, alloc_err = append(&schema.Systems, Meta_System_Declaration{name = name.name})
		if alloc_err != nil {
			return false
		}
		system := &schema.Systems[system_index]
		fmt.println("system:", name.name)
		for field in literal.type.params.list {
			type_expression := field.type
			if type_expression == nil || field.default_value != nil || field.flags != {} {
				fmt.eprintln("explicitly typed parameters are expected", name.name)
				return false
			}

			access := Meta_Access_Type.R
			if pointer, ok := type_expression.derived.(^ast.Pointer_Type); ok {
				access = Meta_Access_Type.RW
				type_expression = pointer.elem
			}
			component, ok := type_expression.derived.(^ast.Ident)

			if !ok {
				fmt.eprintln("Only T or ^T is allowed for types")
				return false
			}
			input_index := len(system.inputs)
			// grouped names e.g name1, name2: ^Transform
			for parameter in field.names {
				identifier, ok := parameter.derived.(^ast.Ident)
				if !ok {
					return false
				}
				_, alloc_err = append(
					&system.inputs,
					Meta_Property{type = component.name, name = identifier.name, access = access},
				)
				if alloc_err != nil {
					return false
				}

			}
		}


	}


	return false
}

parse_meta_file :: proc(schema: ^Meta_Schema, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	defer delete(data)
	if err != nil {
		fmt.eprintfln("AxiomMetaGen: could not read {}: {}", path, err)
		return false
	}
	alloc_err: runtime.Allocator_Error
	defer if alloc_err != nil {
		fmt.eprintfln("AxiomMetaGen: allocation failed while parsing {}: {}", path, alloc_err)
	}

	// Reuse one buffer of each kind while parsing; only exact-size slices escape.
	fields: [dynamic]string
	properties: [dynamic]Meta_Property
	defer delete(fields)
	defer delete(properties)
	storage := vmem.arena_allocator(&schema.storage)

	block := Meta_Block_Kind.None
	fixed_index := -1
	vector_index := -1
	component_index := -1

	remaining_lines := string(data)
	line_number := -1
	for original_line in strings.split_lines_iterator(&remaining_lines) {
		line_number += 1
		line := strings.trim_space(original_line)
		if comment_index := strings.index(line, "//"); comment_index >= 0 {
			line = strings.trim_space(line[:comment_index])
		}
		if line == "" {
			continue
		}

		remaining_words := line
		keyword, _ := strings.fields_iterator(&remaining_words)
		if keyword == "fields" {
			field, has_field := strings.fields_iterator(&remaining_words)
			if block != .Vector || !has_field {
				fmt.eprintfln(
					"AxiomMetaGen: invalid fields declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			for has_field {
				field, alloc_err = strings.intern_get(&schema.names, field)
				if alloc_err != nil {
					return false
				}
				_, alloc_err = append(&fields, field)
				if alloc_err != nil {
					return false
				}
				field, has_field = strings.fields_iterator(&remaining_words)
			}
			continue
		}
		// Other declarations need at most two words; a third detects extra input.
		word_buffer := [3]string{keyword, "", ""}
		word_count := 1
		for word in strings.fields_iterator(&remaining_words) {
			word_buffer[word_count] = word
			word_count += 1
			if word_count == len(word_buffer) {
				break
			}
		}
		words := word_buffer[:word_count]
		if words[0] == "scalar" {
			if block != .Vector || len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: invalid scalar declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			schema.vectors[vector_index].scalar, alloc_err = strings.intern_get(
				&schema.names,
				words[1],
			)
			if alloc_err != nil {
				return false
			}
			continue
		}
		if words[0] == "storage" {
			if block != .Fixed || len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: invalid storage declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			schema.fixed[fixed_index].storage, alloc_err = strings.intern_get(
				&schema.names,
				words[1],
			)
			if alloc_err != nil {
				return false
			}
			continue
		}
		if words[0] == "fraction_bits" {
			if block != .Fixed || len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: invalid fraction_bits declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			value, value_ok := strconv.parse_u64(words[1])
			if !value_ok {
				fmt.eprintfln(
					"AxiomMetaGen: invalid fraction_bits value in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			schema.fixed[fixed_index].fraction_bits = u32(value)
			continue
		}
		if words[0] == "rounding" {
			if block != .Fixed || len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: invalid rounding declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			schema.fixed[fixed_index].rounding, alloc_err = strings.intern_get(
				&schema.names,
				words[1],
			)
			if alloc_err != nil {
				return false
			}
			continue
		}
		if words[0] == "overflow" {
			if block != .Fixed || len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: invalid overflow declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			schema.fixed[fixed_index].overflow, alloc_err = strings.intern_get(
				&schema.names,
				words[1],
			)
			if alloc_err != nil {
				return false
			}
			continue
		}
		if words[0] == "end" {
			if len(words) != 1 || block == .None {
				fmt.eprintfln("AxiomMetaGen: unexpected `end` in {}:{}", path, line_number + 1)
				return false
			}
			switch block {
			case .Vector:
				schema.vectors[vector_index].fields, alloc_err = make(
					[]string,
					len(fields),
					storage,
				)
				if alloc_err != nil {
					return false
				}
				copy(schema.vectors[vector_index].fields, fields[:])
			case .Component:
				schema.components[component_index].properties, alloc_err = make(
					[]Meta_Property,
					len(properties),
					storage,
				)
				if alloc_err != nil {
					return false
				}
				copy(schema.components[component_index].properties, properties[:])
			case .None, .Fixed:
			}
			block = .None
			fixed_index = -1
			vector_index = -1
			component_index = -1
			continue
		}
		if words[0] == "fixed" {
			if block != .None {
				fmt.eprintfln(
					"AxiomMetaGen: expected `end` before declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			if len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: expected `fixed <name>` in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			name: string
			name, alloc_err = strings.intern_get(&schema.names, words[1])
			if alloc_err != nil {
				return false
			}
			_, alloc_err = append(&schema.fixed, Meta_Fixed_Declaration{name = name})
			if alloc_err != nil {
				return false
			}
			fixed_index = len(schema.fixed) - 1
			block = .Fixed
			continue
		}
		if words[0] == "vector" {
			if block != .None {
				fmt.eprintfln(
					"AxiomMetaGen: expected `end` before declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			if len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: expected `vector <name>` in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			name: string
			name, alloc_err = strings.intern_get(&schema.names, words[1])
			if alloc_err != nil {
				return false
			}
			_, alloc_err = append(&schema.vectors, Meta_Vector_Declaration{name = name})
			if alloc_err != nil {
				return false
			}
			clear(&fields)
			vector_index = len(schema.vectors) - 1
			block = .Vector
			continue
		}
		if words[0] == "component" {
			if block != .None {
				fmt.eprintfln(
					"AxiomMetaGen: expected `end` before declaration in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			if len(words) != 2 {
				fmt.eprintfln(
					"AxiomMetaGen: expected `component <name>` in {}:{}",
					path,
					line_number + 1,
				)
				return false
			}
			name: string
			name, alloc_err = strings.intern_get(&schema.names, words[1])
			if alloc_err != nil {
				return false
			}
			_, alloc_err = append(&schema.components, Meta_Component_Declaration{name = name})
			if alloc_err != nil {
				return false
			}
			clear(&properties)
			component_index = len(schema.components) - 1
			block = .Component
			continue
		}
		if block != .Component || len(words) != 2 {
			fmt.eprintfln(
				"AxiomMetaGen: invalid component property in {}:{}",
				path,
				line_number + 1,
			)
			return false
		}
		property: Meta_Property
		property.type, alloc_err = strings.intern_get(&schema.names, words[0])
		if alloc_err != nil {
			return false
		}
		property.name, alloc_err = strings.intern_get(&schema.names, words[1])
		if alloc_err != nil {
			return false
		}
		_, alloc_err = append(&properties, property)
		if alloc_err != nil {
			return false
		}
	}

	if block != .None {
		fmt.eprintfln("AxiomMetaGen: unterminated declaration in {}", path)
		return false
	}
	return true
}

parse_schema_target :: proc(schema: ^Meta_Schema, path: string) -> bool {
	if !os.is_directory(path) {
		if strings.has_suffix(path, ".axmeta") {
			return parse_meta_file(schema, path)
		} else if strings.has_suffix(path, ".odin") {
			return parse_odin_file(schema, path)
		}
		return false
	}

	walker := os.walker_create(path)
	defer os.walker_destroy(&walker)

	for info in os.walker_walk(&walker) {
		if info.type == .Regular {
			if strings.has_suffix(info.name, ".axmeta") {
				if !parse_meta_file(schema, info.fullpath) {
					continue
				}
			} else if strings.has_suffix(info.name, ".odin") {
				if !parse_odin_file(schema, info.fullpath) {
					continue
				}}

		}
	}

	if walk_path, walk_err := os.walker_error(&walker); walk_err != nil {
		fmt.eprintfln("AxiomMetaGen: could not scan {}: {}", walk_path, walk_err)
		return false
	}

	return true
}

odin_value_name :: proc(name: string) -> string {
	value, err := strings.to_snake_case(name, context.temp_allocator)
	return value if err == nil else ""
}

odin_type_name :: proc(name: string) -> string {
	value, err := strings.to_ada_case(name, context.temp_allocator)
	return value if err == nil else ""
}

emit_fixed :: proc(builder: ^strings.Builder, declaration: Meta_Fixed_Declaration) -> bool {
	type_name := odin_type_name(declaration.name)
	proc_prefix := odin_value_name(type_name)
	upper := strings.to_upper(proc_prefix, context.temp_allocator)
	if len(upper) > 3 && upper[:3] == "FP_" {
		upper = upper[3:]
	}
	raw_type := declaration.storage
	wide_type: string
	min_raw: string
	max_raw: string
	if declaration.storage == "i32" {
		wide_type = "i64"
		min_raw = "i32(-0x7fff_ffff - 1)"
		max_raw = "i32(0x7fff_ffff)"
	} else if declaration.storage == "i64" {
		wide_type = "i128"
		min_raw = "i64(-0x7fff_ffff_ffff_ffff - 1)"
		max_raw = "i64(0x7fff_ffff_ffff_ffff)"
	} else {
		fmt.eprintfln(
			"AxiomMetaGen: fixed storage {} is incomplete for Odin ({})",
			declaration.storage,
			declaration.name,
		)
		return false
	}

	fmt.sbprintfln(builder, "{} :: struct {{", type_name)
	fmt.sbprintfln(builder, "\traw: {},", raw_type)
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder)
	fmt.sbprintfln(builder, "FP_{}_FRACTION_BITS :: u32({})", upper, declaration.fraction_bits)
	fmt.sbprintfln(builder, "FP_{}_SCALE :: {}(1) << FP_{}_FRACTION_BITS", upper, wide_type, upper)
	fmt.sbprintfln(builder, "FP_{}_MIN_RAW :: {}", upper, min_raw)
	fmt.sbprintfln(builder, "FP_{}_MAX_RAW :: {}", upper, max_raw)
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"{}_narrow :: proc(value: {}) -> {} {{",
		proc_prefix,
		wide_type,
		raw_type,
	)
	fmt.sbprintfln(builder, "\tif value > {}(FP_{}_MAX_RAW) {{", wide_type, upper)
	fmt.sbprintfln(builder, "\t\treturn FP_{}_MAX_RAW", upper)
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintfln(builder, "\tif value < {}(FP_{}_MIN_RAW) {{", wide_type, upper)
	fmt.sbprintfln(builder, "\t\treturn FP_{}_MIN_RAW", upper)
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintfln(builder, "\treturn {}(value)", raw_type)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_round_ratio :: proc(numerator, denominator: {}) -> {} {{",
		proc_prefix,
		wide_type,
		wide_type,
	)
	fmt.sbprintln(builder, "\tn := numerator")
	fmt.sbprintln(builder, "\td := denominator")
	fmt.sbprintln(builder, "\tif d < 0 { n = -n; d = -d }")
	fmt.sbprintln(builder, "\tquotient := n / d")
	fmt.sbprintln(builder, "\tremainder := n % d")
	fmt.sbprintln(builder, "\tabs_remainder := remainder if remainder >= 0 else -remainder")
	fmt.sbprintln(builder, "\tif abs_remainder >= (d + 1) / 2 { quotient += -1 if n < 0 else 1 }")
	fmt.sbprintln(builder, "\treturn quotient")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_from_raw :: proc(raw: {}) -> {} {{",
		proc_prefix,
		raw_type,
		type_name,
	)
	fmt.sbprintln(builder, "\treturn {raw = raw}")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_from_int :: proc(integer: {}) -> {} {{",
		proc_prefix,
		raw_type,
		type_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn {{raw = {}_narrow({}(integer) * FP_{}_SCALE)}}",
		proc_prefix,
		wide_type,
		upper,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_to_int :: proc(value: {}) -> {} {{",
		proc_prefix,
		type_name,
		raw_type,
	)
	fmt.sbprintfln(builder, "\treturn value.raw / {}(FP_{}_SCALE)", raw_type, upper)
	fmt.sbprintln(builder, "}")

	fmt.sbprintfln(
		builder,
		"{}_add :: proc(left, right: {}) -> {} {{",
		proc_prefix,
		type_name,
		type_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn {}_from_raw({}_narrow({}(left.raw) + {}(right.raw)))",
		proc_prefix,
		proc_prefix,
		wide_type,
		wide_type,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_sub :: proc(left, right: {}) -> {} {{",
		proc_prefix,
		type_name,
		type_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn {}_from_raw({}_narrow({}(left.raw) - {}(right.raw)))",
		proc_prefix,
		proc_prefix,
		wide_type,
		wide_type,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_neg :: proc(value: {}) -> {} {{",
		proc_prefix,
		type_name,
		type_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn {}_from_raw({}_narrow(-{}(value.raw)))",
		proc_prefix,
		proc_prefix,
		wide_type,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_mul :: proc(left, right: {}) -> {} {{",
		proc_prefix,
		type_name,
		type_name,
	)
	fmt.sbprintfln(builder, "\tproduct := {}(left.raw) * {}(right.raw)", wide_type, wide_type)
	fmt.sbprintfln(
		builder,
		"\treturn {}_from_raw({}_narrow({}_round_ratio(product, FP_{}_SCALE)))",
		proc_prefix,
		proc_prefix,
		proc_prefix,
		upper,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_div :: proc(left, right: {}) -> {} {{",
		proc_prefix,
		type_name,
		type_name,
	)
	fmt.sbprintln(builder, "\tif right.raw == 0 {")
	fmt.sbprintfln(
		builder,
		"\t\treturn {}_from_raw(left.raw == 0 ? 0 : (left.raw < 0 ? FP_{}_MIN_RAW : FP_{}_MAX_RAW))",
		proc_prefix,
		upper,
		upper,
	)
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintfln(builder, "\tnumerator := {}(left.raw) * FP_{}_SCALE", wide_type, upper)
	fmt.sbprintfln(
		builder,
		"\treturn {}_from_raw({}_narrow({}_round_ratio(numerator, {}(right.raw))))",
		proc_prefix,
		proc_prefix,
		proc_prefix,
		wide_type,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(builder, "{}_equal :: proc(left, right: {}) -> bool {{", proc_prefix, type_name)
	fmt.sbprintln(builder, "\treturn left.raw == right.raw")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_not_equal :: proc(left, right: {}) -> bool {{",
		proc_prefix,
		type_name,
	)
	fmt.sbprintln(builder, "\treturn left.raw != right.raw")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(builder, "{}_less :: proc(left, right: {}) -> bool {{", proc_prefix, type_name)
	fmt.sbprintln(builder, "\treturn left.raw < right.raw")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_less_equal :: proc(left, right: {}) -> bool {{",
		proc_prefix,
		type_name,
	)
	fmt.sbprintln(builder, "\treturn left.raw <= right.raw")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_greater :: proc(left, right: {}) -> bool {{",
		proc_prefix,
		type_name,
	)
	fmt.sbprintln(builder, "\treturn left.raw > right.raw")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"{}_greater_equal :: proc(left, right: {}) -> bool {{",
		proc_prefix,
		type_name,
	)
	fmt.sbprintln(builder, "\treturn left.raw >= right.raw")
	fmt.sbprintln(builder, "}")
	return true
}

emit_vector :: proc(builder: ^strings.Builder, declaration: Meta_Vector_Declaration) {
	name := odin_type_name(declaration.name)
	scalar := odin_type_name(declaration.scalar)
	fmt.sbprintfln(builder, "{} :: struct {{", name)
	for field in declaration.fields {
		fmt.sbprintfln(builder, "\t{}: {},", odin_value_name(field), scalar)
	}
	fmt.sbprintln(builder, "}")
}

emit_component :: proc(
	builder: ^strings.Builder,
	declaration: Meta_Component_Declaration,
	mask_index: u32,
) {
	fmt.sbprintfln(builder, "Component_{} :: struct {{", odin_type_name(declaration.name))
	// The original generator used a stack while parsing component properties;
	// keep its emitted field order for generated state compatibility.
	for index := len(declaration.properties) - 1; index >= 0; index -= 1 {
		property := declaration.properties[index]
		property_type :=
			property.type if is_primitive_type(property.type) else odin_type_name(property.type)
		fmt.sbprintfln(builder, "\t{}: {},", odin_value_name(property.name), property_type)
	}
	fmt.sbprintln(builder, "}")
	upper := strings.to_upper(odin_value_name(declaration.name), context.temp_allocator)
	fmt.sbprintfln(builder, "COMPONENT_TYPE_{}_MASK_INDEX :: u32({})", upper, mask_index)
}

emit_component_runtime :: proc(
	builder: ^strings.Builder,
	declaration: Meta_Component_Declaration,
) {
	type_name := odin_type_name(declaration.name)
	value_name := odin_value_name(declaration.name)
	upper := strings.to_upper(value_name, context.temp_allocator)

	fmt.sbprintfln(
		builder,
		"COMPONENT_REGION_NAME_{} :: string(\"{}Components\")",
		upper,
		type_name,
	)
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"get_{}_component_manager :: proc(engine: ^Axiom_Engine) -> ^Entity_Component_Manager_Entry(Component_{}) {{",
		value_name,
		type_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine != nil, \"get_{}_component_manager: engine is nil\")",
		value_name,
	)
	fmt.sbprintln(builder, "\tgenerated_runtime := get_axiom_generated_engine_runtime(engine)")
	fmt.sbprintln(builder, "\tfor manager_entry in generated_runtime.component_managers {")
	fmt.sbprintfln(builder, "\t\tif manager_entry.type != COMPONENT_TYPE_{}_MASK_INDEX {{", upper)
	fmt.sbprintln(builder, "\t\t\tcontinue")
	fmt.sbprintln(builder, "\t\t}")
	fmt.sbprintfln(
		builder,
		"\t\tensure(manager_entry.region != nil, \"get_{}_component_manager: component region is nil\")",
		value_name,
	)
	fmt.sbprintln(builder, "\t\tcomponent_manager := memory_region_offset_dereference(")
	fmt.sbprintfln(builder, "\t\t\tEntity_Component_Manager_Entry(Component_{}),", type_name)
	fmt.sbprintln(builder, "\t\t\tmanager_entry.region,")
	fmt.sbprintln(builder, "\t\t\t{},")
	fmt.sbprintln(builder, "\t\t)")
	fmt.sbprintfln(
		builder,
		"\t\tensure(component_manager != nil, \"get_{}_component_manager: manager lookup failed\")",
		value_name,
	)
	fmt.sbprintln(builder, "\t\treturn component_manager")
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintfln(
		builder,
		"\tensure(false, \"get_{}_component_manager: component manager is not registered\")",
		value_name,
	)
	fmt.sbprintln(builder, "\treturn nil")
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"initialize_{}_component_manager :: proc(engine: ^Axiom_Engine) -> ^Memory_Region {{",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine != nil, \"initialize_{}_component_manager: engine is nil\")",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine.engine_memory_table != nil, \"initialize_{}_component_manager: memory table is nil\")",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tif region := memory_region_find(engine.engine_memory_table, COMPONENT_REGION_NAME_{}); region != nil {{",
		upper,
	)
	fmt.sbprintln(builder, "\t\treturn region")
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintln(builder, "\tmemory_region := memory_region_push_subregion(")
	fmt.sbprintln(builder, "\t\tengine.engine_memory_table,")
	fmt.sbprintfln(builder, "\t\tCOMPONENT_REGION_NAME_{},", upper)
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(
		builder,
		"\tensure(memory_region != nil, \"initialize_{}_component_manager: region allocation failed\")",
		value_name,
	)
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\tcomponent_manager, allocation := memory_region_push_struct(")
	fmt.sbprintfln(builder, "\t\tEntity_Component_Manager_Entry(Component_{}),", type_name)
	fmt.sbprintln(builder, "\t\tmemory_region,")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(
		builder,
		"\tensure(component_manager != nil && memory_region_allocation_is_valid(allocation), \"initialize_{}_component_manager: manager allocation failed\")",
		value_name,
	)
	fmt.sbprintfln(builder, "\tcomponent_manager.type = COMPONENT_TYPE_{}_MASK_INDEX", upper)
	fmt.sbprintln(builder, "\tcomponents_arena_error := vmem.arena_init_growing(")
	fmt.sbprintln(builder, "\t\t&component_manager.components_arena,")
	fmt.sbprintln(builder, "\t\tAXIOM_DEFAULT_ARENA_RESERVE,")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(
		builder,
		"\tensure(components_arena_error == nil, \"initialize_{}_component_manager: components arena initialization failed\")",
		value_name,
	)
	fmt.sbprintln(builder, "\tentities_arena_error := vmem.arena_init_growing(")
	fmt.sbprintln(builder, "\t\t&component_manager.entities_arena,")
	fmt.sbprintln(builder, "\t\tAXIOM_DEFAULT_ARENA_RESERVE,")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(
		builder,
		"\tensure(entities_arena_error == nil, \"initialize_{}_component_manager: entities arena initialization failed\")",
		value_name,
	)
	fmt.sbprintln(
		builder,
		"\treverse_packed_entities_lookup_arena_error := vmem.arena_init_growing(",
	)
	fmt.sbprintln(builder, "\t\t&component_manager.reverse_packed_entities_lookup_arena,")
	fmt.sbprintln(builder, "\t\tAXIOM_DEFAULT_ARENA_RESERVE,")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(
		builder,
		"\tensure(reverse_packed_entities_lookup_arena_error == nil, \"initialize_{}_component_manager: reverse lookup arena initialization failed\")",
		value_name,
	)
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\tcomponent_manager.components = make(")
	fmt.sbprintfln(builder, "\t\t[dynamic]Component_{},", type_name)
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t\tvmem.arena_allocator(&component_manager.components_arena),")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintln(builder, "\tcomponent_manager.sparse_entities = make(")
	fmt.sbprintln(builder, "\t\t[dynamic]u32,")
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t\tvmem.arena_allocator(&component_manager.entities_arena),")
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintln(builder, "\tcomponent_manager.reverse_packed_entities_lookup = make(")
	fmt.sbprintln(builder, "\t\t[dynamic]u32,")
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(builder, "\t\t0,")
	fmt.sbprintln(
		builder,
		"\t\tvmem.arena_allocator(&component_manager.reverse_packed_entities_lookup_arena),",
	)
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintln(builder, "\treturn memory_region")
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"has_{}_component :: proc(engine: ^Axiom_Engine, entity_id: Entity_ID) -> bool {{",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine != nil, \"has_{}_component: engine is nil\")",
		value_name,
	)
	fmt.sbprintln(builder, "\tentity_system := get_entity_system(engine)")
	fmt.sbprintfln(
		builder,
		"\tensure(entity_system != nil, \"has_{}_component: entity system is nil\")",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn entity_has_component(entity_system, entity_id, COMPONENT_TYPE_{}_MASK_INDEX)",
		upper,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"remove_{}_component :: proc(engine: ^Axiom_Engine, entity_id: Entity_ID) {{",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(has_{}_component(engine, entity_id), \"remove_{}_component: entity does not have component\")",
		value_name,
		value_name,
	)
	fmt.sbprintln(builder, "\tentity_system := get_entity_system(engine)")
	fmt.sbprintln(builder, "\tensure(")
	fmt.sbprintfln(
		builder,
		"\t\tentity_remove_component_mask(entity_system, entity_id, COMPONENT_TYPE_{}_MASK_INDEX),",
		upper,
	)
	fmt.sbprintfln(
		builder,
		"\t\t\"remove_{}_component: failed to remove component mask\",",
		value_name,
	)
	fmt.sbprintln(builder, "\t)")
	fmt.sbprintfln(builder, "\tcomponent_manager := get_{}_component_manager(engine)", value_name)
	fmt.sbprintfln(
		builder,
		"\tensure(component_manager != nil, \"remove_{}_component: component manager is nil\")",
		value_name,
	)
	fmt.sbprintln(builder, "\tcomponent_entity_index := get_entity_index(entity_id)")
	fmt.sbprintln(
		builder,
		"\tcomponent_index := component_manager.sparse_entities[component_entity_index]",
	)
	fmt.sbprintln(builder, "\tlast_component_index := u32(len(component_manager.components) - 1)")
	fmt.sbprintln(builder, "\tlast_component_entity_id := Entity_ID{")
	fmt.sbprintln(
		builder,
		"\t\tid = component_manager.reverse_packed_entities_lookup[last_component_index],",
	)
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintln(
		builder,
		"\tlast_component_entity_index := get_entity_index(last_component_entity_id)",
	)
	fmt.sbprintln(
		builder,
		"\tcomponent_manager.sparse_entities[component_entity_index] = MAX_ENTITIES",
	)
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\tif component_index == last_component_index {")
	fmt.sbprintln(builder, "\t\tpop(&component_manager.components)")
	fmt.sbprintln(builder, "\t\tpop(&component_manager.reverse_packed_entities_lookup)")
	fmt.sbprintln(builder, "\t\treturn")
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\tunordered_remove(&component_manager.components, component_index)")
	fmt.sbprintln(
		builder,
		"\tunordered_remove(&component_manager.reverse_packed_entities_lookup, component_index)",
	)
	fmt.sbprintln(
		builder,
		"\tcomponent_manager.sparse_entities[last_component_entity_index] = component_index",
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder)

	fmt.sbprintfln(
		builder,
		"add_{}_component_to_entity_system :: proc(engine: ^Axiom_Engine, entity_system: ^Entity_System, entity_id: Entity_ID) -> bool {{",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine != nil, \"add_{}_component_to_entity_system: engine is nil\")",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(entity_system != nil, \"add_{}_component_to_entity_system: entity system is nil\")",
		value_name,
	)
	fmt.sbprintfln(builder, "\tif !entity_add_component_mask(")
	fmt.sbprintln(builder, "\t\tentity_system,")
	fmt.sbprintln(builder, "\t\tentity_id,")
	fmt.sbprintfln(builder, "\t\tCOMPONENT_TYPE_{}_MASK_INDEX,", upper)
	fmt.sbprintln(builder, "\t) {")
	fmt.sbprintln(builder, "\t\treturn false")
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintfln(builder, "\tcomponent_manager := get_{}_component_manager(engine)", value_name)
	fmt.sbprintln(builder, "\tentity_index := int(get_entity_index(entity_id))")
	fmt.sbprintln(builder, "\tif entity_index >= len(component_manager.sparse_entities) {")
	fmt.sbprintln(builder, "\t\told_length := len(component_manager.sparse_entities)")
	fmt.sbprintln(builder, "\t\tnew_length := entity_index + 1")
	fmt.sbprintln(builder, "\t\tif new_length > cap(component_manager.sparse_entities) {")
	fmt.sbprintln(
		builder,
		"\t\t\tnew_capacity := max(new_length, max(8, 2 * cap(component_manager.sparse_entities)))",
	)
	fmt.sbprintln(
		builder,
		"\t\t\treserve_error := reserve(&component_manager.sparse_entities, new_capacity)",
	)
	fmt.sbprintfln(
		builder,
		"\t\t\tensure(reserve_error == nil, \"add_{}_component_to_entity_system: sparse entity reservation failed\")",
		value_name,
	)
	fmt.sbprintln(builder, "\t\t}")
	fmt.sbprintln(
		builder,
		"\t\tresize_error := resize(&component_manager.sparse_entities, new_length)",
	)
	fmt.sbprintfln(
		builder,
		"\t\tensure(resize_error == nil, \"add_{}_component_to_entity_system: sparse entity resize failed\")",
		value_name,
	)
	fmt.sbprintln(builder, "\t\tfor index := old_length; index < new_length; index += 1 {")
	fmt.sbprintln(builder, "\t\t\tcomponent_manager.sparse_entities[index] = MAX_ENTITIES")
	fmt.sbprintln(builder, "\t\t}")
	fmt.sbprintln(builder, "\t}")
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\tcomponent_index := u32(len(component_manager.components))")
	fmt.sbprintfln(builder, "\tappend(&component_manager.components, Component_{}{{}})", type_name)
	fmt.sbprintln(
		builder,
		"\tappend(&component_manager.reverse_packed_entities_lookup, entity_id.id)",
	)
	fmt.sbprintln(builder, "\tcomponent_manager.sparse_entities[entity_index] = component_index")
	fmt.sbprintfln(
		builder,
		"\t{}_component := &component_manager.components[component_index]",
		value_name,
	)
	fmt.sbprintfln(builder, "\t_ = {}_component", value_name)
	fmt.sbprintln(builder, "\t// initialize")
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "\treturn true")
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(
		builder,
		"add_{}_component_to_engine :: proc(engine: ^Axiom_Engine, entity_id: Entity_ID) -> bool {{",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\tensure(engine != nil, \"add_{}_component_to_engine: engine is nil\")",
		value_name,
	)
	fmt.sbprintln(builder, "\tentity_system := get_entity_system(engine)")
	fmt.sbprintfln(
		builder,
		"\tensure(entity_system != nil, \"add_{}_component_to_engine: entity system is nil\")",
		value_name,
	)
	fmt.sbprintfln(
		builder,
		"\treturn add_{}_component_to_entity_system(engine, entity_system, entity_id)",
		value_name,
	)
	fmt.sbprintln(builder, "}")
	fmt.sbprintfln(builder, "add_{}_component :: proc{{", value_name)
	fmt.sbprintfln(builder, "\tadd_{}_component_to_entity_system,", value_name)
	fmt.sbprintfln(builder, "\tadd_{}_component_to_engine,", value_name)
	fmt.sbprintln(builder, "}")
}

begin_generated_file :: proc(builder: ^strings.Builder) {
	fmt.sbprintln(builder, "package axiom")
	fmt.sbprintln(builder)
	fmt.sbprintln(builder, "// Generated by AxiomMetaGen; do not edit by hand.")
	fmt.sbprintln(builder)
}

write_generated_state_file :: proc(source_directory: string, schema: ^Meta_Schema) -> bool {
	builder, err := strings.builder_make()
	if err != nil {
		return false
	}
	defer strings.builder_destroy(&builder)

	begin_generated_file(&builder)
	fmt.sbprintln(&builder, "import vmem \"core:mem/virtual\"")
	fmt.sbprintln(&builder)
	fmt.sbprintln(
		&builder,
		"Destroy_Component_Proc :: #type proc(engine: ^Axiom_Engine, entity_id: Entity_ID)",
	)
	fmt.sbprintln(&builder, "Axiom_Generated_Component_Manager_Table :: struct {")
	fmt.sbprintln(&builder, "\tdestroy_component: Destroy_Component_Proc,")
	fmt.sbprintln(&builder, "\tregion:            ^Memory_Region,")
	fmt.sbprintln(&builder, "\ttype:              u32,")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "Axiom_Generated_Engine_Runtime :: struct {")
	fmt.sbprintln(&builder, "\tcomponent_managers_arena: vmem.Arena,")
	fmt.sbprintln(
		&builder,
		"\tcomponent_managers:       [dynamic]Axiom_Generated_Component_Manager_Table,",
	)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "get_axiom_generated_engine_runtime :: proc(")
	fmt.sbprintln(&builder, "\tengine: ^Axiom_Engine,")
	fmt.sbprintln(&builder, ") -> ^Axiom_Generated_Engine_Runtime {")
	fmt.sbprintln(
		&builder,
		"\tensure(engine != nil, \"get_axiom_generated_engine_runtime: engine is nil\")",
	)
	fmt.sbprintln(
		&builder,
		"\tensure(engine.engine_memory_region != nil, \"get_axiom_generated_engine_runtime: engine memory region is nil\")",
	)
	fmt.sbprintln(&builder, "\tgenerated_runtime := memory_region_offset_dereference(")
	fmt.sbprintln(&builder, "\t\tAxiom_Generated_Engine_Runtime,")
	fmt.sbprintln(&builder, "\t\tengine.engine_memory_region,")
	fmt.sbprintln(&builder, "\t\tengine.generated_engine_runtime,")
	fmt.sbprintln(&builder, "\t)")
	fmt.sbprintln(
		&builder,
		"\tensure(generated_runtime != nil, \"get_axiom_generated_engine_runtime: runtime lookup failed\")",
	)
	fmt.sbprintln(&builder, "\treturn generated_runtime")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "initialize_axiom_components :: proc(engine: ^Axiom_Engine) {")
	fmt.sbprintln(
		&builder,
		"\tensure(engine != nil, \"initialize_axiom_components: engine is nil\")",
	)
	fmt.sbprintln(
		&builder,
		"\tensure(engine.engine_memory_region != nil, \"initialize_axiom_components: engine memory region is nil\")",
	)
	fmt.sbprintln(&builder, "\tgenerated_runtime, allocation := memory_region_push_struct(")
	fmt.sbprintln(&builder, "\t\tAxiom_Generated_Engine_Runtime,")
	fmt.sbprintln(&builder, "\t\tengine.engine_memory_region,")
	fmt.sbprintln(&builder, "\t)")
	fmt.sbprintln(
		&builder,
		"\tensure(generated_runtime != nil && memory_region_allocation_is_valid(allocation), \"initialize_axiom_components: runtime allocation failed\")",
	)
	fmt.sbprintln(&builder, "\tengine.generated_engine_runtime = allocation.offset")
	fmt.sbprintln(&builder, "\tcomponent_managers_arena_error := vmem.arena_init_growing(")
	fmt.sbprintln(&builder, "\t\t&generated_runtime.component_managers_arena,")
	fmt.sbprintln(&builder, "\t\tAXIOM_DEFAULT_ARENA_RESERVE,")
	fmt.sbprintln(&builder, "\t)")
	fmt.sbprintln(
		&builder,
		"\tensure(component_managers_arena_error == nil, \"initialize_axiom_components: component manager table arena initialization failed\")",
	)
	fmt.sbprintln(&builder, "\tgenerated_runtime.component_managers = make(")
	fmt.sbprintln(&builder, "\t\t[dynamic]Axiom_Generated_Component_Manager_Table,")
	fmt.sbprintln(&builder, "\t\t0,")
	fmt.sbprintln(&builder, "\t\t0,")
	fmt.sbprintln(
		&builder,
		"\t\tvmem.arena_allocator(&generated_runtime.component_managers_arena),",
	)
	fmt.sbprintln(&builder, "\t)")
	fmt.sbprintln(&builder)
	for index := len(schema.components) - 1; index >= 0; index -= 1 {
		value_name := odin_value_name(schema.components[index].name)
		upper := strings.to_upper(value_name, context.temp_allocator)
		fmt.sbprintfln(&builder, "\t_, {}_append_error := append(", value_name)
		fmt.sbprintln(&builder, "\t\t&generated_runtime.component_managers,")
		fmt.sbprintln(&builder, "\t\tAxiom_Generated_Component_Manager_Table{")
		fmt.sbprintfln(&builder, "\t\t\tdestroy_component = remove_{}_component,", value_name)
		fmt.sbprintfln(
			&builder,
			"\t\t\tregion            = initialize_{}_component_manager(engine),",
			value_name,
		)
		fmt.sbprintfln(&builder, "\t\t\ttype              = COMPONENT_TYPE_{}_MASK_INDEX,", upper)
		fmt.sbprintln(&builder, "\t\t},")
		fmt.sbprintln(&builder, "\t)")
		fmt.sbprintfln(
			&builder,
			"\tensure({}_append_error == nil, \"initialize_axiom_components: failed to register {} component manager\")",
			value_name,
			value_name,
		)
	}
	fmt.sbprintln(&builder, "}")

	return write_generated_file(
		source_directory,
		"generated_state.odin",
		strings.to_string(builder),
	)
}

generated_file_name :: proc(kind, declaration_name: string) -> string {
	return fmt.aprintf(
		"generated_{}_{}.odin",
		kind,
		odin_value_name(declaration_name),
		allocator = context.allocator,
	)
}

write_generated_file :: proc(output_directory, file_name, contents: string) -> bool {
	path, path_err := filepath.join({output_directory, file_name}, context.allocator)
	if path_err != nil {
		fmt.eprintfln("AxiomMetaGen: could not build output path for {}: {}", file_name, path_err)
		return false
	}
	defer delete(path, context.allocator)

	if write_err := os.write_entire_file(path, contents); write_err != nil {
		fmt.eprintfln("AxiomMetaGen: could not write {}: {}", path, write_err)
		return false
	}
	return true
}

write_fixed_file :: proc(
	output_directory, file_name: string,
	declaration: Meta_Fixed_Declaration,
) -> bool {
	builder, err := strings.builder_make()
	if err != nil {
		return false
	}
	defer strings.builder_destroy(&builder)

	begin_generated_file(&builder)
	if !emit_fixed(&builder, declaration) {
		return false
	}
	return write_generated_file(output_directory, file_name, strings.to_string(builder))
}

write_vector_file :: proc(
	output_directory, file_name: string,
	declaration: Meta_Vector_Declaration,
) -> bool {
	builder, err := strings.builder_make()
	if err != nil {
		return false
	}
	defer strings.builder_destroy(&builder)

	begin_generated_file(&builder)
	emit_vector(&builder, declaration)
	return write_generated_file(output_directory, file_name, strings.to_string(builder))
}

write_component_file :: proc(
	output_directory, file_name: string,
	declaration: Meta_Component_Declaration,
	mask_index: u32,
) -> bool {
	builder, err := strings.builder_make()
	if err != nil {
		return false
	}
	defer strings.builder_destroy(&builder)

	begin_generated_file(&builder)
	fmt.sbprintln(&builder, "import vmem \"core:mem/virtual\"")
	fmt.sbprintln(&builder)
	emit_component(&builder, declaration, mask_index)
	fmt.sbprintln(&builder)
	emit_component_runtime(&builder, declaration)
	return write_generated_file(output_directory, file_name, strings.to_string(builder))
}

is_owned_generated_file :: proc(file_name: string) -> bool {
	if !strings.has_suffix(file_name, ".odin") {
		return false
	}
	return(
		file_name == "generated.odin" ||
		file_name == "generated_api.odin" ||
		strings.has_prefix(file_name, "generated_fixed_") ||
		strings.has_prefix(file_name, "generated_vector_") ||
		strings.has_prefix(file_name, "generated_component_") \
	)
}

file_name_is_expected :: proc(file_name: string, expected: []string) -> bool {
	for expected_name in expected {
		if file_name == expected_name {
			return true
		}
	}
	return false
}

remove_stale_generated_files :: proc(output_directory: string, expected: []string) -> bool {
	files, read_err := os.read_all_directory_by_path(output_directory, context.allocator)
	if read_err != nil {
		fmt.eprintfln(
			"AxiomMetaGen: could not scan output directory {}: {}",
			output_directory,
			read_err,
		)
		return false
	}
	defer os.file_info_slice_delete(files, context.allocator)

	for file in files {
		if file.type != .Regular ||
		   !is_owned_generated_file(file.name) ||
		   file_name_is_expected(file.name, expected) {
			continue
		}
		if remove_err := os.remove(file.fullpath); remove_err != nil {
			fmt.eprintfln(
				"AxiomMetaGen: could not remove stale output {}: {}",
				file.fullpath,
				remove_err,
			)
			return false
		}
	}
	return true
}

register_generated_file :: proc(expected: ^[dynamic]string, file_name: string) -> bool {
	if file_name_is_expected(file_name, expected[:]) {
		fmt.eprintfln("AxiomMetaGen: declarations map to duplicate output file {}", file_name)
		return false
	}
	if _, err := append(expected, file_name); err != nil {
		fmt.eprintfln("AxiomMetaGen: could not register output {}: {}", file_name, err)
		return false
	}
	return true
}

remove_legacy_generated_directory :: proc(source_directory: string) -> bool {
	legacy_directory, path_err := filepath.join({source_directory, "generated"}, context.allocator)
	if path_err != nil {
		fmt.eprintfln("AxiomMetaGen: could not build legacy generated path: {}", path_err)
		return false
	}
	defer delete(legacy_directory, context.allocator)

	if !os.is_directory(legacy_directory) {
		return true
	}
	if !remove_stale_generated_files(legacy_directory, nil) {
		return false
	}

	files, read_err := os.read_all_directory_by_path(legacy_directory, context.allocator)
	if read_err != nil {
		fmt.eprintfln(
			"AxiomMetaGen: could not inspect legacy generated directory {}: {}",
			legacy_directory,
			read_err,
		)
		return false
	}
	defer os.file_info_slice_delete(files, context.allocator)
	if len(files) != 0 {
		return true
	}
	if remove_err := os.remove(legacy_directory); remove_err != nil {
		fmt.eprintfln(
			"AxiomMetaGen: could not remove legacy generated directory {}: {}",
			legacy_directory,
			remove_err,
		)
		return false
	}
	return true
}

emit_schema_files :: proc(schema: ^Meta_Schema, source_directory: string) -> bool {
	// Builders and the expected-file list can grow on the caller's allocator.
	// Case conversions only survive until the current output file is written.
	scratch: vmem.Arena
	scratch.default_commit_size = 4 * mem.Kilobyte
	if err := vmem.arena_init_growing(&scratch, 64 * mem.Kilobyte); err != nil {
		fmt.eprintfln("AxiomMetaGen: could not allocate emission scratch: {}", err)
		return false
	}
	defer vmem.arena_destroy(&scratch)
	context.temp_allocator = vmem.arena_allocator(&scratch)

	expected: [dynamic]string
	defer {
		for file_name in expected {
			delete(file_name)
		}
		delete(expected)
	}
	for declaration in schema.fixed {
		defer vmem.arena_free_all(&scratch)
		file_name := generated_file_name("fixed", declaration.name)
		if !register_generated_file(&expected, file_name) {
			delete(file_name)
			return false
		}
		if !write_fixed_file(source_directory, file_name, declaration) {
			return false
		}
	}
	for declaration in schema.vectors {
		defer vmem.arena_free_all(&scratch)
		file_name := generated_file_name("vector", declaration.name)
		if !register_generated_file(&expected, file_name) {
			delete(file_name)
			return false
		}
		if !write_vector_file(source_directory, file_name, declaration) {
			return false
		}
	}
	for index := 0; index < len(schema.components); index += 1 {
		defer vmem.arena_free_all(&scratch)
		mask_index := u32(len(schema.components) - index)
		declaration := schema.components[index]
		file_name := generated_file_name("component", declaration.name)
		if !register_generated_file(&expected, file_name) {
			delete(file_name)
			return false
		}
		if !write_component_file(source_directory, file_name, declaration, mask_index) {
			return false
		}
	}
	if !write_generated_state_file(source_directory, schema) ||
	   !remove_stale_generated_files(source_directory, expected[:]) ||
	   !remove_legacy_generated_directory(source_directory) {
		return false
	}
	return true
}


generate :: proc(args: []string) -> bool {
	if len(args) < 3 {
		fmt.eprintln(
			"usage: axiom-metagen <source-directory> <schema-directory|schema.axmeta> [...]",
		)
		return false
	}

	source_directory := args[1]
	schema: Meta_Schema
	if err := schema_init(&schema); err != nil {
		fmt.eprintfln("AxiomMetaGen: could not allocate schema storage: {}", err)
		return false
	}
	defer schema_destroy(&schema)
	for path in args[2:] {
		if !parse_schema_target(&schema, path) {
			return false
		}
	}

	if !emit_schema_files(&schema, source_directory) {
		fmt.eprintln("AxiomMetaGen: failed to write generated files under ", source_directory)
		return false
	}
	return true
}

main :: proc() {
	if !generate(os.args) {
		os.exit(1)
	}
}
