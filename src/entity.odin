package axiom

import vmem "core:mem/virtual"

Entity_ID :: struct {
	id: u32,
}

Entity_System_Tick_Group :: enum {
	None,
	Pre_Physics,
}

Components_Type_Mask :: struct {
	word: [4]u64,
}

Entity_System_Configuration :: struct {
	dependencies: [dynamic]string,
	tick_group:   Entity_System_Tick_Group,
}

system_after :: proc(config: ^Entity_System_Configuration, system: string) {
	append(&config.dependencies, system)
	// Todo(Nacho): check alloc error
}

Update_System_Proc :: #type proc(engine: ^Axiom_Engine)
Entity_System :: struct {
	name:               string,
	configuration:      Entity_System_Configuration,
	update_system_proc: Update_System_Proc,
	target_components:  Components_Type_Mask,
}

Entity_Component_System :: struct {
	entity_list: Entity_List,
}

Entity_Component_Manager_Entry :: struct($T: typeid) {
	type:                                 u32,
	components_arena:                     vmem.Arena,
	entities_arena:                       vmem.Arena,
	reverse_packed_entities_lookup_arena: vmem.Arena,
	components:                           [dynamic]T,
	sparse_entities:                      [dynamic]u32,
	reverse_packed_entities_lookup:       [dynamic]u32,
}

Entity_Component_Manager_Registry :: struct {
	component_managers: [dynamic]rawptr,
	count:              u32,
}

Entity_Description :: struct {
	id:                    Entity_ID,
	owned_components_mask: Components_Type_Mask,
}

Entity_List :: struct {
	entities_arena: vmem.Arena,
	entities:       [dynamic]Entity_Description,
	available:      u32,
	next_free:      u32,
	last_free:      u32,
}

Axiom_Component_System_Parameters :: struct {
	max_components:          u32,
	preallocated_components: u32,
	type:                    u32,
}

make_entity_id :: proc(index, generation: u32) -> Entity_ID {
	return {id = (generation << ENTITY_INDEX_BITS) | (index & ENTITY_INDEX_MASK)}
}

get_entity_index :: proc(entity: Entity_ID) -> u32 {
	return entity.id & ENTITY_INDEX_MASK
}

get_entity_generation :: proc(entity: Entity_ID) -> u32 {
	return entity.id >> ENTITY_INDEX_BITS
}

entity_equals :: proc(left, right: Entity_ID) -> bool {
	return(
		get_entity_generation(left) == get_entity_generation(right) &&
		get_entity_index(left) == get_entity_index(right) \
	)
}

make_entity_system :: proc(engine: ^Axiom_Engine) -> ^Entity_Component_System {
	if engine == nil || engine.engine_memory_table == nil {
		return nil
	}

	region := memory_region_find(engine.engine_memory_table, "EntitySystem")
	if region == nil {
		region = memory_region_push_subregion(engine.engine_memory_table, "EntitySystem", 0)
	}

	if region == nil {
		return nil
	}

	engine.entity_system_region = region

	if region.used != 0 {
		return memory_region_offset_dereference(Entity_Component_System, region, {offset = 0})
	}

	entity_system, allocation := memory_region_push_struct(Entity_Component_System, region)
	if entity_system == nil || !memory_region_allocation_is_valid(allocation) {
		return nil
	}
	if vmem.arena_init_growing(
		   &entity_system.entity_list.entities_arena,
		   AXIOM_DEFAULT_ARENA_RESERVE,
	   ) !=
	   nil {
		return nil
	}
	entity_system.entity_list.entities = make(
		[dynamic]Entity_Description,
		0,
		0,
		vmem.arena_allocator(&entity_system.entity_list.entities_arena),
	)
	entity_system.entity_list.available = 0
	entity_system.entity_list.next_free = MAX_ENTITIES
	entity_system.entity_list.last_free = MAX_ENTITIES
	return entity_system
}

get_entity_system :: proc(engine: ^Axiom_Engine) -> ^Entity_Component_System {
	if engine == nil {
		return nil
	}

	region := memory_region_find(engine.engine_memory_table, "EntitySystem")
	if region == nil {
		return nil
	}

	return cast(^Entity_Component_System)region.base
}

get_entity :: proc(entity_system: ^Entity_Component_System, id: Entity_ID) -> Entity_Description {
	if entity_system == nil || !entity_is_valid(entity_system, id) {
		return {}
	}
	return entity_system.entity_list.entities[get_entity_index(id)]
}

entity_is_valid :: proc(entity_system: ^Entity_Component_System, id: Entity_ID) -> bool {
	if entity_system == nil {
		return false
	}
	index := get_entity_index(id)
	if index >= MAX_ENTITIES || int(index) >= len(entity_system.entity_list.entities) {
		return false
	}
	return entity_equals(entity_system.entity_list.entities[index].id, id)
}

