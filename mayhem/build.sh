#!/usr/bin/env bash
#
# mayhem/build.sh — build w3m's fuzz harnesses (OSS-Fuzz's original `fuzz_conv`, from the upstream
# fuzz/fuzz-conv.c; plus three targets added for wider coverage — `fuzz_checktype`, `fuzz_url`,
# `fuzz_parsetag`, each in mayhem/fuzz-*.c with a comment on what it exercises and why) and w3m's own
# functional test suite (tests/run_tests).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract: CC, CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS
# (ASan+UBSan, halting), DEBUG_FLAGS, STANDALONE_FUZZ_MAIN, SRC=/mayhem.
#
# What gets built (two independent, out-of-source copies of the whole tree under $BUILD_ROOT, so
# /mayhem itself — the grader's diff target — stays a clean, unbuilt source checkout):
#   (1) A SANITIZED, minimal-feature `./configure && make w3m` — the `w3m` MAKE TARGET (not just the
#       harness's direct dependency chain), instrumented with $SANITIZER_FLAGS + $DEBUG_FLAGS
#       (DWARF 3) + libFuzzer coverage. `make w3m` alone (not the default `all`) builds exactly
#       $(OBJS)+$(LOBJS)+$(LLOBJS) (every module the real `w3m` binary links) plus libwc/libwc.a —
#       and deliberately skips the OTHER top-level targets (w3mbookmark, w3mhelperpanel, inflate),
#       each of which brings its own conflicting `main()`. Every harness then links against the same
#       shared object set (every module `w3m` links, minus main.o, which defines main() — each
#       harness supplies its own entry point instead), so adding a 5th target later is "add a
#       fuzz/*.c file + a build_harness call", not "work out a new subset of objects by hand". The
#       four harnesses are each linked TWICE: against $LIB_FUZZING_ENGINE -> /mayhem/<name> (the
#       Mayhem target) and against $STANDALONE_FUZZ_MAIN -> /mayhem/<name>-standalone (run-once
#       reproducer, no libFuzzer).
#   (2) A NORMAL-flags (non-sanitized) full `./configure && make` build producing the real `w3m`
#       binary, which mayhem/test.sh only RUNS via tests/run_tests (it never compiles). Keeping the
#       oracle build clean of sanitizer/fuzzer flags keeps it an honest functional oracle for PATCH
#       grading.
#
# w3m specifics:
#   * Autotools (`./configure && make`), in-tree — so each build gets its OWN copy of the source
#     under $BUILD_ROOT (never build in /mayhem itself).
#   * Neither the functional-test build nor any of the four harnesses need w3m's network/image/
#     terminal-mouse features (tests/run_tests only feeds HTML through `w3m -T text/html`; the
#     harnesses call into the charset/line-property/URL/tag-parsing layers directly) — so both
#     builds disable everything that would otherwise pull in optional libraries the base image
#     doesn't ship (SSL, imlib2, migemo, X11/mouse). `--with-termlib=ncurses` is still required: the
#     `w3m` binary always links a terminal library.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with parameter-expansion fallbacks.
# SANITIZER_FLAGS uses `=` (not `:=`) on purpose: an explicitly EMPTY value (--build-arg
# SANITIZER_FLAGS=) is honored and builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# Out-of-source build trees (kept OUT of /mayhem so the checked-out source tree stays clean — the
# grader diffs it). mayhem/test.sh derives the same default for the oracle build.
BUILD_ROOT="${MAYHEM_BUILD_ROOT:-${HOME:-/tmp}/mayhem-build}"
mkdir -p "$BUILD_ROOT"

# Feature set common to both builds: only what tests/run_tests + the harnesses actually exercise
# (charset conversion, line-property/backspace handling, URL parsing, HTML tag parsing — none of it
# network/image/terminal-mouse). Disabling the rest keeps the build offline/air-gapped — no
# SSL/imlib2/migemo/X11 probing — and re-runnable without network access (§6.5).
CONFIGURE_FLAGS=(
  --disable-nls --disable-cookie --disable-nntp --disable-gopher --without-ssl
  --disable-image --disable-mouse --disable-menu --disable-alarm --disable-w3mmailer
  --disable-external-uri-loader --disable-dict --with-termlib=ncurses
)

# libFuzzer coverage instrumentation for the PROJECT objects (so the fuzzer sees w3m's own edges,
# not just the harness). Tied to the sanitizer switch: with SANITIZER_FLAGS explicitly empty there is
# no sanitizer runtime to provide the __sanitizer_cov_* hooks the standalone reproducer would need,
# and that off-switch exists precisely to get a plain, natural-crash binary.
FUZZ_COV="-fsanitize=fuzzer-no-link"
[ -n "$SANITIZER_FLAGS" ] || FUZZ_COV=""

# ==================================================================================================
# (1) SANITIZED build: every module `w3m` links (minus main.o) + libwc/libwc.a, then all 4 harnesses
# ==================================================================================================
SAN_DIR="$BUILD_ROOT/w3m-san"
rm -rf "$SAN_DIR"
cp -a "$SRC" "$SAN_DIR"
cd "$SAN_DIR"

SAN_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV"
echo "build.sh: (1a) sanitized ./configure (minimal feature set)"
CC="$CC" CFLAGS="$SAN_CFLAGS" ./configure "${CONFIGURE_FLAGS[@]}"

echo "build.sh: (1b) make w3m (every linked module + libwc/libwc.a; skips the other mini-tools so
      their conflicting main()s never land in this build tree)"
