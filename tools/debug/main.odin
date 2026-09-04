package main

import axiom "axiom:src"
import "core:os"
import "core:time"

main :: proc() {
	engine := axiom.init_axiom({max_axiom_cores = 1, target_fps = 60})
	if engine == nil {
		os.exit(1)
	}

	time.sleep(10 * time.Second)
	axiom.stop_axiom(engine)
}
