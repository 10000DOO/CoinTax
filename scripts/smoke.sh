#!/usr/bin/env bash
# 합성 fixture 전용 스모크: 빌드 + 단위 테스트
#
# 개발자 인증서가 없는 환경(다른 머신·CI)에서도 돌아야 하므로 서명을 끄고 빌드한다.
# 서명된 빌드가 필요한 검증(샌드박스 권한으로 export 저장 등)은 Xcode 에서 직접 실행할 것.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DD="${TMPDIR:-/tmp}/CoinTaxSmokeDerived"
rm -rf "$DD"

SIGNING_OFF=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  CODE_SIGN_ENTITLEMENTS=
  DEVELOPMENT_TEAM=
)

echo "== PII 검사 =="
# 실파일 자체는 .gitignore 로 막혀 있지만, 파서를 만들면서 실제 값을 주석·문서·테스트로
# 옮겨 적는 일이 실제로 있었다. 빌드 전에 한 번 걸러낸다.
"$ROOT/scripts/check-pii.sh" | tail -8

echo "== build-for-testing =="
xcodebuild -scheme CoinTax -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" "${SIGNING_OFF[@]}" build-for-testing | tail -3

echo "== test (CoinTaxTests) =="
RUN="$(ls "$DD"/Build/Products/*.xctestrun | head -1)"
LOG="$(mktemp)"
xcodebuild -xctestrun "$RUN" -destination 'platform=macOS,arch=arm64' \
  -only-testing:CoinTaxTests -parallel-testing-enabled NO \
  test-without-building >"$LOG" 2>&1 || true

# 판정은 **마지막 합계 줄**로만 한다.
# 개별 스위트 줄에도 "with 0 failures" 가 나오므로, 아무 줄이나 grep 하면 실패를 놓친다.
SUMMARY="$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$LOG" | tail -1)"

if [ -z "$SUMMARY" ]; then
  echo "--- 테스트 결과를 판정할 수 없습니다 ---"
  tail -40 "$LOG"
  exit 1
fi

echo "$SUMMARY"
if echo "$SUMMARY" | grep -qE "with 0 failures"; then
  echo "SMOKE OK"
  exit 0
fi

echo "--- 실패 상세 ---"
grep -E "error:.*-\[CoinTaxTests|^Test Case.*failed" "$LOG" | head -40
exit 1
