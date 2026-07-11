#!/usr/bin/env bash
#
# rapidjson/mayhem/build.sh — build the OSS-Fuzz rapidjson harness as a sanitized libFuzzer target
# (+ a standalone run-once reproducer) against rapidjson's header-only parser.
#
# The fuzzed surface is rapidjson's JSON PARSER + PrettyWriter round-trip. The harness parses the
# raw input bytes (as a NUL-terminated string) into a rapidjson::Document four times, once per
# parse-flag set, and re-serialises accepted documents:
#   fuzzer — drives Document::Parse<flags>() for kParseDefaultFlags, kParseFullPrecisionFlag,
#            kParseNumbersAsStringsFlag and kParseCommentsFlag, then Accept(PrettyWriter).
# rapidjson is HEADER-ONLY: there is no library to compile — the parser code is instrumented because
# it is #included into the (sanitised) harness translation unit. We compile WITH $SANITIZER_FLAGS so
# the parser itself is covered, and -D_GLIBCXX_DEBUG as OSS-Fuzz does to catch libstdc++ misuse.
#
# Build contract comes from the org base ENV (CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). One libFuzzer binary + one standalone binary, both into /mayhem.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS OUT

cd "$SRC"

HARNESS="$SRC/mayhem/harnesses/fuzzer.cpp"
INC="-I$SRC/include"
# OSS-Fuzz compiles the harness with these; -std=c++17 per the integration contract.
CXXFLAGS_COMMON="-std=c++17 -pthread -D_GLIBCXX_DEBUG"

# ── 1) libFuzzer target -> $OUT/fuzzer ────────────────────────────────────────────────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_COMMON $INC \
    "$HARNESS" $LIB_FUZZING_ENGINE \
    -o "$OUT/fuzzer"

# ── 2) standalone run-once reproducer -> $OUT/fuzzer-standalone ─────────────────────────────────────
# Compile LLVM's standalone driver as a C object first ($CC) so its extern "C" LLVMFuzzerTestOneInput
# reference matches the harness's C-linkage definition, then link with the C++ harness.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_COMMON $INC \
    /tmp/standalone_main.o "$HARNESS" \
    -o "$OUT/fuzzer-standalone"

echo "build.sh complete:"
ls -la "$OUT/fuzzer" "$OUT/fuzzer-standalone" 2>&1 || true
