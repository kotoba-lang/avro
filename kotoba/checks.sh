#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Compile avro.kotoba with Kotoba 0.7.2 (wasm32, i64-v1) and assert
# Object Container File identification fields against the vendored fixture.
# Fail closed. A local run is not CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${ROOT}/fixtures/tiny-header.avro"
SRC="${ROOT}/avro.kotoba"
KOTOBA_VERSION="0.7.2"
KOTOBA_TARBALL="kotoba-linux-amd64.tar.gz"
# sha256 of https://github.com/kotoba-lang/kotoba/releases/download/v0.7.2/kotoba-linux-amd64.tar.gz
KOTOBA_SHA256="95e225461e1b8a21849b251e8c8b654693d2c8a516b258532771651e978e1977"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-avro-v1.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

fail() {
  printf 'kotoba/checks.sh: %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required"

if [[ -n "${KOTOBA:-}" ]]; then
  KOTOBA_BIN="${KOTOBA}"
  [[ -f "${KOTOBA_BIN}" && -x "${KOTOBA_BIN}" && ! -d "${KOTOBA_BIN}" ]] \
    || fail "KOTOBA=${KOTOBA_BIN} is not an executable file"
elif command -v kotoba >/dev/null 2>&1; then
  KOTOBA_BIN="$(command -v kotoba)"
  if [[ -d "${KOTOBA_BIN}" ]]; then
    fail "kotoba on PATH resolved to a directory, not the 0.7.2 CLI"
  fi
  CURRENT_LINK="${KOTOBA_HOME:-$HOME/.local/share/kotoba}/current"
  if [[ -L "${CURRENT_LINK}" ]]; then
    INSTALLED="$(readlink "${CURRENT_LINK}")"
    printf 'kotoba install current: %s\n' "${INSTALLED}"
    if [[ "${INSTALLED}" != "v0.7.2" ]]; then
      fail "refusing kotoba ${INSTALLED} (need v0.7.2)"
    fi
  fi
else
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  if [[ "${uname_s}" != "Linux" || "${uname_m}" != "x86_64" ]]; then
    fail "no KOTOBA set; automatic install is linux-amd64 only (this host is ${uname_s}/${uname_m})"
  fi
  cache="${ROOT}/.kotoba-cli/${KOTOBA_VERSION}"
  mkdir -p "${cache}"
  archive="${cache}/${KOTOBA_TARBALL}"
  if [[ ! -x "${cache}/kotoba" ]]; then
    url="https://github.com/kotoba-lang/kotoba/releases/download/v${KOTOBA_VERSION}/${KOTOBA_TARBALL}"
    printf 'downloading Kotoba %s from %s\n' "${KOTOBA_VERSION}" "${url}"
    curl -fsSL -o "${archive}" "${url}"
    got="$(sha256sum "${archive}" | awk '{print $1}')"
    if [[ "${got}" != "${KOTOBA_SHA256}" ]]; then
      fail "checksum mismatch for ${KOTOBA_TARBALL}: got ${got} expected ${KOTOBA_SHA256}"
    fi
    tar -xzf "${archive}" -C "${cache}" kotoba
  fi
  KOTOBA_BIN="${cache}/kotoba"
  [[ -x "${KOTOBA_BIN}" ]] || fail "extracted kotoba binary missing"
fi

printf 'kotoba binary: %s\n' "${KOTOBA_BIN}"

[[ -f "${FIXTURE}" ]] || fail "missing fixture ${FIXTURE}"
[[ -f "${SRC}" ]] || fail "missing module ${SRC}"

# Independent field read from the fixture. These numbers come from the
# file bytes, not from the .kotoba source.
FIELDS="${WORKDIR}/fields.env"
set +e
python3 - "${FIXTURE}" "${SRC}" >"${FIELDS}" 2>"${WORKDIR}/fields.err" <<'PY'
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
src = Path(sys.argv[2]).read_text()
raw = fixture.read_bytes()
if len(raw) != 4:
    print("fixture must be exactly the 4-byte OCF identification prefix", file=sys.stderr)
    sys.exit(1)
if raw[:3] != b"Obj":
    print("fixture does not start with Obj magic", file=sys.stderr)
    sys.exit(1)
for i, b in enumerate(raw):
    needle = f"(= i {i}) {b}"
    if needle not in src:
        print(f"avro.kotoba is missing fixture byte {i} = {b}", file=sys.stderr)
        sys.exit(1)
version = raw[3]
print(f"FIXTURE_LEN={len(raw)}")
print(f"FIELD_MAGIC=Obj")
print(f"FIELD_VERSION={version}")
print(f"FIELD_EXPECT={version}")
PY
fields_rc=$?
set -e
if [[ "${fields_rc}" -ne 0 ]]; then
  cat "${WORKDIR}/fields.err" >&2 || true
  fail "fixture field read failed"
fi
# shellcheck disable=SC1090
. "${FIELDS}"

printf 'fixture: %s (%s bytes)\n' "${FIXTURE}" "${FIXTURE_LEN}"
printf 'fixture fields: magic=%s version=%s\n' "${FIELD_MAGIC}" "${FIELD_VERSION}"

COMPILE_JSON="${WORKDIR}/compile.json"
WASM="${WORKDIR}/avro.wasm"
set +e
"${KOTOBA_BIN}" compile "${SRC}" --target wasm -o "${WASM}" --json >"${COMPILE_JSON}" 2>"${WORKDIR}/compile.err"
compile_rc=$?
set -e
if [[ "${compile_rc}" -ne 0 ]]; then
  cat "${COMPILE_JSON}" "${WORKDIR}/compile.err" >&2 || true
  fail "kotoba compile failed (exit ${compile_rc})"
fi

python3 - "${COMPILE_JSON}" "${WASM}" <<'PY'
import json
import sys
from pathlib import Path

WASM_IMPORT_SECTION = 2


def read_uleb128(buf, i):
    shift = 0
    value = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated uleb128")
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, i
        shift += 7
        if shift > 35:
            raise ValueError("uleb128 too long")


def wasm_import_section(buf):
    if buf[:4] != b"\x00asm":
        raise ValueError("artifact magic %r is not wasm" % (buf[:4],))
    if len(buf) < 8:
        raise ValueError("truncated wasm header")
    i = 8
    found = False
    import_count = None
    while i < len(buf):
        section_id = buf[i]
        i += 1
        size, i = read_uleb128(buf, i)
        end = i + size
        if end > len(buf):
            raise ValueError("truncated wasm section")
        payload = buf[i:end]
        i = end
        if section_id == WASM_IMPORT_SECTION:
            found = True
            import_count, _ = read_uleb128(payload, 0) if payload else (0, 0)
    return found, import_count


# Fail closed on the checker itself before trusting the artifact.
_no_import = b"\x00asm\x01\x00\x00\x00"
_empty_import = b"\x00asm\x01\x00\x00\x00\x02\x01\x00"
if wasm_import_section(_no_import) != (False, None):
    sys.exit("import-section checker failed on a no-section wasm")
if wasm_import_section(_empty_import) != (True, 0):
    sys.exit("import-section checker failed to see an import section")

report_text = Path(sys.argv[1]).read_text()
try:
    report = json.loads(report_text)
except json.JSONDecodeError:
    sys.exit("compile --json was not JSON:\n%s" % report_text)
wasm = Path(sys.argv[2])
if report.get("kotoba.cli/ok?") is not True:
    sys.exit("compile JSON kotoba.cli/ok? is %r" % (report.get("kotoba.cli/ok?"),))
if report.get("kotoba.cli/code") != "emitted":
    sys.exit("compile JSON kotoba.cli/code is %r, expected emitted" % (report.get("kotoba.cli/code"),))
data = report.get("kotoba.cli/data") or {}
profile = data.get("value-profile")
compat = data.get("compatibility") or {}
target = compat.get("target")
features = data.get("wasm-features") or []
if profile != "i64-v1":
    sys.exit("value-profile %r is not i64-v1" % (profile,))
if target != "wasm32-kotoba-v1":
    sys.exit("target %r is not wasm32-kotoba-v1" % (target,))
blocked = [f for f in features if f in ("simd", "floats", "float", "nontrapping-fptoint")]
if blocked:
    sys.exit("unexpected floating/SIMD wasm features: %s" % (blocked,))
if not wasm.is_file() or wasm.stat().st_size == 0:
    sys.exit("compile did not write a wasm artifact")
raw = wasm.read_bytes()
has_imports, import_count = wasm_import_section(raw)
if has_imports:
    sys.exit("wasm has import section (count=%s); FFI is out of v1 scope" % (import_count,))
print("compile JSON: ok?=true code=emitted value-profile=i64-v1 target=wasm32-kotoba-v1 import-section=absent")
PY

# Prefer kotoba run (observed integer :kotoba.runtime/value). Node wasm
# instantiate is a fallback only if the CLI run path is unavailable.
set +e
"${KOTOBA_BIN}" run "${SRC}" >"${WORKDIR}/run.out" 2>"${WORKDIR}/run.err"
run_rc=$?
set -e

GOT=""
if [[ "${run_rc}" -eq 0 ]]; then
  GOT="$(python3 - "${WORKDIR}/run.out" "${WORKDIR}/run.err" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text() + "\n" + Path(sys.argv[2]).read_text()
if ":kotoba.runtime/ok? true" not in text:
    sys.exit("kotoba run produced no :kotoba.runtime/ok? true")
match = re.search(r":kotoba.runtime/value (-?\d+)", text)
if match is None:
    sys.exit("kotoba run produced no integer :kotoba.runtime/value")
print(match.group(1))
PY
)" || GOT=""
fi

if [[ -z "${GOT}" ]]; then
  command -v node >/dev/null 2>&1 || fail "kotoba run did not yield a value and node is not available to instantiate wasm"
  printf 'kotoba run did not yield :kotoba.runtime/value; instantiating wasm with node\n'
  GOT="$(node --input-type=module - "${WASM}" <<'JS'
import fs from "node:fs";
const wasm = fs.readFileSync(process.argv[2]);
const { instance } = await WebAssembly.instantiate(wasm);
if (!instance.exports.main) {
  throw new Error("wasm module has no exported main");
}
const value = instance.exports.main();
const n = typeof value === "bigint" ? value : BigInt(value);
process.stdout.write(n.toString());
JS
)"
fi

printf 'module returned: %s\n' "${GOT}"
if [[ "${GOT}" != "${FIELD_EXPECT}" ]]; then
  fail "version ${GOT} != fixture-derived ${FIELD_EXPECT}"
fi

printf 'kotoba/checks.sh: compile i64-v1 wasm32 and fixture header fields matched\n'
printf 'kotoba/checks.sh: asserted magic=Obj version=%s (local run is not CI)\n' "${FIELD_VERSION}"
