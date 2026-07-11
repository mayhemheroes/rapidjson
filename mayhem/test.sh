#!/usr/bin/env bash
#
# rapidjson/mayhem/test.sh — build + RUN rapidjson's OWN gtest unit-test suite (test/unittest) with
# NORMAL flags and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: test/unittest is rapidjson's real ~30-file gtest suite (readertest, writertest,
# documenttest, schematest, valuetest, …). It asserts parse/serialise/round-trip correctness against
# golden JSON in bin/ (bin/jsonchecker, bin/data) — a no-op / "return success" patch to the parser
# cannot pass. We build it SEPARATELY with normal (non-sanitiser) flags into a clean tree so this
# script is an honest functional oracle, then run the single `unittest` binary and parse its gtest
# output. gtest source comes from /usr/src/gtest (libgtest-dev), found by FindGTestSrc.cmake with
# -DRAPIDJSON_BUILD_THIRDPARTY_GTEST=OFF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# ── build the unittest suite with NORMAL flags (clean, separate tree) ──────────────────────────────
# rapidjson (and the gtest source) build with -Werror; newer clang emits diagnostics rapidjson's
# CMake never anticipated (deprecated TypedTestCase, etc.). Rather than chase each one, neuter
# -Werror for the test build. rapidjson APPENDS "-Werror" to CMAKE_CXX_FLAGS itself, so our override
# must land LATER on the compile line: CMake emits CMAKE_CXX_FLAGS then CMAKE_CXX_FLAGS_<CONFIG>, so
# we stash -Wno-error there (Release build) where it wins. -Wno-unknown-warning-option tolerates any
# stale -W flag. This only downgrades warnings; it does not change test behaviour.
NO_ERROR="-Wno-error -Wno-unknown-warning-option"
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
     cmake -S "$SRC" -B "$BUILDDIR" \
       -DRAPIDJSON_BUILD_CXX17=ON \
       -DRAPIDJSON_BUILD_CXX11=OFF \
       -DRAPIDJSON_BUILD_THIRDPARTY_GTEST=OFF \
       -DRAPIDJSON_BUILD_DOC=OFF \
       -DRAPIDJSON_BUILD_EXAMPLES=OFF \
       -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG $NO_ERROR" >/tmp/rj-cmake.log 2>&1; then
  echo "cmake configure failed:" >&2; tail -30 /tmp/rj-cmake.log >&2
  emit_ctrf "rapidjson-unittest" 0 1 0; exit 2
fi
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
     cmake --build "$BUILDDIR" --target unittest -j"$MAYHEM_JOBS" >/tmp/rj-build.log 2>&1; then
  echo "unittest build failed:" >&2; tail -30 /tmp/rj-build.log >&2
  emit_ctrf "rapidjson-unittest" 0 1 0; exit 2
fi

UNITTEST="$BUILDDIR/bin/unittest"
[ -x "$UNITTEST" ] || UNITTEST="$(find "$BUILDDIR" -name unittest -type f -perm -u+x 2>/dev/null | head -1)"
if [ -z "${UNITTEST:-}" ] || [ ! -x "$UNITTEST" ]; then
  echo "unittest binary not found after build" >&2
  emit_ctrf "rapidjson-unittest" 0 1 0; exit 2
fi

# rapidjson's tests load golden JSON relative to bin/ (jsonchecker/*, data/*) — run from $SRC/bin.
echo "=== running rapidjson unittest ==="
out="$(cd "$SRC/bin" && "$UNITTEST" 2>&1)"; rc=$?
echo "$out"

# gtest summary lines: "[  PASSED  ] N tests." and "[  FAILED  ] N tests".
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*\[[[:space:]]*PASSED[[:space:]]*\][[:space:]]*\([0-9][0-9]*\) test.*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*\[[[:space:]]*FAILED[[:space:]]*\][[:space:]]*\([0-9][0-9]*\) test.*/\1/p' | tail -1)
: "${PASSED:=0}" "${FAILED:=0}"

# If gtest produced no parseable summary, fall back to the binary's exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse gtest summary; using unittest exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "rapidjson-unittest" 1 0 0; exit 0; }
  emit_ctrf "rapidjson-unittest" 0 1 0; exit 1
fi

# A nonzero exit with no parsed failures still means failure (e.g. a crash) — record at least one.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "rapidjson-unittest" "$PASSED" "$FAILED" 0