make -j"$MAYHEM_JOBS" w3m

[ -f libwc/libwc.a ] || { echo "build.sh: expected lib missing: $SAN_DIR/libwc/libwc.a" >&2; exit 1; }

# Every top-level .o EXCEPT main.o (which defines main() — each harness supplies its own instead).
# Globbed rather than hand-copied from Makefile.in's $(OBJS)/$(LOBJS)/$(LLOBJS)/$(KEYBIND_OBJ) so
# this never drifts if upstream adds/renames/reconfigures a source file; `make w3m` already limited
# what got compiled to exactly this binary's dependency closure (see above), so the glob is safe.
# main.c is more than an entry point: fm.h's `global ... init(...)` idiom defines every w3m global
# (TrapSignal, UserAgent, SystemCharset, ...) only in the ONE translation unit that #define
# MAINPROGRAM's before #include "fm.h" (main.c's own first two lines), and main.c also implements
# dozens of ordinary command functions (quitfm, nulcmd, wrapToggle, ...) that func.c's static
# w3mFuncList[] dispatch table references by address. A harness needs both, but must NOT bring in
# main.c's actual `main()` — that collides with libFuzzer's/the standalone driver's own entry point.
# Recompile main.c with its `main` symbol renamed via the preprocessor (a plain, unmangled `main(int
# argc, char **argv)` definition — confirmed there is exactly one `main` token in the file, so
# -Dmain=... can't misfire on some unrelated identifier) through the Makefile's OWN implicit rule
# (CPPFLAGS is make-invocation-time-overridable per Makefile.in's `CFLAGS = ... $(CPPFLAGS) $(DEFS)
# ...`), so it picks up the exact same $(DEFS) path macros (-DETC_DIR=..., -DAUXBIN_DIR=..., ...)
# every other object gets — a hand-rolled clang invocation for just this file silently drops those
# and fails to parse main.c's own path-macro initializers.
rm -f main.o
make -B CPPFLAGS="-Dmain=w3m_disabled_main" main.o
mv main.o main_noentry.o

# Excluded besides main.o: `make w3m`'s prerequisite chain (regenerating funcname*.h, entity.h,
# tagtable.c, ...) incidentally compiles a few objects that are NOT part of the w3m binary itself —
# dummy.o + mktable.o's own `main()` collide with the harness's entry point (dummy.o additionally
# redefines conv_entity() as a stub for the mini-tools below); w3mbookmark.o/w3mhelperpanel.o/
# inflate.o/w3mimgdisplay.o are OTHER top-level mini-tool mains ($(BOOKMARKER)/$(HELPER)/$(INFLATE)/
# $(IMGDISPLAY) targets, never part of $(TARGET)=w3m's own $(ALLOBJS)).
mapfile -t PROJECT_OBJS < <(find . -maxdepth 1 -name '*.o' \
    ! -name main.o ! -name dummy.o ! -name mktable.o \
    ! -name w3mbookmark.o ! -name w3mhelperpanel.o ! -name inflate.o ! -name w3mimgdisplay.o \
  | sort)
[ "${#PROJECT_OBJS[@]}" -ge 20 ] || {
  echo "build.sh: only ${#PROJECT_OBJS[@]} project objects after 'make w3m' — build didn't complete?" >&2
  exit 1
}

INCS="-I. -Ilibwc -DHAVE_CONFIG_H -DUSE_UNICODE"

echo "build.sh: (1c) harnesses: fuzz_conv fuzz_checktype fuzz_url fuzz_parsetag (+ standalone reproducers)"
LINK_LIBS=(libwc/libwc.a -lgc -lncurses -lm)

build_harness() {
  local name="$1" src="$2"
  # The standalone driver and every harness here are plain C, so both link straight through $CC (no
  # separate C++-linkage step needed — that only matters for a C++ harness compiled with clang++).
  "$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV $INCS $LIB_FUZZING_ENGINE \
      "$src" "${PROJECT_OBJS[@]}" "${LINK_LIBS[@]}" -o "/mayhem/$name"
  "$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV $INCS \
      "$src" "$STANDALONE_FUZZ_MAIN" "${PROJECT_OBJS[@]}" "${LINK_LIBS[@]}" -o "/mayhem/$name-standalone"
}

build_harness fuzz_conv      fuzz/fuzz-conv.c
build_harness fuzz_checktype mayhem/fuzz-checktype.c
build_harness fuzz_url       mayhem/fuzz-url.c
build_harness fuzz_parsetag  mayhem/fuzz-parsetag.c

# ==================================================================================================
# (2) NORMAL-flags full build (the PATCH oracle; test.sh RUNS tests/run_tests against it)
# ==================================================================================================
TEST_DIR="$BUILD_ROOT/w3m-test"
rm -rf "$TEST_DIR"
cp -a "$SRC" "$TEST_DIR"
cd "$TEST_DIR"

echo "build.sh: (2) normal-flags full w3m build"
CC="$CC" CFLAGS="$COVERAGE_FLAGS" ./configure "${CONFIGURE_FLAGS[@]}"
make -j"$MAYHEM_JOBS"

[ -x "$TEST_DIR/w3m" ] || { echo "build.sh: test binary missing: $TEST_DIR/w3m" >&2; exit 1; }

echo "build.sh: built /mayhem/{fuzz_conv,fuzz_checktype,fuzz_url,fuzz_parsetag} (+ -standalone reproducers); test binary in $TEST_DIR/w3m"
