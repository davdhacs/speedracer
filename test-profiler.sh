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

# Step 1: group raw profiles into per-type aggregates, filter <20%, sort slowest-first
JQ_BUILD_FRESH='
  group_by(.cpu) |
  map({
    full: .[0].cpu,
    id: (.[0].cpu | gsub("AMD EPYC "; "") | gsub("Intel\\(R\\) Xeon\\(R\\) "; "") | gsub(" \\d+-Core Processor"; "") | gsub(" CPU @ .*"; "")),
    count: length,
    pct_num: (length * 100 / $n),
    pct: "\(length * 100 / $n)%",
    avg_ms: ([.[].cpu_bench_ms] | add / length | round),
    avg_disk: ([.[].disk_write_mbs | tonumber? // 0] | add / length | round),
    cores: .[0].cores,
    mem_mb: .[0].mem_mb
  }) |
  (map(select(.pct_num >= 20))) as $common |
  (if ($common | length) > 1 then $common else . end) |
  map(del(.pct_num)) |
  sort_by(-.avg_ms)
'

# Step 2: prune-merge-decide (fresh + old → result)
JQ_MERGE='
  ($fresh[0] | map(.id)) as $seen |
  ($old[0] | length) as $total |
  (reduce range($total) as $i (
    {pruning: true, pruned: 0, kept: []};
    ($old[0][$i]) as $entry |
    if .pruning and ($seen | index($entry.id) | not) then
      .pruned += 1
    else
      .pruning = false | .kept += [$entry]
    end
  )) as $prune |
  ($prune.kept | map(.id)) as $old_ids |
  [$fresh[0][] | select(.id as $id | $old_ids | index($id) | not)] as $new_entries |
  [
    ($prune.kept[] | . as $old |
      ([$fresh[0][] | select(.id == $old.id)][0] // null) as $match |
      if $match then $match else $old end
    ),
    $new_entries[]
  ] |
  sort_by(-.avg_ms) |
  { pruned: $prune.pruned,
    added: ($new_entries | length),
    entries: [.[] | {
      id, full,
      count: (.count | tostring),
      pct: (if .pct then .pct else "\(.count)/?%" end),
      avg_ms: (.avg_ms | tostring),
      avg_disk: (.avg_disk | tostring),
      cores: (.cores | tostring),
      mem_mb: (.mem_mb | tostring)
    }]
  }
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

  # Step 3: prune-merge-decide
  local result
  result=$(jq -n --argjson fresh "[$fresh_json]" --argjson old "[$old_json]" "$JQ_MERGE")

  # Extract actual values
  local actual_ids actual_pruned actual_added actual_commit
  actual_ids=$(echo "$result" | jq -r '[.entries[].id] | join(",")')
  actual_pruned=$(echo "$result" | jq -r '.pruned')
  actual_added=$(echo "$result" | jq -r '.added')
  if [[ "$actual_pruned" -gt 0 || "$actual_added" -gt 0 ]]; then
    actual_commit="yes"
  else
    actual_commit="no"
  fi

  # Row 1 = what the action would use as slow-cpu-pattern
  local row1
  row1=$(echo "$result" | jq -r '.entries[0].id // "NONE"')

  # Compare
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
      printf "        commit: expected=%s actual=%s (pruned=%s added=%s)\n" \
        "$expected_commit" "$actual_commit" "$actual_pruned" "$actual_added"
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
  "1 very-slow + 5 slow + 4 medium (10/50/40). Rare outlier slowest." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 5 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "" \
  "7763,9V74" \
  "yes" \
  "Optimal: filter out 10% very-slow. Gate 7763 (50%) instead."

run_test "A6: three-type-rare-fastest" \
  "5 slow + 4 medium + 1 fast (50/40/10). Rare fast type." \
  "$(make_profiles 5 "$CPU_SLOW" 4 "$CPU_MEDIUM" 1 "$CPU_FAST")" \
  "" \
  "7763,9V74" \
  "yes" \
  "Optimal: filter out 10% fast. Gate 7763 (50%)."

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

run_test "A9: five-types-sub-20" \
  "Mixed distribution, one type at 10%." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 3 "$CPU_VERY_FAST")" \
  "" \
  "7763,9V74,9V84,9X94" \
  "yes" \
  "7551 at 10% filtered. Row1=7763 gates 20%."

run_test "A10: four-type-spread" \
  "4+3+2+1 distribution (40/30/20/10)." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "7763,9V74,9V84" \
  "yes" \
  "9X94 (10%) filtered. Row1=7763 gates 40%."

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

run_test "B2: benchmark-jitter" \
  "Same types, benchmarks fluctuated. Same pool." \
  "$(make_profiles 5 '{"cpu":"AMD EPYC 7763 64-Core Processor","cpu_bench_ms":4900,"disk_write_mbs":"600","cores":4,"mem_mb":15990}' \
                   5 '{"cpu":"AMD EPYC 9V74 80-Core Processor","cpu_bench_ms":5100,"disk_write_mbs":"550","cores":4,"mem_mb":15990}')" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "no" \
  "Sort order flips from jitter but commit suppressed (pruned=0, added=0)."

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

run_test "C2: new-rare-type-filtered" \
  "Old has slow+medium. Fresh sees a rare new fast type (10%)." \
  "$(make_profiles 5 "$CPU_SLOW" 4 "$CPU_MEDIUM" 1 "$CPU_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763,9V74" \
  "no" \
  "New fast type at 10% filtered by 20% rule. Not added. No commit."

run_test "C3: slowest-disappears" \
  "Old has slow+medium. Fresh only sees medium (pool changed)." \
  "$(make_profiles 10 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74" \
  "yes" \
  "Top entry 7763 not seen → pruned. Commit."

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

run_test "C5: complete-pool-turnover" \
  "Old pool entirely replaced by new CPU types." \
  "$(make_profiles 6 "$CPU_FAST" 4 "$CPU_VERY_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V84,9X94" \
  "yes" \
  "Both old types pruned from top. Both new types added. Commit."

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
echo "=== Group D: Edge cases for the 20% filter ==="
echo ""

run_test "D1: barely-at-threshold" \
  "2 of 10 = exactly 20%. Should be included." \
  "$(make_profiles 2 "$CPU_SLOW" 8 "$CPU_FAST")" \
  "" \
  "7763,9V84" \
  "yes" \
  "20% is the threshold (>=). Both included."

run_test "D2: barely-below-threshold" \
  "1 slow + 9 fast. Slow at 10% < 20%." \
  "$(make_profiles 1 "$CPU_SLOW" 9 "$CPU_FAST")" \
  "" \
  "7763,9V84" \
  "yes" \
  "CRITICAL: slow filtered but only 1 type remains → fallback keeps all."

run_test "D3: three-types-one-dominates" \
  "1 very-slow + 1 medium + 8 fast (10/10/80)." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_MEDIUM" 8 "$CPU_FAST")" \
  "" \
  "7551,9V74,9V84" \
  "yes" \
  "Only fast (80%) passes 20% filter → 1 type → fallback to all."

run_test "D4: two-rare-one-common" \
  "1 very-slow + 1 slow + 8 fast (10/10/80). Two rare slow types." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_SLOW" 8 "$CPU_FAST")" \
  "" \
  "7551,7763,9V84" \
  "yes" \
  "Only fast passes 20% → 1 type → fallback to all."

run_test "D5: all-above-20" \
  "3 slow + 3 medium + 4 fast (30/30/40). All common." \
  "$(make_profiles 3 "$CPU_SLOW" 3 "$CPU_MEDIUM" 4 "$CPU_FAST")" \
  "" \
  "7763,9V74,9V84" \
  "yes" \
  "All pass filter. Row1=7763 gates 30%."

echo ""
echo "=== Group E: Future scenarios — wider spreads ==="
echo ""

run_test "E1: four-type-gradual" \
  "3 very-slow + 3 slow + 2 medium + 2 fast (30/30/20/20)." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 3 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST")" \
  "" \
  "7551,7763,9V74,9V84" \
  "yes" \
  "All >= 20%. Row1=7551 gates 30%. ACTION LIMITATION: 7763 (30%) also slow."

run_test "E2: two-slow-one-fast" \
  "4 very-slow + 4 slow + 2 fast (40/40/20). Two slow types." \
  "$(make_profiles 4 "$CPU_VERY_SLOW" 4 "$CPU_SLOW" 2 "$CPU_FAST")" \
  "" \
  "7551,7763,9V84" \
  "yes" \
  "Row1=7551 gates 40%. ACTION LIMITATION: 7763 (40%) also slow, ungated."

run_test "E3: staircase-five-types" \
  "3+2+2+2+1 = 30/20/20/20/10. Gradual performance staircase." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84" \
  "yes" \
  "9X94 (10%) filtered. Row1=7551 gates 30%."

run_test "E4: many-types-no-majority" \
  "2 each of 5 types. Equal fragmented pool." \
  "$(make_profiles 2 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 2 "$CPU_VERY_FAST")" \
  "" \
  "7551,7763,9V74,9V84,9X94" \
  "yes" \
  "All at 20%. Row1=7551 gates 20%. 80% proceed."

echo ""
echo "=== Group F: Action-side improvement scenarios ==="
echo "=== (These document cases where TSV ranking + action changes would help) ==="
echo ""

run_test "F1: ranking-would-help" \
  "3 very-slow + 3 slow + 4 fast. Single pattern gates only 30%." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 3 "$CPU_SLOW" 4 "$CPU_FAST")" \
  "" \
  "7551,7763,9V84" \
  "yes" \
  "Row1=7551 gates 30%. 7763 (30%) also slow. WITH RANKING: all slow types would be gated."

run_test "F2: ranking-not-needed" \
  "6 slow + 4 fast. One clear slow type, one clear fast." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_FAST")" \
  "" \
  "7763,9V84" \
  "yes" \
  "Row1=7763 gates 60%. Fast type proceeds. Single pattern is optimal here."

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"
echo "════════════════════════════════════════════════════════"

# Highlight cases where the action's single-pattern design is the bottleneck
echo ""
echo "Cases marked ACTION LIMITATION show where a TSV-ranking approach"
echo "(runner reads its position, defers to faster-ranked siblings)"
echo "would outperform the current single-pattern gate."
echo ""

exit "$FAIL"
