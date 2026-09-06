package axiom

@(axiom_system)
bullet_movement :: proc(transform: ^Component_Transform) {
	transform.x += 5
}

@(axiom_system_config = bullet_movement)
bullet_movement_config :: proc(config: ^Entity_System_Configuration) {
	config.tick_group = .Pre_Physics
	system_after(config, "Bullet_Spawn")
}
