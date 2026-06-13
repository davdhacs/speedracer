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
# IMPORTANT: CPU and disk speeds are intentionally uncorrelated — matching real-world
# observations where newer CPUs can have worse disk I/O. Sorting by disk I/O
# (the actual bottleneck for builds) gives a DIFFERENT order than sorting by CPU.
#
# By CPU (slowest first):  7551 > 7763 > 9V74 > 9V84 > 9X94
# By disk (slowest first): 9V74 < 9V84 < 7551 < 7763 < 9X94
#
# The sort key is disk I/O (ascending = worst disk first), so the expected
# order in most tests is: 9V74, 9V84, 7551, 7763, 9X94
CPU_VERY_SLOW='{"cpu":"AMD EPYC 7551 32-Core Processor","cpu_bench_ms":7000,"disk_write_mbs":"500","cores":4,"mem_mb":15990}'
CPU_SLOW='{"cpu":"AMD EPYC 7763 64-Core Processor","cpu_bench_ms":5500,"disk_write_mbs":"580","cores":4,"mem_mb":15990}'
CPU_MEDIUM='{"cpu":"AMD EPYC 9V74 80-Core Processor","cpu_bench_ms":5000,"disk_write_mbs":"400","cores":4,"mem_mb":15990}'
CPU_FAST='{"cpu":"AMD EPYC 9V84 96-Core Processor","cpu_bench_ms":4500,"disk_write_mbs":"450","cores":4,"mem_mb":15990}'
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
  sort_by(.avg_disk)
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
  sort_by(.avg_disk) |
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
  "6 slow-disk(7763) + 4 slower-disk(9V74). 9V74 has worst disk." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "" \
  "9V74,7763" \
  "yes" \
  "Row1=9V74 (400 MB/s disk) gates 40%. 7763 (580 MB/s) proceeds."

run_test "A2: two-type-equal-50-50" \
  "5 of each type. Equal split, sorted by disk." \
  "$(make_profiles 5 "$CPU_SLOW" 5 "$CPU_MEDIUM")" \
  "" \
  "9V74,7763" \
  "yes" \
  "Row1=9V74 gates 50%. 7763 has faster disk, proceeds."

run_test "A3: two-type-dominant-fast-90-10" \
  "9 fast-disk(9V84) + 1 faster-disk(7763). Rare type has better disk." \
  "$(make_profiles 9 "$CPU_FAST" 1 "$CPU_SLOW")" \
  "" \
  "9V84,7763" \
  "yes" \
  "CRITICAL: row1 must be the slow-disk type (9V84, 450 MB/s), not the rare fast-disk type. 20% filter must not invert this."

run_test "A4: three-type-all-common" \
  "4 types at 40/30/30. All significant." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 3 "$CPU_FAST")" \
  "" \
  "9V74,9V84,7763" \
  "yes" \
  "Row1=9V74 (400 MB/s) gates 30%. 9V84 and 7763 proceed."

run_test "A5: three-type-rare-slowest-disk" \
  "1 slowest-disk(9V74) + 5 mid(7763) + 4 fast-disk(7551). Rare outlier." \
  "$(make_profiles 1 "$CPU_MEDIUM" 5 "$CPU_SLOW" 4 "$CPU_VERY_SLOW")" \
  "" \
  "7551,7763" \
  "yes" \
  "9V74 at 10% filtered. Gate 7551 (40%, 500 MB/s disk) instead. Row1=7551."

run_test "A6: three-type-rare-fastest-disk" \
  "5 slow-disk(9V74) + 4 mid(7763) + 1 fast-disk(9X94). Rare fast type." \
  "$(make_profiles 5 "$CPU_MEDIUM" 4 "$CPU_SLOW" 1 "$CPU_VERY_FAST")" \
  "" \
  "9V74,7763" \
  "yes" \
  "9X94 at 10% filtered. Gate 9V74 (50%). Rare fast-disk type not worth tracking."

run_test "A7: single-type" \
  "10 of one type (100%). Homogeneous pool." \
  "$(make_profiles 10 "$CPU_SLOW")" \
  "" \
  "7763" \
  "yes" \
  "One type. Gating means only copy-a runs. Fine — all runners equal."

run_test "A8: five-types-all-20pct" \
  "2 each of 5 types (20% each). Fragmented pool." \
  "$(make_profiles 2 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 2 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9V84,7551,7763,9X94" \
  "yes" \
  "All at exactly 20% — all kept. Row1=9V74 (400 MB/s) gates 20%."

run_test "A9: five-types-sub-20" \
  "Mixed distribution, one type at 10%." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 3 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9V84,7763,9X94" \
  "yes" \
  "7551 at 10% filtered. Row1=9V74 (400 MB/s) gates 20%."

