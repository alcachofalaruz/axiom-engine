package axiom

import "core:c"
import "core:mem"
import mem_virtual "core:mem/virtual"
import b3 "vendor:box3d"

Physics_World :: struct {
	world_id:      b3.WorldId,
	time_step:     f32,
	substep_count: u32,
}

Physics_State_Buffer :: struct {
	arena: ^mem_virtual.Arena,
}

Physics_World_Create_Parameters :: struct {
	substep_count: u32,
	time_step:     f32,
}

destroy_physics_world :: proc(world: ^Physics_World) {
	if world != nil {
		b3.DestroyWorld(world.world_id)
	}
}

serialize_physics :: proc(world: ^Physics_World, buffer: ^Physics_State_Buffer) {
	_, _ = world, buffer
}

deserialize_physics :: proc(world: ^Physics_World, buffer: ^Physics_State_Buffer) {
	_, _ = world, buffer
}

step_physics :: proc(world: ^Physics_World) {
	if world != nil {
		b3.World_Step(world.world_id, world.time_step, c.int(world.substep_count))
	}
}

get_physics_world_state_hash :: proc(world: ^Physics_World) -> u64 {
	_ = world
	return 0
}

create_dynamic_capsule :: proc(world: ^Physics_World) -> u64 {
	_ = world
	return 0
}

create_physics_world :: proc(
	engine: ^Axiom_Engine,
	parameters: Physics_World_Create_Parameters,
) -> Memory_Region_Allocation {
	if engine == nil {
		return {}
	}

	world, allocation := memory_region_push_struct(Physics_World, engine.simulation_state_region)
	if world == nil {
		return {}
	}
	world.time_step = parameters.time_step
	world.substep_count = parameters.substep_count
	definition := b3.DefaultWorldDef()
	world.world_id = b3.CreateWorld(definition)
	b3.World_SetContactRecycleDistance(world.world_id, 100_000.0)
	return allocation
}
