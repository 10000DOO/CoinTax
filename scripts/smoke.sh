#!/usr/bin/env bash
# 합성 fixture 전용 스모크: 빌드 + 단위 테스트
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DD="${TMPDIR:-/tmp}/CoinTaxSmokeDerived"
rm -rf "$DD"
echo "== build-for-testing =="
xcodebuild -scheme CoinTax -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" build-for-testing | tail -5

echo "== test-without-building (CoinTaxTests) =="
log=$(mktemp)
(
  xcodebuild -scheme CoinTax -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" test-without-building \
    -only-testing:CoinTaxTests -parallel-testing-enabled NO >"$log" 2>&1
) &
pid=$!
for i in $(seq 1 90); do
  if grep -q "Test Suite 'All tests' passed" "$log" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -E "Executed [0-9]+ tests|failed \(" "$log" | tail -5
    echo "SMOKE OK"
    exit 0
  fi
  if grep -q "Test Suite 'All tests' failed" "$log" 2>/dev/null; then
    tail -40 "$log"
    exit 1
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 2
done
tail -40 "$log"
exit 1
