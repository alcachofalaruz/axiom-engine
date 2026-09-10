package axiom

import "core:mem"
import mem_virtual "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

Axiom_Callback :: #type proc(_: ^Axiom_Engine)

Axiom_Init_Parameters :: struct {
	max_axiom_cores:   u32,
	target_fps:        u32,
	content_directory: string,
	config_directory:  string,
}

Axiom_Thread_Parameters :: struct {
	engine: ^Axiom_Engine,
	lane:   Lane_Context,
}

Axiom_Engine :: struct {
	game_thread_count:        u32,
	target_fps:               u32,
	last_tick_time:           f32,
	tick_head:                u64,
	tick_verified:            u64,
	tick_current:             u64,
	last_time:                time.Time,
	lane_broadcast_memory:    u64,
	game_barrier:             sync.Barrier,
	game_threads:             []^thread.Thread,
	counter_per_sim_step:     time.Duration,
	delta_time:               f32,
	initialized:              bool,
	running:                  u32,
	arena:                    ^mem_virtual.Arena,
	engine_memory_table:      ^Memory_Region_Table,
	simulation_state_region:  ^Memory_Region,
	engine_memory_region:     ^Memory_Region,
	entity_system_region:     ^Memory_Region,
	generated_engine_runtime: Memory_Region_Offset,
	systems:                  [dynamic]Entity_System,
}

Axiom_System_Tick_Phase :: enum {
	None,
	Pre_Physics,
}

tick_systems :: proc(engine: ^Axiom_Engine, phase: Axiom_System_Tick_Phase) {
	// Note(Nacho): we either want to keep systems in their own array or keep track of
	// where each start on the array, this will do for now

	// Note(Nacho): future nacho, search for first index more efficiently
	// and just fo if group != phase -> break
	found := false
	for system in engine.systems {
		if system.configuration.tick_group == phase {
			found = true
			system.update_system_proc(engine)
			continue
		}

		// systems are sorted, if we reached here it means we ran out
		// of systems in this tick phase to tick
		if found {
			break
		}
	}
}

tick_axiom :: proc(engine: ^Axiom_Engine) {
	ensure(engine != nil)
	tick_systems(engine, Axiom_System_Tick_Phase.Pre_Physics)
	lane_sync()
	step_simulation(engine, get_simulation_state(engine))
	if lane_index() == 0 {
		engine.tick_current += 1
	}
}

axiom_thread_entry :: proc(data: rawptr) {
	parameters := cast(^Axiom_Thread_Parameters)data
	if parameters == nil {
		return
	}

	ctx := thread_context_alloc()
	if ctx == nil {
		return
	}
	defer thread_context_release(ctx)
	thread_context_select(ctx)
	ctx.engine = parameters.engine
	lane_context_set(parameters.lane)

	engine := parameters.engine
	if engine == nil || engine.target_fps == 0 {
		return
	}

	time_accumulator: time.Duration = 0
	last_time := time.now()
	counter_per_step := engine.counter_per_sim_step
	step_count: u64 = 0

	for {
		exit_requested: u64 = 1 if sync.atomic_load(&engine.running) == 0 else 0
		lane_sync_u64(&exit_requested, 0)
		if exit_requested != 0 {
			break
		}

		if lane_index() == 0 {
			now := time.now()
			delta := time.since(last_time)
			last_time = now
			if delta > time.Second {
				delta = time.Second
			}
			time_accumulator += delta
			for counter_per_step > 0 && time_accumulator >= counter_per_step {
				time_accumulator -= counter_per_step
				step_count += 1
			}
		}

		lane_sync_u64(&step_count, 0)
		for step_index: u64 = 0; step_index < step_count; step_index += 1 {
			lane_sync()
			tick_axiom(engine)
			lane_sync()
		}
		step_count = 0
	}
}

