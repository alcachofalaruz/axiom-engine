package axiom

@(axiom_system)
bullet_movement :: proc(transform: ^Component_Transform) {
	transform.x += 5
}