create_entity :: proc(entity_system: ^Entity_Component_System) -> Entity_ID {
	if entity_system == nil {
		return {id = MAX_ENTITIES}
	}

	if entity_system.entity_list.available == 0 {
		index := u32(len(entity_system.entity_list.entities))
		if index >= MAX_ENTITIES {
			return {id = MAX_ENTITIES}
		}

		entity := Entity_Description {
			id = make_entity_id(index, 1),
		}
		if _, err := append(&entity_system.entity_list.entities, entity); err != nil {
			return {id = MAX_ENTITIES}
		}
		return entity.id
	}

	free_index := entity_system.entity_list.next_free
	if free_index >= u32(len(entity_system.entity_list.entities)) {
		return {id = MAX_ENTITIES}
	}

	free_entity := &entity_system.entity_list.entities[free_index]
	free_entity.owned_components_mask = {}
	next_free := get_entity_index(free_entity.id)
	free_entity.id = make_entity_id(free_index, get_entity_generation(free_entity.id) + 1)
	entity_system.entity_list.available -= 1
	entity_system.entity_list.next_free = next_free
	if entity_system.entity_list.available == 0 {
		entity_system.entity_list.next_free = MAX_ENTITIES
		entity_system.entity_list.last_free = MAX_ENTITIES
	}
	return free_entity.id
}

destroy_entity :: proc(
	engine: ^Axiom_Engine,
	entity_system: ^Entity_Component_System,
	entity: Entity_ID,
) {
	if !entity_is_valid(entity_system, entity) {
		return
	}
	generated_runtime := get_axiom_generated_engine_runtime(engine)
	for manager_region in generated_runtime.component_managers {
		if (entity_has_component(entity_system, entity, manager_region.type)) {
			manager_region.destroy_component(engine, entity)
		}
	}
	index := get_entity_index(entity)
	dead := &entity_system.entity_list.entities[index]
	if entity_system.entity_list.available > 0 {
		last_free := &entity_system.entity_list.entities[entity_system.entity_list.last_free]
		last_free.id = make_entity_id(index, get_entity_generation(last_free.id))
		dead.id = {
			id = (dead.id.id & ~ENTITY_INDEX_MASK) | MAX_ENTITIES,
		}
		entity_system.entity_list.last_free = index
		entity_system.entity_list.available += 1
		return
	}

	dead.id = {
		id = (dead.id.id & ~ENTITY_INDEX_MASK) | MAX_ENTITIES,
	}
	entity_system.entity_list.next_free = index
	entity_system.entity_list.last_free = index
	entity_system.entity_list.available = 1
}

entity_has_component :: proc(
	entity_system: ^Entity_Component_System,
	id: Entity_ID,
	component_index: u32,
) -> bool {
	if !entity_is_valid(entity_system, id) {
		return false
	}
	entity := get_entity(entity_system, id)
	word_index := component_index / 64
	if word_index >= len(entity.owned_components_mask.word) {
		return false
	}
	return(
		(entity.owned_components_mask.word[word_index] & (u64(1) << (component_index % 64))) !=
		0 \
	)
}

entity_remove_component_mask :: proc(
	entity_system: ^Entity_Component_System,
	id: Entity_ID,
	component_index: u32,
) -> bool {
	if !entity_is_valid(entity_system, id) {
		return false
	}
	word_index := component_index / 64
	if word_index >= len(Components_Type_Mask{}.word) {
		return false
	}

	entity := &entity_system.entity_list.entities[get_entity_index(id)]
	component_bit := u64(1) << (component_index % 64)
	if (entity.owned_components_mask.word[word_index] & component_bit) == 0 {
		return true
	}

	entity.owned_components_mask.word[word_index] &= ~component_bit
	return true
}

entity_add_component_mask :: proc(
	entity_system: ^Entity_Component_System,
	id: Entity_ID,
	component_index: u32,
) -> bool {
	if !entity_is_valid(entity_system, id) {
		return false
	}
	word_index := component_index / 64
	if word_index >= len(Components_Type_Mask{}.word) {
		return false
	}
	entity := &entity_system.entity_list.entities[get_entity_index(id)]
	component_bit := u64(1) << (component_index % 64)
	if (entity.owned_components_mask.word[word_index] & component_bit) != 0 {
		return false
	}
	entity.owned_components_mask.word[word_index] |= component_bit
	return true
}

entity_add_component_mask :: proc(mask: ^Components_Type_Mask, component_index: u32) -> bool {
	word_index := component_index / 64
	if word_index >= len(Components_Type_Mask{}.word) {
		return false
	}
	component_bit := u64(1) << (component_index % 64)
	if (mask.word[word_index] & component_bit) != 0 {
		return false
	}
	mask.word[word_index] |= component_bit
	return true
}
