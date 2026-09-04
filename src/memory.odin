package axiom

import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Memory_Region :: struct {
	arena: ^vmem.Arena,
	base:  rawptr,
	used:  u64,
	name:  string,
	next:  ^Memory_Region,
}

Memory_Region_Offset :: struct {
	offset: u64,
}

Memory_Region_Table :: struct {
	string_arena: vmem.Arena,
	first:        ^Memory_Region,
	size:         u64,
}

Memory_Region_Allocation :: struct {
	data:   rawptr,
	offset: Memory_Region_Offset,
}

Memory_Region_Array :: struct {
	start:     Memory_Region_Offset,
	type_size: u32,
	count:     u32,
}

Memory_Region_Params :: struct {
	reserve_size: u64,
	name:         string,
}

memory_region_table_init :: proc(table: ^Memory_Region_Table) -> bool {
	if table == nil {
		return false
	}
	err := vmem.arena_init_growing(&table.string_arena, AXIOM_DEFAULT_ARENA_RESERVE)
	return err == nil
}

memory_region_table_destroy :: proc(table: ^Memory_Region_Table) {
	if table == nil {
		return
	}
	for region := table.first; region != nil; {
		next := region.next
		if region.arena != nil {
			vmem.arena_destroy(region.arena)
		}
		region = next
	}
	vmem.arena_destroy(&table.string_arena)
	table^ = {}
}

memory_region_push_subregion :: proc(
	table: ^Memory_Region_Table,
	name: string,
	max_size: u64,
) -> ^Memory_Region {
	if table == nil {
		return nil
	}

	region, err := vmem.new(&table.string_arena, Memory_Region)
	if err != nil {
		return nil
	}
	region.name, err = strings.clone(name, allocator = vmem.arena_allocator(&table.string_arena))
	if err != nil {
		return nil
	}

	region.arena, err = vmem.new(&table.string_arena, vmem.Arena)
	if err != nil {
		return nil
	}
	reserve := uint(max_size)
	if reserve == 0 {
		reserve = AXIOM_DEFAULT_ARENA_RESERVE
	}
	if err = vmem.arena_init_static(
		region.arena,
		reserved = reserve,
		commit_size = AXIOM_DEFAULT_ARENA_COMMIT,
	); err != nil {
		return nil
	}

	// The standard arena owns the virtual memory; the base allocation remains
	// at offset zero so region offsets can be translated without raw pointers in
	// simulation state.
	base: []byte
	base, err = vmem.arena_alloc(region.arena, 1, 1)
	if err != nil || len(base) == 0 {
		vmem.arena_destroy(region.arena)
		return nil
	}
	region.base = raw_data(base)
	_ = vmem.arena_static_reset_to(region.arena, 0)

	region.next = table.first
	table.first = region
	table.size += u64(reserve)
	return region
}

memory_region_find :: proc(table: ^Memory_Region_Table, name: string) -> ^Memory_Region {
	if table == nil {
		return nil
	}
	for region := table.first; region != nil; region = region.next {
		if region.name == name {
			return region
		}
	}
	return nil
}

arena_push :: proc(
	arena: ^vmem.Arena,
	size, alignment: u64,
) -> rawptr {
	if arena == nil || size == 0 || alignment == 0 {
		return nil
	}

	data, err := vmem.arena_alloc(arena, uint(size), uint(alignment))
	if err != nil || len(data) == 0 {
		return nil
	}
	return raw_data(data)
}

arena_push_struct :: proc(
	$T: typeid,
	arena: ^vmem.Arena,
) -> ^T {
	value := (^T)(arena_push(arena, u64(size_of(T)), u64(align_of(T))))
	if value != nil {
		mem.zero(value, size_of(T))
	}
	return value
}

memory_region_push :: proc(
	region: ^Memory_Region,
	size, alignment: u64,
) -> Memory_Region_Allocation {
	if region == nil || region.arena == nil || size == 0 || alignment == 0 {
		return {}
	}

	offset := u64(mem.align_forward_uint(uint(region.used), uint(alignment)))
	data := arena_push(region.arena, size, alignment)
	if data == nil {
		return {}
	}
	region.used = offset + size
	return {data = data, offset = {offset = offset}}
}

memory_region_push_struct :: proc(
	$T: typeid,
	region: ^Memory_Region,
) -> (
	value: ^T,
	allocation: Memory_Region_Allocation,
) {
	allocation = memory_region_push(region, u64(size_of(T)), u64(align_of(T)))
	if allocation.data != nil {
		value = (^T)(allocation.data)
		mem.zero(value, size_of(T))
	}
	return
}

memory_region_offset_dereference :: proc(
	$T: typeid,
	region: ^Memory_Region,
	offset: Memory_Region_Offset,
) -> ^T {
	if region == nil || region.base == nil {
		return nil
	}
	return (^T)(uintptr(region.base) + uintptr(offset.offset))
}

memory_region_find_at :: proc(
	$T: typeid,
	region_base: rawptr,
	array: Memory_Region_Array,
	index: u32,
) -> Memory_Region_Allocation {
	if region_base == nil || index >= array.count || u32(size_of(T)) != array.type_size {
		return {}
	}
	offset := array.start.offset + u64(array.type_size) * u64(index)
	return {
		data = rawptr(uintptr(region_base) + uintptr(offset)),
		offset = {offset = offset},
	}
}

memory_region_allocation_is_valid :: proc(allocation: Memory_Region_Allocation) -> bool {
	return allocation.data != nil
}
