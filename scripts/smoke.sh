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

# 판정은 **마지막 합계 줄**로 하되, 실패 줄이 하나라도 있으면 무조건 실패로 본다.
#
# 예전 규칙(`with [0-9]+ failures`)은 skip 이 섞인 합계
# ("with 3 tests skipped and 7 failures")에 안 걸렸다. 그러면 `tail -1` 이
# 아무 스위트 줄("with 0 failures")을 집어 **실패 7건을 SMOKE OK 로 보고했다.**
# 그래서 합계 파싱과 실패 줄 카운트를 **둘 다** 본다 — 한쪽이 형식 변화로 새면 다른 쪽이 잡는다.
SUMMARY="$(grep -aE "Executed [0-9]+ tests?, with .*(failure|failures)" "$LOG" | tail -1)"
FAIL_LINES="$(grep -acE "^Test Case .* failed \(" "$LOG" || true)"

if [ -z "$SUMMARY" ]; then
  echo "--- 테스트 결과를 판정할 수 없습니다 ---"
  tail -40 "$LOG"
  exit 1
fi

echo "$SUMMARY"

# 테스트 **프로세스가 죽으면** 실패 줄이 안 찍힌다.
#
# xcodebuild 는 죽은 자리에서 러너를 다시 띄우고, 죽은 테스트와 그 뒤에 있던 테스트들을
# 합계에서 통째로 빼 버린다. 그러면 "Executed 194 tests, with 0 failures" 처럼
# **정상 통과처럼 보이는 줄**이 남는다 (실제로 54건이 안 돌았는데 SMOKE OK 가 나왔다).
# 합계 줄만 보는 판정으로는 절대 못 잡으므로 재시작 흔적을 직접 본다.
if grep -aq "Restarting after unexpected exit, crash, or test timeout" "$LOG"; then
  echo "--- 테스트 도중 크래시/타임아웃이 있었습니다 (합계는 믿을 수 없습니다) ---"
  grep -aB3 "Restarting after unexpected exit" "$LOG" | grep -aE "Test Case .* started|Fatal error|Restarting" | tail -12
  exit 1
fi

# 테스트가 **조용히 사라지는** 것도 막는다.
#
# 파일이 타깃에서 빠지거나 스위트가 통째로 안 돌면 실패 없이 개수만 줄어든다.
# 이 앱의 품질 근거가 「N건 초록불」이므로, 개수가 줄면 그 자체가 회귀다.
# 새 테스트를 추가하면 이 값을 함께 올린다.
MIN_TESTS=324
COUNT="$(printf '%s' "$SUMMARY" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p')"
if [ -n "$COUNT" ] && [ "$COUNT" -lt "$MIN_TESTS" ]; then
  echo "--- 테스트가 $MIN_TESTS 건보다 적게 돌았습니다 ($COUNT 건) — 사라진 테스트가 있습니다 ---"
  exit 1
fi

if echo "$SUMMARY" | grep -qE "and 0 failures|with 0 failures" && [ "$FAIL_LINES" -eq 0 ]; then
  echo "SMOKE OK"
  exit 0
fi

echo "--- 실패 상세 (실패한 테스트 $FAIL_LINES 건) ---"
grep -aE "error:.*-\[CoinTaxTests|^Test Case.*failed" "$LOG" | head -40
exit 1
