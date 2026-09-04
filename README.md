# Axiom Engine

A hobby game engine written in Odin. It's a work in progress; the core
systems and APIs are still moving around.

## Goals

Axiom is headless. It simulates, and that's all: no renderer, no window, no
asset pipeline. Whatever embeds the engine decides how the world gets drawn.

Simulation and system execution are built around multiple cores from the
start, rather than threaded in after the fact.

The long-term target is deterministic rollback netcode. Same starting state
and same inputs should give the same result every time, which is what lets
earlier ticks be restored and simulated again when a network input arrives
late.

That last part isn't done yet. What works today: a fixed-step simulation loop,
lane threading, memory regions, entity and component scaffolding, metadata
generation, and a Box3D physics adapter.

## Layout

```
src/                Odin engine package
src/meta/           .axmeta schemas
tools/metagen/       Odin metadata generator
lib/box3d/           Box3D dependency
```

Generated Odin files under `src/` are gitignored, and `generate.sh` or
`build.sh` recreate them. To change one, edit the schema or the generator
rather than the output.

Everything else comes from Odin's core library: virtual arenas,
synchronization, threading, time, files, and strings.

## Build

Install Odin and CMake, initialize the Box3D submodule, then:

```sh
git submodule update --init lib/box3d
./generate.sh
./build.sh
```

`build.sh` takes `debug` (the default) or `release`, and writes the static and
shared libraries to `build/axiom.a` and `build/axiom.so`. Box3D gets built
under `build/box3d` if its archive isn't there already.

## Tests

Plain `core:testing`:

```sh
./run_tests.sh
```

## License

zlib. See [LICENSE.md](LICENSE.md). Third-party code keeps its own licenses,
listed in the [third-party notices](THIRD_PARTY_LICENSES.md).
