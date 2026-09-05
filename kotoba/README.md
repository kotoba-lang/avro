# Kotoba v1 — Avro Object Container File identification

This directory is a first-class language tree on the `kotoba-lang/avro`
fork, next to `lang/c`, `lang/c++`, `lang/java`, and the other SDK trees.
It is **not** part of apache/avro upstream.

## Honest scope

Kotoba binding **v1** identifies only:

- the Object Container File magic `Obj` (bytes 0-2)
- the one-byte version that follows (byte 3)

from the vendored fixture `fixtures/tiny-header.avro`.

Those four bytes match `DataFileConstants.MAGIC` in the Java SDK and the
C writer's `"Obj"` plus `version = 1`. This tree does **not** parse the
JSON schema, codec name, sync marker, or data blocks. It has no writer
and no reader engine. It does not FFI into C, C++, or Java.

This is **not** a replacement for those SDKs. It is **not robotics-ready**.

The fixture is only the identification prefix. It is not a complete
Object Container File.

## Language constraints

- Kotoba CLI **0.7.2**
- `kotoba compile --target wasm` → `wasm32-kotoba-v1`
- value profile **i64-v1** (no IEEE floats)
- no FFI / no host imports
- no vector/map ABI

`avro.kotoba` embeds the fixture as integer bytes and uses only `if`,
`=`, `and`, and the version byte. `main` returns the version when magic
is `Obj`, otherwise 0.

## Checks

`checks.sh` compiles with Kotoba 0.7.2, parses the compile JSON, rejects
a wasm import section, runs the one fixture, and asserts the header
fields against the fixture bytes. A local run is not CI.

```sh
# requires Linux amd64, or KOTOBA pointing at a 0.7.2 CLI
./checks.sh
```

## Operator

awai.network / Ryo Awai
