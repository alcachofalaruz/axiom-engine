package axiom

import "core:testing"

@(test)
test_fixed_point :: proc(t: ^testing.T) {
	one := fp_16_16_from_int(1)
	two := fp_16_16_from_int(2)

	testing.expect_value(t, fp_16_16_to_int(fp_16_16_add(one, two)), i32(3))
	testing.expect_value(t, fp_16_16_to_int(fp_16_16_mul(two, two)), i32(4))
	testing.expect_value(t, fp_16_16_to_int(fp_16_16_div(two, two)), i32(1))
	testing.expect_value(t, fp_16_16_div(one, {}).raw, FP_16_16_MAX_RAW)
}

@(test)
test_generated_names_use_odin_case :: proc(t: ^testing.T) {
	velocity := Component_Something_Velocity {
		something = 7,
	}
	testing.expect_value(t, velocity.something, i32(7))
}

@(test)
test_lane_ranges :: proc(t: ^testing.T) {
	start, end := range_from_lane(0, 3, 8)
	testing.expect_value(t, start, u64(0))
	testing.expect_value(t, end, u64(3))

	start, end = range_from_lane(1, 3, 8)
	testing.expect_value(t, start, u64(3))
	testing.expect_value(t, end, u64(6))

	start, end = range_from_lane(2, 3, 8)
	testing.expect_value(t, start, u64(6))
	testing.expect_value(t, end, u64(8))
}
