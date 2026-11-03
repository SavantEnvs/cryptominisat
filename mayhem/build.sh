#!/usr/bin/env bash
# mayhem/build.sh — builds the sanitized CryptoMiniSat library + fuzz harness (and a standalone
# reproducer), and, separately with the project's normal flags, the gtest suite test.sh runs.
# Air-gapped: CaDiCaL/CaDiBaCk come from the pinned in-image copies under /opt/toolchains/deps.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${DEPS_DIR:=/opt/toolchains/deps}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# A re-run resolves the compiler differently (ccache masquerade at image build vs plain PATH) and CMake then
# drops its cache, losing the offline FetchContent settings; always configure from scratch.
rm -rf build/fuzz build/test

COMMON_CMAKE=(-G Ninja
  -DBUILD_SHARED_LIBS=OFF -DSTATIC_BINARY=OFF
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  -DFETCHCONTENT_SOURCE_DIR_CADICAL="$DEPS_DIR/cadical"
  -DFETCHCONTENT_SOURCE_DIR_CADIBACK="$DEPS_DIR/cadiback"
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX")

# 1) Sanitized library (the fuzzed code), DWARF 3.
cmake -S . -B build/fuzz "${COMMON_CMAKE[@]}" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
# Upstream's header-copy target is not a dependency of everything that includes those headers.
cmake --build build/fuzz --target CopyPublicHeaders_cryptominisat5
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target cryptominisat5 cadical cadiback

# 2) Harness: fuzzer binary + standalone reproducer, both linked with the same sanitized libs.
LIBS=("$SRC/build/fuzz/lib/libcryptominisat5.a"
      "$SRC/build/fuzz/_deps/cadiback-build/libcadiback.a"
      "$SRC/build/fuzz/_deps/cadical-build/libcadical.a"
      -lgmpxx -lgmp -lz -lpthread)
INC=(-I"$SRC/src" -I"$SRC/build/fuzz/include/cryptominisat5")
CXXF=(-std=c++20 -O1)

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${CXXF[@]}" -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${CXXF[@]}" "${INC[@]}" \
  "$SRC/mayhem/fuzz_cms_dimacs.cpp" /tmp/lsan_off.o "${LIBS[@]}" -o /mayhem/fuzz_cms_dimacs
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${CXXF[@]}" "${INC[@]}" \
  "$SRC/mayhem/fuzz_cms_dimacs.cpp" /tmp/standalone_main.o /tmp/lsan_off.o "${LIBS[@]}" \
  -o /mayhem/fuzz_cms_dimacs-standalone

# 3) Test suite with the project's normal flags (no sanitizers).
cmake -S . -B build/test "${COMMON_CMAKE[@]}" -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_C_FLAGS_RELEASE="-O2" -DCMAKE_CXX_FLAGS_RELEASE="-O2"   # no -DNDEBUG: the tests' assert()s must stay live
cmake --build build/test --target CopyPublicHeaders_cryptominisat5
cmake --build build/test -j"$MAYHEM_JOBS"