run_test "A10: four-type-spread" \
  "4+3+2+1 distribution (40/30/20/10)." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9V84,7763" \
  "yes" \
  "9X94 (10%) filtered. Row1=9V74 (400 MB/s) gates 30%."

run_test "A11: extreme-skew-95-5" \
  "19 of one type + 1 of another. Extreme skew." \
  "$(make_profiles 19 "$CPU_FAST" 1 "$CPU_SLOW")" \
  "" \
  "9V84,7763" \
  "yes" \
  "CRITICAL: same as A3. Slow-disk type must be row1 despite 5% share."

echo ""
echo "=== Group B: Steady state (existing TSV, repeat runs) ==="
echo ""

# Old TSV in disk-sorted order (9V74 has worse disk than 7763)
OLD_TSV_STANDARD="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  '9V74' '4' '40%' '5037' '403' '4' '15990' 'AMD EPYC 9V74 80-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  '7763' '6' '60%' '5276' '584' '4' '15990' 'AMD EPYC 7763 64-Core Processor')"

OLD_TSV_STANDARD_WITH_HEADER="# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model
${OLD_TSV_STANDARD}"

run_test "B1: no-change-same-benchmarks" \
  "Same types, same distribution. No change." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "no" \
  "Benchmark numbers updated in memory but not committed. File unchanged on disk."

run_test "B2: benchmark-jitter" \
  "Same types, disk benchmarks fluctuated. Same pool." \
  "$(make_profiles 5 '{"cpu":"AMD EPYC 7763 64-Core Processor","cpu_bench_ms":4900,"disk_write_mbs":"600","cores":4,"mem_mb":15990}' \
                   5 '{"cpu":"AMD EPYC 9V74 80-Core Processor","cpu_bench_ms":5100,"disk_write_mbs":"550","cores":4,"mem_mb":15990}')" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "no" \
  "Disk speeds jittered but same order (9V74 still slower). No commit."

run_test "B3: count-shift" \
  "Same types, distribution shifted from 60/40 to 50/50." \
  "$(make_profiles 5 "$CPU_SLOW" 5 "$CPU_MEDIUM")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "no" \
  "Count/pct changes but same types. No commit."

echo ""
echo "=== Group C: Structural changes ==="
echo ""

run_test "C1: new-common-type-appears" \
  "Old has 9V74+7763. Fresh adds 9V84 at 30%." \
  "$(make_profiles 4 "$CPU_SLOW" 3 "$CPU_MEDIUM" 3 "$CPU_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,9V84,7763" \
  "yes" \
  "New type 9V84 at 30% → added. Commit."

run_test "C2: new-rare-type-filtered" \
  "Old has 9V74+7763. Fresh sees a rare new type (10%)." \
  "$(make_profiles 5 "$CPU_SLOW" 4 "$CPU_MEDIUM" 1 "$CPU_FAST")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "9V74,7763" \
  "no" \
  "New type at 10% filtered by 20% rule. Not added. No commit."

run_test "C3: slowest-disk-disappears" \
  "Old has 9V74+7763. Fresh only sees 7763 (9V74 gone from pool)." \
  "$(make_profiles 10 "$CPU_SLOW")" \
  "$OLD_TSV_STANDARD_WITH_HEADER" \
  "7763" \
  "yes" \
  "Top entry 9V74 not seen → pruned. Commit."

run_test "C4: middle-unseen-stays" \
  "Old has 3 types (disk-sorted). Fresh doesn't see the middle one." \
  "$(make_profiles 6 "$CPU_SLOW" 4 "$CPU_FAST")" \
  "# cpu_id	count	pct	avg_bench_ms	avg_disk_mbs	cores	mem_mb	full_model
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9V84' '2' '20%' '4500' '450' '4' '15990' 'AMD EPYC 9V84 96-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '7551' '3' '30%' '7000' '500' '4' '15990' 'AMD EPYC 7551 32-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '7763' '5' '50%' '5500' '580' '4' '15990' 'AMD EPYC 7763 64-Core Processor')" \
  "9V84,7551,7763" \
  "no" \
  "7551 not seen but below seen top entry (9V84 seen via CPU_FAST) → stays. No commit."

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
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9V84' '6' '60%' '4500' '450' '4' '15990' 'AMD EPYC 9V84 96-Core Processor')
$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' '9X94' '4' '40%' '4000' '700' '4' '15990' 'AMD EPYC 9X94 128-Core Processor')" \
  "9V84,7763,9X94" \
  "yes" \
  "7763 at 30% is new (wasn't in old TSV) → added. Commit."

echo ""
echo "=== Group D: Edge cases for the 20% filter ==="
echo ""

