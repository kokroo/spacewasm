#!/usr/bin/env bash
#
# pgo.sh - Build a Profile-Guided Optimized (PGO) SpaceWasm interpreter binary.
#
# SpaceWasm is published as a `no_std` library, so PGO cannot be baked into the
# crates.io artifact (the consumer recompiles from source). This script instead
# produces a profile-optimized standalone interpreter binary
# (`target/release/spacewasm_std`) that an embedder can ship, using the standard
# three-stage LLVM PGO workflow trained on the in-repo CoreMark benchmark, which
# exercises the interpreter's hot dispatch loop:
#
#   1. Instrument + gather - build & run CoreMark with `-Cprofile-generate`,
#      producing `.profraw` execution profiles.
#   2. Merge               - fold the raw profiles into a single `.profdata`
#      with `llvm-profdata merge`.
#   3. Optimize            - rebuild the interpreter (and CoreMark, to report the
#      optimized score) with `-Cprofile-use`.
#
# PGO profiles are specific to the host toolchain and target triple; regenerate
# them for each deployment target rather than reusing a checked-in profile.
#
# Prerequisites: the `llvm-tools-preview` rustup component (ships llvm-profdata):
#   rustup component add llvm-tools-preview
#
# Usage:
#   scripts/pgo.sh [--compare] [--out <path>]
#
#   --compare      Also build & run a clean (non-PGO) release CoreMark first and
#                  report the baseline score next to the PGO score.
#   --out <path>   Copy the optimized `spacewasm_std` binary to <path>.
#   -h, --help     Show this help.

set -euo pipefail

# --- locate the repository root (script lives in <root>/scripts) -------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- parse arguments ---------------------------------------------------------
COMPARE=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --compare) COMPARE=1; shift ;;
    --out)
      if [ $# -lt 2 ]; then echo "error: --out requires a path" >&2; exit 2; fi
      OUT="$2"; shift 2 ;;
    -h|--help)
      # Print the leading comment block (skip the shebang, stop at the first
      # non-comment line), with the leading "# " stripped.
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# --- locate llvm-profdata from the active toolchain --------------------------
# `rustc --print target-libdir` resolves to <toolchain>/lib/rustlib/<triple>/lib;
# the llvm-tools binaries live in the sibling `bin` directory.
PROFDATA="$(rustc --print target-libdir)/../bin/llvm-profdata"
if [ ! -x "$PROFDATA" ]; then
  echo "error: llvm-profdata not found at $PROFDATA" >&2
  echo "       install the llvm-tools-preview component for this toolchain:" >&2
  echo "         rustup component add llvm-tools-preview" >&2
  exit 1
fi

BENCH_ARGS=(-p spacewasm_std --bench coremark --no-fail-fast)
BIN_ARGS=(--release -p spacewasm_std --bin spacewasm_std)

PGO_DIR="$ROOT/target/pgo"
PROFRAW_DIR="$PGO_DIR/profraw"
MERGED="$PGO_DIR/merged.profdata"

# Extract the "CoreMark Score: X.XXX" line from a captured build/run log.
score_from() { grep -m1 'CoreMark Score:' "$1" | awk '{print $3}'; }

BASELINE_SCORE=""

# --- optional baseline (clean release, no PGO) -------------------------------
if [ "$COMPARE" -eq 1 ]; then
  echo "==> [baseline] building & running CoreMark (release, no PGO)"
  baseline_log="$PGO_DIR/baseline.log"
  mkdir -p "$PGO_DIR"
  cargo bench "${BENCH_ARGS[@]}" 2>&1 | tee "$baseline_log"
  BASELINE_SCORE="$(score_from "$baseline_log" || true)"
fi

# --- stage 1: instrument + gather --------------------------------------------
echo "==> [1/3] building instrumented CoreMark and gathering profiles"
rm -rf "$PROFRAW_DIR"
mkdir -p "$PROFRAW_DIR"
# The bench harness exits non-zero on a low score; LLVM still flushes .profraw
# via its atexit hook, so tolerate the exit and verify the profiles landed.
RUSTFLAGS="-Cprofile-generate=$PROFRAW_DIR" cargo bench "${BENCH_ARGS[@]}" || true

# Collect the raw profiles the instrumented run produced (portable to the
# bash 3.2 that ships on macOS, which lacks `mapfile`).
PROFRAWS=()
while IFS= read -r profraw; do
  PROFRAWS+=("$profraw")
done < <(find "$PROFRAW_DIR" -name '*.profraw' -type f)
if [ "${#PROFRAWS[@]}" -eq 0 ]; then
  echo "error: no .profraw profiles were generated in $PROFRAW_DIR" >&2
  echo "       the instrumented CoreMark run may have crashed before exit." >&2
  exit 1
fi
echo "    gathered ${#PROFRAWS[@]} raw profile(s)"

# --- stage 2: merge ----------------------------------------------------------
echo "==> [2/3] merging profiles into $MERGED"
"$PROFDATA" merge -o "$MERGED" "${PROFRAWS[@]}"

# --- stage 3: optimize -------------------------------------------------------
echo "==> [3/3] rebuilding with profile-use"
# Re-run CoreMark under PGO to measure the optimized score...
pgo_log="$PGO_DIR/pgo.log"
RUSTFLAGS="-Cprofile-use=$MERGED" cargo bench "${BENCH_ARGS[@]}" 2>&1 | tee "$pgo_log"
PGO_SCORE="$(score_from "$pgo_log" || true)"
# ...and build the shippable interpreter binary with the same profile.
RUSTFLAGS="-Cprofile-use=$MERGED" cargo build "${BIN_ARGS[@]}"

BIN="$ROOT/target/release/spacewasm_std"
if [ -n "$OUT" ]; then
  cp "$BIN" "$OUT"
  BIN="$OUT"
fi

# --- summary -----------------------------------------------------------------
echo
echo "==> PGO build complete"
echo "    optimized binary: $BIN"
echo "    merged profile:   $MERGED"
if [ "$COMPARE" -eq 1 ] && [ -n "$BASELINE_SCORE" ] && [ -n "$PGO_SCORE" ]; then
  improvement="$(awk -v b="$BASELINE_SCORE" -v p="$PGO_SCORE" \
    'BEGIN { if (b > 0) printf "%+.2f", (p - b) / b * 100; else print "n/a" }')"
  echo "    CoreMark baseline: $BASELINE_SCORE"
  echo "    CoreMark PGO:      $PGO_SCORE  (${improvement}%)"
elif [ -n "$PGO_SCORE" ]; then
  echo "    CoreMark PGO score: $PGO_SCORE"
fi