init_axiom :: proc(parameters: Axiom_Init_Parameters) -> ^Axiom_Engine {
	if parameters.target_fps == 0 {
		return nil
	}

	arena := new(mem_virtual.Arena)
	if arena == nil || mem_virtual.arena_init_growing(arena, 32 * mem.Gigabyte) != nil {
		return nil
	}

	engine, err := mem_virtual.new(arena, Axiom_Engine)
	if err != nil {
		mem_virtual.arena_destroy(arena)
		free(rawptr(arena))
		return nil
	}
	engine.arena = arena
	engine.target_fps = parameters.target_fps
	engine.delta_time = 1.0 / f32(parameters.target_fps)
	engine.counter_per_sim_step = time.Second / time.Duration(parameters.target_fps)
	engine.last_time = time.now()
	engine.initialized = true
	sync.atomic_store(&engine.running, 1)

	engine.engine_memory_table, err = mem_virtual.new(arena, Memory_Region_Table)
	if err != nil || !memory_region_table_init(engine.engine_memory_table) {
		return nil
	}
	engine.engine_memory_region = memory_region_push_subregion(
		engine.engine_memory_table,
		"EngineData",
		32 * mem.Gigabyte,
	)
	engine.simulation_state_region = memory_region_push_subregion(
		engine.engine_memory_table,
		"SimulationData",
		32 * mem.Gigabyte,
	)

	engine.entity_system_region = memory_region_push_subregion(
		engine.engine_memory_table,
		"EntitySystem",
		32 * mem.Gigabyte,
	)

	if engine.engine_memory_region == nil ||
	   engine.simulation_state_region == nil ||
	   engine.entity_system_region == nil {
		return nil
	}

	_, _ = memory_region_push_struct(Simulation_State, engine.simulation_state_region)
	_ = make_entity_system(engine)
	if state := get_simulation_state(engine); state != nil {
		state.time_step = engine.delta_time
	}
	engine.systems.allocator = mem_virtual.arena_allocator(engine.arena)

	initialize_axiom_components(engine)
	// TODO(Nacho): palyer generated content also gets init here


	// sort by tick group, then by name, dupe names are not allowed
	slice.sort_by(engine.systems[:], proc(a, b: Entity_System) -> bool {
		if a.configuration.tick_group != b.configuration.tick_group {
			return a.configuration.tick_group < b.configuration.tick_group
		}

		return a.name < b.name
	})

	system_core_count := os.get_processor_core_count()
	if system_core_count < 1 {
		system_core_count = 1
	}
	requested_core_count := parameters.max_axiom_cores
	if requested_core_count == 0 {
		requested_core_count = 1
	}
	engine.game_thread_count = min(requested_core_count, u32(system_core_count))
	if engine.game_thread_count == 0 {
		engine.game_thread_count = 1
	}

	thread_parameters: []Axiom_Thread_Parameters
	thread_parameters, err = mem_virtual.make(
		arena,
		[]Axiom_Thread_Parameters,
		int(engine.game_thread_count),
	)
	if err != nil {
		return nil
	}
	engine.game_threads, err = mem_virtual.make(
		arena,
		[]^thread.Thread,
		int(engine.game_thread_count),
	)
	if err != nil {
		return nil
	}
	sync.barrier_init(&engine.game_barrier, int(engine.game_thread_count))
	for lane_index in 0 ..< engine.game_thread_count {
		thread_parameters[lane_index] = {
			engine = engine,
			lane = {
				lane_index = u64(lane_index),
				lane_count = u64(engine.game_thread_count),
				barrier = &engine.game_barrier,
				broadcast_memory = &engine.lane_broadcast_memory,
			},
		}
		engine.game_threads[lane_index] = thread.create_and_start_with_data(
			rawptr(&thread_parameters[lane_index]),
			axiom_thread_entry,
			self_cleanup = false,
		)
		if engine.game_threads[lane_index] == nil {
			sync.atomic_store(&engine.running, 0)
			for previous in 0 ..< lane_index {
				if engine.game_threads[previous] != nil {
					thread.destroy(engine.game_threads[previous])
				}
			}
			return nil
		}
	}

	return engine
}

stop_axiom :: proc(engine: ^Axiom_Engine) {
	if engine == nil {
		return
	}
	sync.atomic_store(&engine.running, 0)
	for worker in engine.game_threads {
		if worker != nil {
			thread.destroy(worker)
		}
	}
	engine.game_threads = nil
}