run_test "D1: barely-at-threshold" \
  "2 of 10 = exactly 20%. Should be included." \
  "$(make_profiles 2 "$CPU_SLOW" 8 "$CPU_FAST")" \
  "" \
  "9V84,7763" \
  "yes" \
  "20% is the threshold (>=). Both included. Row1=9V84 (450 MB/s)."

run_test "D2: barely-below-threshold" \
  "1 slow-disk + 9 fast-disk. Slow at 10% < 20%." \
  "$(make_profiles 1 "$CPU_SLOW" 9 "$CPU_FAST")" \
  "" \
  "9V84,7763" \
  "yes" \
  "CRITICAL: 7763 filtered but only 1 type remains → fallback keeps all. Row1=9V84 (slower disk)."

run_test "D3: three-types-one-dominates" \
  "1+1+8 split (10/10/80). One dominant type." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_MEDIUM" 8 "$CPU_FAST")" \
  "" \
  "9V74,9V84,7551" \
  "yes" \
  "Only 9V84 (80%) passes 20% filter → 1 type → fallback to all. Row1=9V74 (400 MB/s)."

run_test "D4: two-rare-one-common" \
  "1+1+8 split (10/10/80). Two rare types." \
  "$(make_profiles 1 "$CPU_VERY_SLOW" 1 "$CPU_SLOW" 8 "$CPU_FAST")" \
  "" \
  "9V84,7551,7763" \
  "yes" \
  "Only 9V84 passes 20% → 1 type → fallback to all. Row1=9V84 (450 MB/s)."

run_test "D5: all-above-20" \
  "3+3+4 split (30/30/40). All common." \
  "$(make_profiles 3 "$CPU_SLOW" 3 "$CPU_MEDIUM" 4 "$CPU_FAST")" \
  "" \
  "9V74,9V84,7763" \
  "yes" \
  "All pass filter. Row1=9V74 (400 MB/s) gates 30%."

echo ""
echo "=== Group E: Future scenarios — wider spreads ==="
echo ""

run_test "E1: four-type-gradual" \
  "3+3+2+2 (30/30/20/20). Gradual disk speed spread." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 3 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST")" \
  "" \
  "9V74,9V84,7551,7763" \
  "yes" \
  "All >= 20%. Row1=9V74 (400 MB/s) gates 20%. ACTION LIMITATION: 9V84 (450 MB/s, 20%) also slow disk — single pattern can only gate one."

run_test "E2: two-slow-disk-one-fast" \
  "4+4+2 (40/40/20). Two types with slow disk." \
  "$(make_profiles 4 "$CPU_VERY_SLOW" 4 "$CPU_SLOW" 2 "$CPU_FAST")" \
  "" \
  "9V84,7551,7763" \
  "yes" \
  "Row1=9V84 (450 MB/s) gates ... wait, 7551 has 500 MB/s disk. ACTION LIMITATION: single pattern misses the other slow-disk type."

run_test "E3: staircase-five-types" \
  "3+2+2+2+1 = 30/20/20/20/10. Gradual performance staircase." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 1 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9V84,7551,7763" \
  "yes" \
  "9X94 (10%) filtered. Row1=9V74 (400 MB/s) gates 20%."

run_test "E4: many-types-no-majority" \
  "2 each of 5 types. Equal fragmented pool." \
  "$(make_profiles 2 "$CPU_VERY_SLOW" 2 "$CPU_SLOW" 2 "$CPU_MEDIUM" 2 "$CPU_FAST" 2 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9V84,7551,7763,9X94" \
  "yes" \
  "All at 20%. Row1=9V74 (400 MB/s) gates 20%. 80% proceed."

echo ""
echo "=== Group F: Action-side improvement scenarios ==="
echo "=== (These document cases where TSV ranking + action changes would help) ==="
echo ""

run_test "F1: ranking-would-help" \
  "3+3+4 split. Two slow-disk types, single pattern gates only one." \
  "$(make_profiles 3 "$CPU_VERY_SLOW" 3 "$CPU_SLOW" 4 "$CPU_FAST")" \
  "" \
  "9V84,7551,7763" \
  "yes" \
  "Row1=9V84 gates ... WITH RANKING: runners read their TSV line and defer to faster-disk siblings. Would gate multiple slow-disk types."

run_test "F2: ranking-not-needed" \
  "6+4 split. One slow-disk type, one fast-disk type." \
  "$(make_profiles 6 "$CPU_MEDIUM" 4 "$CPU_VERY_FAST")" \
  "" \
  "9V74,9X94" \
  "yes" \
  "Row1=9V74 (400 MB/s) gates 60%. 9X94 (700 MB/s) proceeds. Single pattern is optimal."

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
