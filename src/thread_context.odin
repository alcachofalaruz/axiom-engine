package axiom

import "core:mem"
import vmem "core:mem/virtual"
import "core:sync"

Lane_Context :: struct {
	lane_index:       u64,
	lane_count:       u64,
	barrier:          ^sync.Barrier,
	broadcast_memory: ^u64,
}

Thread_Context :: struct {
	arenas:           [2]^vmem.Arena,
	frame_arena:      ^vmem.Arena,
	thread_name:      [32]u8,
	thread_name_size: u64,
	lane:             Lane_Context,
	engine:           ^Axiom_Engine,
}

@(thread_local)
selected_thread_context: ^Thread_Context

thread_context_alloc :: proc() -> ^Thread_Context {
	ctx := new(Thread_Context)
	if ctx == nil {
		return nil
	}

	for index in 0 ..< len(ctx.arenas) {
		arena := new(vmem.Arena)
		ctx.arenas[index] = arena
		if arena == nil || vmem.arena_init_growing(arena, AXIOM_DEFAULT_ARENA_RESERVE) != nil {
			thread_context_release(ctx)
			return nil
		}
	}

	ctx.frame_arena = new(vmem.Arena)
	if ctx.frame_arena == nil ||
	   vmem.arena_init_growing(ctx.frame_arena, AXIOM_DEFAULT_ARENA_RESERVE) != nil {
		thread_context_release(ctx)
		return nil
	}
	ctx.lane.lane_count = 1
	return ctx
}

thread_context_release :: proc(ctx: ^Thread_Context) {
	if ctx == nil {
		return
	}
	if ctx.frame_arena != nil {
		vmem.arena_destroy(ctx.frame_arena)
		free(rawptr(ctx.frame_arena))
	}
	for arena in ctx.arenas {
		if arena != nil {
			vmem.arena_destroy(arena)
			free(rawptr(arena))
		}
	}
	free(rawptr(ctx))
}

thread_context_select :: proc(ctx: ^Thread_Context) {
	selected_thread_context = ctx
}

thread_context_selected :: proc() -> ^Thread_Context {
	return selected_thread_context
}

thread_context_get_scratch :: proc(conflicts: []^vmem.Arena) -> ^vmem.Arena {
	ctx := thread_context_selected()
	if ctx == nil {
		return nil
	}

	for arena in ctx.arenas {
		conflicted := false
		for conflict in conflicts {
			if arena == conflict {
				conflicted = true
				break
			}
		}
		if !conflicted {
			return arena
		}
	}
	return nil
}

Scratch_Temp :: struct {
	arena: ^vmem.Arena,
	temp:  vmem.Arena_Temp,
}

thread_context_get_scratch_temp :: proc(conflicts: []^vmem.Arena) -> Scratch_Temp {
	arena := thread_context_get_scratch(conflicts)
	if arena == nil {
		return {}
	}
	return {arena = arena, temp = vmem.arena_temp_begin(arena)}
}

thread_context_release_scratch :: proc(temp: ^Scratch_Temp) {
	if temp != nil && temp.arena != nil {
		vmem.arena_temp_end(temp.temp)
		temp^ = {}
	}
}

lane_context_set :: proc(lane: Lane_Context) -> Lane_Context {
	ctx := thread_context_selected()
	if ctx == nil {
		return {}
	}
	previous := ctx.lane
	ctx.lane = lane
	return previous
}

lane_barrier_wait :: proc(broadcast: rawptr, broadcast_size, source_lane: u64) {
	ctx := thread_context_selected()
	if ctx == nil || ctx.lane.barrier == nil {
		return
	}

	size := min(broadcast_size, u64(size_of(u64)))
	if broadcast != nil && ctx.lane.lane_index == source_lane {
		mem.copy(rawptr(ctx.lane.broadcast_memory), broadcast, int(size))
	}

	_ = sync.barrier_wait(ctx.lane.barrier)

	if broadcast != nil && ctx.lane.lane_index != source_lane {
		mem.copy(broadcast, rawptr(ctx.lane.broadcast_memory), int(size))
	}

	if broadcast != nil {
		_ = sync.barrier_wait(ctx.lane.barrier)
	}
}

lane_sync :: proc() {
	lane_barrier_wait(nil, 0, 0)
}

lane_sync_u64 :: proc(value: ^u64, source_lane: u64) {
	lane_barrier_wait(rawptr(value), size_of(u64), source_lane)
}

lane_index :: proc() -> u64 {
	ctx := thread_context_selected()
	return ctx.lane.lane_index if ctx != nil else 0
}

lane_count :: proc() -> u64 {
	ctx := thread_context_selected()
	return ctx.lane.lane_count if ctx != nil else 1
}

lane_range :: proc(count: u64) -> (start, end: u64) {
	return range_from_lane(lane_index(), lane_count(), count)
}

set_thread_name :: proc(name: string) {
	ctx := thread_context_selected()
	if ctx == nil {
		return
	}

	size := min(len(name), len(ctx.thread_name))
	if size > 0 {
		mem.copy(rawptr(&ctx.thread_name[0]), rawptr(raw_data(name)), size)
	}
	ctx.thread_name_size = u64(size)
}
