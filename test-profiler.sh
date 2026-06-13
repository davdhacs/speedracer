#!/usr/bin/env bash
# Test suite for the runner-pool.tsv profiler filtering and merge logic.
#
# Each test case defines:
#   - A mock runner pool (what the 10 profiler runners reported)
#   - An existing runner-pool.tsv (or empty for fresh start)
#   - The expected optimal output: which cpu_ids, in what order
#   - Whether a commit should happen
#
# Run: bash test-profiler.sh
#
# The jq expressions here must match what's in runner-profile.yaml.

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

# CPU types used in tests (realistic model names that the id-extraction jq handles).
# The jq strips "AMD EPYC " prefix and " NN-Core Processor" suffix to get the short id.
#
# Sorted by CPU benchmark (slowest first = highest avg_ms):
#   7551 (7000ms) > 7763 (5500ms) > 9V74 (5000ms) > 9V84 (4500ms) > 9X94 (4000ms)
CPU_VERY_SLOW='{"cpu":"AMD EPYC 7551 32-Core Processor","cpu_bench_ms":7000,"disk_write_mbs":"400","cores":4,"mem_mb":15990}'
CPU_SLOW='{"cpu":"AMD EPYC 7763 64-Core Processor","cpu_bench_ms":5500,"disk_write_mbs":"580","cores":4,"mem_mb":15990}'
CPU_MEDIUM='{"cpu":"AMD EPYC 9V74 80-Core Processor","cpu_bench_ms":5000,"disk_write_mbs":"600","cores":4,"mem_mb":15990}'
CPU_FAST='{"cpu":"AMD EPYC 9V84 96-Core Processor","cpu_bench_ms":4500,"disk_write_mbs":"650","cores":4,"mem_mb":15990}'
CPU_VERY_FAST='{"cpu":"AMD EPYC 9X94 128-Core Processor","cpu_bench_ms":4000,"disk_write_mbs":"700","cores":4,"mem_mb":15990}'

# ── jq expressions (must match runner-profile.yaml) ─────────────────────────

