#!/usr/bin/env bash
# mayhem/test.sh — RUN CryptoMiniSat's own gtest binaries (built by mayhem/build.sh in build/test)
# plus known-answer runs of the solver CLI. Does not compile anything.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

B="$SRC/build/test"
CLI="$B/cryptominisat5"
[ -x "$CLI" ] || { echo "missing $CLI — mayhem/build.sh must build it" >&2; emit_ctrf cryptominisat-gtest 0 1; exit 1; }

passed=0; failed=0; skipped=0
n_bins=0
for t in "$B"/tests/*_test; do
  [ -x "$t" ] || continue
  n_bins=$((n_bins+1))
  out=$("$t" 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\..*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below.*/\1/p' | tail -1)
  s=$(printf '%s\n' "$out" | sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?.*/\1/p' | tail -1)
  p=${p:-0}; f=${f:-0}; s=${s:-0}
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi          # crashed / aborted
  if [ "$p" -eq 0 ] && [ "$f" -eq 0 ] && [ "$s" -eq 0 ]; then  # not a gtest binary: assert()-based program
    case "$(basename "$t")" in
      c_test) ;;
      readme_test) printf '%s\n' "$out" | grep -q 'Solution is: l_True, l_False, l_True' || f=1 ;;
      multisol_test) [ "$(printf '%s\n' "$out" | grep -c '^Solution is')" -eq 3 ] \
                       && printf '%s\n' "$out" | grep -q 'No more solutions' || f=1 ;;
      *) echo "no gtest result from $t (rc=$rc)"; f=1 ;;
    esac
    [ "$f" -eq 0 ] && [ "$rc" -eq 0 ] && p=1
  fi
  [ "$f" -gt 0 ] && { echo "--- $t"; printf '%s\n' "$out" | tail -30; }
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
done
[ "$n_bins" -gt 0 ] || { echo "no gtest binaries under $B/tests" >&2; failed=$((failed+1)); }

# Known-answer checks of the solver CLI: <name> <expected 's ' line> <cnf text>
check_cli() {
  local name="$1" want="$2" cnf="$3" f res
  f=$(mktemp "${TMPDIR:-/tmp}/cms-ka.XXXXXX.cnf")
  printf '%b' "$cnf" > "$f"
  res=$("$CLI" --verb=0 "$f" 2>&1 | grep -E '^s ' | head -1)
  rm -f "$f"
  if [ "$res" = "$want" ]; then passed=$((passed+1)); else
    echo "FAIL $name: got '${res}', want '${want}'"; failed=$((failed+1)); fi
}
check_cli unsat-all-8-clauses "s UNSATISFIABLE" 'p cnf 3 8\n1 2 3 0\n1 2 -3 0\n1 -2 3 0\n1 -2 -3 0\n-1 2 3 0\n-1 2 -3 0\n-1 -2 3 0\n-1 -2 -3 0\n'
check_cli sat-simple "s SATISFIABLE" 'p cnf 3 2\n1 2 0\n-2 3 0\n'
check_cli unsat-units "s UNSATISFIABLE" 'p cnf 1 2\n1 0\n-1 0\n'
check_cli unsat-xor-contradiction "s UNSATISFIABLE" 'p cnf 3 3\nx1 2 0\nx2 3 0\nx1 3 0\n'
check_cli sat-xor "s SATISFIABLE" 'p cnf 3 3\nx1 2 0\nx2 3 0\nx-1 3 0\n'

# Forced-model check: units 1,-2 and (-1 2 3) pin the unique model.
f=$(mktemp "${TMPDIR:-/tmp}/cms-model.XXXXXX.cnf")
printf 'p cnf 3 4\n1 0\n-2 0\n-1 2 3 0\n-3 1 0\n' > "$f"
model=$("$CLI" --verb=0 "$f" 2>&1 | grep -E '^v ' | head -1)
rm -f "$f"
if [ "$model" = "v 1 -2 3 0" ]; then passed=$((passed+1)); else
  echo "FAIL forced-model: got '$model', want 'v 1 -2 3 0'"; failed=$((failed+1)); fi

emit_ctrf cryptominisat-gtest "$passed" "$failed" "$skipped"
