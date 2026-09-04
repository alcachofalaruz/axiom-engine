package axiom

Simulation_State :: struct {
	init:          bool,
	physics_world: Memory_Region_Offset,
	time_step:     f32,
}

get_simulation_state :: proc(engine: ^Axiom_Engine) -> ^Simulation_State {
	if engine == nil || engine.simulation_state_region == nil {
		return nil
	}
	return memory_region_offset_dereference(
		Simulation_State,
		engine.simulation_state_region,
		{offset = 0},
	)
}

step_simulation :: proc(engine: ^Axiom_Engine, state: ^Simulation_State) {
	if engine == nil || state == nil {
		return
	}

	if !state.init {
		state.init = true
		parameters := Physics_World_Create_Parameters {
			substep_count = 4,
			time_step     = state.time_step,
		}
		state.physics_world = create_physics_world(engine, parameters).offset
	}

	world := memory_region_offset_dereference(
		Physics_World,
		engine.simulation_state_region,
		state.physics_world,
	)
	step_physics(world)
}