# Step 1: group raw profiles into per-type aggregates, sort slowest-first
JQ_BUILD_FRESH='
  group_by(.cpu) |
  map({
    full: .[0].cpu,
    id: (.[0].cpu | gsub("AMD EPYC "; "") | gsub("Intel\\(R\\) Xeon\\(R\\) "; "") | gsub(" \\d+-Core Processor"; "") | gsub(" CPU @ .*"; "")),
    count: length,
    pct: "\(length * 100 / $n)%",
    avg_ms: ([.[].cpu_bench_ms] | add / length | round),
    avg_disk: ([.[].disk_write_mbs | tonumber? // 0] | add / length | round),
    cores: .[0].cores,
    mem_mb: .[0].mem_mb
  }) |
  sort_by(-.avg_ms)
'

# Step 2: merge fresh + old → sorted entries
JQ_MERGE='
  ($old[0] | map(.id)) as $old_ids |
  [
    ($old[0][] | . as $entry |
      ([$fresh[0][] | select(.id == $entry.id)][0] // null) as $match |
      if $match then $match else $entry end
    ),
    ($fresh[0][] | select(.id as $id | $old_ids | index($id) | not))
  ] |
  sort_by(-.avg_ms) |
  [.[] | {
    id, full,
    count: (.count | tostring),
    pct: (if .pct then .pct else "\(.count)/?%" end),
    avg_ms: (.avg_ms | tostring),
    avg_disk: (.avg_disk | tostring),
    cores: (.cores | tostring),
    mem_mb: (.mem_mb | tostring)
  }]
'

# ── Test runner ──────────────────────────────────────────────────────────────

make_profiles() {
  # Build a merged.json from count+template pairs: make_profiles 6 "$CPU_SLOW" 4 "$CPU_MEDIUM"
  local items=()
  while [[ $# -ge 2 ]]; do
    local count=$1 template=$2; shift 2
    for ((i=0; i<count; i++)); do items+=("$template"); done
  done
  local IFS=','
  echo "[${items[*]}]"
}

make_old_tsv() {
  # Build an old runner-pool.tsv from id/bench/disk/cores/mem/full tuples
  # Usage: make_old_tsv "id1 count1 pct1 ms1 disk1 cores1 mem1 full1" "id2 ..."
  local header="# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model"
  if [[ $# -eq 0 ]]; then
    echo ""
    return
  fi
  local lines=("$header")
  for row in "$@"; do
    IFS=$'\t' read -ra fields <<< "$row"
    lines+=("${fields[*]}")
  done
  printf '%s\n' "${lines[@]}"
}

tsv_to_json() {
  # Parse TSV string to JSON array (same logic as workflow)
  local tsv="$1"
  if [[ -z "$tsv" ]]; then
    echo '[]'
    return
  fi
  echo "$tsv" | grep -v '^#' | grep -v '^$' | jq -Rn '
    [inputs | split("\t") | select(length >= 8) | {
      id: .[0], count: (.[1] | tonumber), pct: .[2],
      avg_ms: (.[3] | tonumber), avg_disk: (.[4] | tonumber),
      cores: (.[5] | tonumber), mem_mb: (.[6] | tonumber), full: .[7]
    }]
  '
}

run_test() {
  local name="$1"
  local description="$2"
  local merged_json="$3"         # raw profiler output (array of runner profiles)
  local old_tsv="$4"             # existing runner-pool.tsv content (or "")
  local expected_ids="$5"        # comma-separated expected cpu_ids in order
  local expected_commit="$6"     # "yes" or "no"
  local notes="${7:-}"           # optional notes about optimality

  TOTAL=$((TOTAL + 1))

  local sample_count
  sample_count=$(echo "$merged_json" | jq 'length')

  # Step 1: build fresh.json
  local fresh_json
  fresh_json=$(echo "$merged_json" | jq --argjson n "$sample_count" "$JQ_BUILD_FRESH")

  # Step 2: parse old TSV
  local old_json
  old_json=$(tsv_to_json "$old_tsv")

  # Step 3: merge
  local entries
  entries=$(jq -n --argjson fresh "[$fresh_json]" --argjson old "[$old_json]" "$JQ_MERGE")

  local actual_ids old_order old_count new_count actual_commit
  actual_ids=$(echo "$entries" | jq -r '[.[].id] | join(",")')
  old_order=$(echo "$old_json" | jq -r '[.[].id] | join(",")')
  old_count=$(echo "$old_json" | jq 'length')
  new_count=$(echo "$entries" | jq 'length')

  if [[ "$old_order" != "$actual_ids" || "$old_count" != "$new_count" ]]; then
    actual_commit="yes"
  else
    actual_commit="no"
  fi

  local row1
  row1=$(echo "$entries" | jq -r '.[0].id // "NONE"')

  local id_ok commit_ok
  [[ "$actual_ids" == "$expected_ids" ]] && id_ok=true || id_ok=false
  [[ "$actual_commit" == "$expected_commit" ]] && commit_ok=true || commit_ok=false

  if $id_ok && $commit_ok; then
    printf "  \033[32mPASS\033[0m  %-40s ids=[%s] row1=%s commit=%s\n" "$name" "$actual_ids" "$row1" "$actual_commit"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf "  \033[31mFAIL\033[0m  %-40s\n" "$name"
    if ! $id_ok; then
      printf "        ids:    expected=[%s]\n" "$expected_ids"
      printf "                  actual=[%s]\n" "$actual_ids"
    fi
    if ! $commit_ok; then
      printf "        commit: expected=%s actual=%s\n" "$expected_commit" "$actual_commit"
      printf "                old_order=[%s] new_order=[%s]\n" "$old_order" "$actual_ids"
    fi
    [[ -n "$notes" ]] && printf "        notes:  %s\n" "$notes"
  fi
}

# ── Test cases ───────────────────────────────────────────────────────────────

echo ""
echo "=== Group A: Fresh start (no existing TSV) ==="
echo ""

run_test "A1: two-type-balanced-60-40" \
  "6 slow + 4 medium. Clear majority slow type." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "" \
  "7763,9V74" \
  "yes" \
  "Row1=7763 gates 60% of runners. Optimal."

run_test "A2: two-type-equal-50-50" \
  "5 slow + 5 medium. Equal split." \
  "$(make_profiles 5 "$CPU_SLOW" 5 "$CPU_MEDIUM")" \
  "" \
  "7763,9V74" \
  "yes" \
  "Row1=7763 gates 50%. Sibling polling picks the 9V74 winner."

run_test "A3: two-type-dominant-fast-90-10" \
  "9 fast + 1 slow. Rare slow type." \
  "$(make_profiles 9 "$CPU_FAST" 1 "$CPU_SLOW")" \
  "" \
  "7763,9V84" \
  "yes" \
  "CRITICAL: row1 must be the slow type, not the dominant fast type."

run_test "A4: three-type-all-common" \
  "4 slow + 3 medium + 3 fast (40/30/30). All significant." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 3 "$CPU_FAST")" \
  "" \
  "7763,9V74,9V84" \
  "yes" \
  "Row1=7763 gates 40%. Medium and fast proceed."

run_test "A5: three-type-rare-slowest" \
  "1 very-slow + 5 slow + 4 medium (10/50/40). Rare slowest included." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 5 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "" \
  "7551,7763,9V74" \
  "yes" \
  "All types included regardless of share. 7551 gets rank 1."

run_test "A6: three-type-rare-fastest" \
  "5 slow + 4 medium + 1 fast (50/40/10). Rare fast type included." \
  "$(make_profiles 5 "$CPU_SLOW" 4 "$CPU_MEDIUM" 1 "$CPU_FAST")" \
  "" \
  "7763,9V74,9V84" \
  "yes" \
  "All types included. 9V84 gets highest rank despite 10% share."

run_test "A7: single-type" \
  "10 slow (100%). Homogeneous pool." \
  "$(make_profiles 10 "$CPU_SLOW")" \
  "" \
  "7763" \
  "yes" \
  "One type. Gating means only copy-a runs. Fine — all runners equal."

run_test "A8: five-types-all-20pct" \
  "2 each of 5 types (20% each). Fragmented pool." \
  "$(make_profiles 2 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 2 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84,9X94" \
  "yes" \
  "All at exactly 20% — all kept. Row1=7551 gates 20%."

run_test "A9: five-types-mixed-share" \
  "Mixed distribution, all types included." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 3 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84,9X94" \
  "yes" \
  "All 5 types included. Full ranking from slowest to fastest."

run_test "A10: four-type-spread" \
  "4+3+2+1 distribution (40/30/20/10). All included." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "7763,9V74,9V84,9X94" \
  "yes" \
  "All 4 types ranked. 9X94 at 10% still gets highest rank."

run_test "A11: extreme-skew-95-5" \
  "19 fast + 1 slow out of 20. Extreme skew." \
  "$(make_profiles 19 "$CPU_FAST" 1 "$CPU_SLOW")" \
  "" \
  "7763,9V84" \
  "yes" \
  "CRITICAL: same as A3. Slow type must be row1 despite 5% share."

echo ""
echo "=== Group B: Steady state (existing TSV, repeat runs) ==="
echo ""

OLD_TSV_STANDARD="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  '7763' '6' '60%' '5276' '584' '4' '15990' 'AMD EPYC 7763 64-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  '9V74' '4' '40%' '5037' '403' '4' '15990' 'AMD EPYC 9V74 80-Core Processor')"

OLD_TSV_STANDARD_WITH_HEADER="# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model
${OLD_TSV_STANDARD}"

run_test "B1: no-change-same-benchmarks" \
  "Same types, same distribution. No change." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74" \
  "no" \
  "Benchmark numbers updated in memory but not committed."

run_test "B2: benchmark-jitter-flips-order" \
  "Same types, benchmarks fluctuated enough to flip order." \
  "$(make_profiles 5 '{"cpu":"AMD EPYC 7763 64-Core Processor","cpu_bench_ms":4900,"disk_write_mbs":"600","cores":4,"mem_mb":15990}' \
                   5 '{"cpu":"AMD EPYC 9V74 80-Core Processor","cpu_bench_ms":5100,"disk_write_mbs":"550","cores":4,"mem_mb":15990}')" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "yes" \
  "Order flipped (9V74 now slower) → commit. Rankings changed."

run_test "B3: count-shift" \
  "Same types, distribution shifted from 60/40 to 50/50." \
  "$(make_profiles 5 "$CPU_SLOW" 5 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74" \
  "no" \
  "Count/pct changes but same types. No commit."

echo ""
echo "=== Group C: Structural changes ==="
echo ""

run_test "C1: new-common-type-appears" \
  "Old has slow+medium. Fresh adds a common fast type." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 3 "$CPU_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74,9V84" \
  "yes" \
  "New type 9V84 at 30% → added. Commit."

run_test "C2: new-rare-type-added" \
  "Old has slow+medium. Fresh sees a rare new fast type (10%). Added." \
  "$(make_profiles 5 "$CPU_SLOW" 4 "$CPU_MEDIUM" 1 "$CPU_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74,9V84" \
  "yes" \
  "New fast type added regardless of share. Count changed → commit."

run_test "C3: type-unseen-stays" \
  "Old has slow+medium. Fresh only sees medium. Unseen type stays." \
  "$(make_profiles 10 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74" \
  "no" \
  "7763 not seen but stays in TSV (no purging). Same count+order. No commit."

run_test "C4: middle-unseen-stays" \
  "Old has 3 types. Fresh doesn't see the middle one." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_FAST")" \
  "# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '7763' '5' '50%' '5500' '580' '4' '15990' 'AMD EPYC 7763 64-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9V74' '3' '30%' '5000' '600' '4' '15990' 'AMD EPYC 9V74 80-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9V84' '2' '20%' '4500' '650' '4' '15990' 'AMD EPYC 9V84 96-Core Processor')" \
  "7763,9V74,9V84" \
  "no" \
  "9V74 not seen but below a seen top entry → stays. No commit."

run_test "C5: new-types-added-old-stay" \
  "All fresh types are new. Old types stay, new types added." \
  "$(make_profiles 6 "$CPU_FAST" 4 "$CPU_VERY_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74,9V84,9X94" \
  "yes" \
  "Old types kept (no purging). New types added. Count changed → commit."

run_test "C6: old-type-returns" \
  "After a previous turnover, an old type reappears." \
  "$(make_profiles 3 "$CPU_SLOW" 4 "$CPU_FAST" 3 "$CPU_VERY_FAST")" \
  "# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9V84' '6' '60%' '4500' '650' '4' '15990' 'AMD EPYC 9V84 96-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9X94' '4' '40%' '4000' '700' '4' '15990' 'AMD EPYC 9X94 128-Core Processor')" \
  "7763,9V84,9X94" \
  "yes" \
  "7763 at 30% is new (wasn't in old TSV) → added. Commit."

echo ""
echo "=== Group D: Rare types and skewed distributions ==="
echo ""

run_test "D1: dominant-fast-rare-slow" \
  "9 fast + 1 slow (90/10). Rare slow type gets rank." \
  "$(make_profiles 9 "$CPU_FAST" 1 "$CPU_SLOW")" \
  "" \
  "7763,9V84" \
  "yes" \
  "Both ranked. 7763 at rank 1 (slowest). 9V84 at rank 2."

run_test "D2: three-types-one-dominates" \
  "1 very-slow + 1 medium + 8 fast (10/10/80). All ranked." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_MEDIUM" 8 "$CPU_FAST")" \
  "" \
  "7551,9V74,9V84" \
  "yes" \
  "All 3 types get ranks. 7551 rank 1, 9V74 rank 2, 9V84 rank 3."

run_test "D3: many-rare-types" \
  "1 of each of 5 types + 5 of a 6th. All included." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_SLOW" 1 "$CPU_MEDIUM" 1 "$CPU_FAST" 1 "$CPU_VERY_FAST" 5 '{"cpu":"AMD EPYC 9V45 96-Core Processor","cpu_bench_ms":4800,"disk_write_mbs":"620","cores":4,"mem_mb":15990}')" \
  "" \
  "7551,7763,9V74,9V45,9V84,9X94" \
  "yes" \
  "6 types ranked. Every runner gets a meaningful rank instead of defaulting to 0."

echo ""
echo "=== Group E: Future scenarios — wider spreads ==="
echo ""

run_test "E1: four-type-gradual" \
  "3 very-slow + 3 slow + 2 medium + 2 fast (30/30/20/20)." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 3 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST")" \
  "" \
  "7551,7763,9V74,9V84" \
  "yes" \
  "4 ranks. Ranking defers all slower types to faster ones."

run_test "E2: two-slow-one-fast" \
  "4 very-slow + 4 slow + 2 fast (40/40/20). Two slow types both ranked." \
  "$(make_profiles 4 "$CPU_VERY_SLOW" 4 "$CPU_SLOW" 2 "$CPU_FAST")" \
  "" \
  "7551,7763,9V84" \
  "yes" \
  "Both slow types get low ranks. Fast type at rank 3 wins. No more single-pattern limitation."

run_test "E3: staircase-five-types" \
  "3+2+2+2+1 = full 5-type staircase." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84,9X94" \
  "yes" \
  "All 5 types ranked. Full performance staircase."

run_test "E4: equal-fragmented" \
  "2 each of 5 types. Equal fragmented pool." \
  "$(make_profiles 2 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 2 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84,9X94" \
  "yes" \
  "5 ranks. Fastest type (rank 5) wins via ranking."

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"
echo "════════════════════════════════════════════════════════"
echo ""

exit "$FAIL"
