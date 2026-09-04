package axiom

import "core:mem"

AXIOM_MAX_U32 :: u32(0xffff_ffff)

AXIOM_DEFAULT_ARENA_RESERVE :: 64 * mem.Megabyte
AXIOM_DEFAULT_ARENA_COMMIT :: 64 * mem.Kilobyte

ENTITY_INDEX_BITS :: 22
ENTITY_INDEX_MASK :: (u32(1) << ENTITY_INDEX_BITS) - 1
MAX_ENTITIES :: AXIOM_MAX_U32 & ENTITY_INDEX_MASK

DEFAULT_PREALLOCATED_COMPONENTS :: 100

// range_from_lane is the existing even subdivision used by the engine lanes.
range_from_lane :: proc(lane_index, lane_count, count: u64) -> (start, end: u64) {
	if lane_count == 0 {
		return 0, 0
	}

	main_count := count / lane_count
	leftover_count := count - main_count * lane_count
	leftover_before := min(lane_index, leftover_count)
	lane_start := lane_index * main_count + leftover_before
	lane_start = min(lane_start, count)
	lane_end := lane_start + main_count + (1 if lane_index < leftover_count else 0)
	lane_end = min(lane_end, count)
	return lane_start, lane_end
}

lane_from_task_index :: proc(task_index, lane_count: u64) -> u64 {
	return task_index % lane_count if lane_count != 0 else 0
}
