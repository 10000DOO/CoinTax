#!/usr/bin/env bash
# 커밋될 파일에 개인정보·실거래 수치가 섞였는지 검사한다.
#
# 왜 필요한가: 실파일 자체는 .gitignore 로 막혀 있지만, **파서를 만들면서 실제 값을
# 주석·문서·테스트 단정값에 그대로 옮겨 적는 일**이 실제로 있었다. 원본을 막는 것만으로는
# 부족하고, 커밋 직전에 한 번 더 봐야 한다.
#
# 사용:
#   scripts/check-pii.sh            # 추적 파일 + 무시되지 않은 신규 파일 전체
#   scripts/check-pii.sh --staged   # 스테이징된 것만 (pre-commit 훅용)
#
# 훅으로 걸기:
#   ln -sf ../../scripts/check-pii.sh .git/hooks/pre-commit
set -uo pipefail

# git 훅으로 걸면 `$0` 이 `.git/hooks/pre-commit` 심볼릭 링크라
# `dirname "$0"/..` 은 저장소 루트가 아니라 `.git` 을 가리킨다 → git 에게 직접 물어본다.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) 신원 정보 — 형태로 잡는다 (특정인의 값을 스크립트에 적어두면 그 자체가 유출이다)
IDENTITY='[A-Za-z0-9._%+-]+@(gmail|naver|daum|kakao|hanmail|outlook|icloud)\.[a-z.]+'
IDENTITY="$IDENTITY|[0-9]{3}-[0-9]{2,4}-[0-9]{4}-[0-9]{3}"          # 국민은행식 계좌
IDENTITY="$IDENTITY|[0-9]{6}-[1-4][0-9]{6}"                          # 주민등록번호
IDENTITY="$IDENTITY|bc1[a-z0-9]{20,}"                                # BTC bech32 주소
IDENTITY="$IDENTITY|\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b"             # BTC legacy 주소
IDENTITY="$IDENTITY|\bT[A-Za-z0-9]{33}\b"                            # TRON 주소
IDENTITY="$IDENTITY|\b0x[a-fA-F0-9]{40}\b"                           # EVM 주소

FAIL=0

# macOS 기본 bash 는 3.2 라 mapfile 이 없다 — 임시 파일로 목록을 넘긴다
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
if [ "${1:-}" = "--staged" ]; then
  git diff --cached --name-only --diff-filter=ACM > "$LIST"
else
  { git ls-files
    git status --porcelain -uall | grep '^??' | cut -c4- | tr -d '"'
  } | sort -u > "$LIST"
fi

CHECK=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  case "$f" in
    docs/samples/raw/*|docs/raw/*|raw/*|scripts/check-pii.sh) continue ;;
  esac
  CHECK+=("$f")
done < "$LIST"
[ ${#CHECK[@]} -eq 0 ] && { echo "PII CHECK: 검사할 파일 없음"; exit 0; }

echo "== 1. 신원 정보 (이메일·계좌·주민번호·지갑주소) =="
if grep -nEI "$IDENTITY" "${CHECK[@]}" 2>/dev/null; then
  echo "   ↑ 커밋하면 안 됩니다"
  FAIL=1
else
  echo "   없음"
fi

# 2) 실거래 수치 — 실파일에 있는 숫자가 소스·문서로 옮겨졌는지 대조한다.
#    사람 눈으로는 못 잡는다. 실파일이 있는 동안에만 검사할 수 있다.
echo "== 2. 실거래 수치 유출 (실파일이 있을 때만) =="
RAW_ROOT=""
for d in docs/samples/raw docs/raw raw; do [ -d "$d" ] && RAW_ROOT="$d" && break; done

if [ -z "$RAW_ROOT" ]; then
  echo "   실파일 없음 — 건너뜀 (실파일이 있는 기기에서 한 번 돌려보세요)"
else
  TOKENS="$(mktemp)"
  # 실파일의 숫자를 뽑되 **식별력 있는 것만** 남긴다.
  #   - 뒤의 0 을 떼고도 유효숫자 6자리 이상인 소수  → 0.0001·0.000015·50000.00000000 같은
  #     상수·반올림 값은 걸러지고 9600.934027 같은 실거래 값만 남는다
  #   - 9자리 이상 정수 (거래소 id·UID)
  # 이 필터가 없으면 허용오차 상수까지 잡혀 경고가 무시당한다.
  grep -rhoE '[0-9]+\.[0-9]+|\b[0-9]{9,}\b' "$RAW_ROOT" --include='*.csv' 2>/dev/null \
    | awk '{
        t = $0
        if (index(t, ".") > 0) {
          sub(/0+$/, "", t); sub(/\.$/, "", t)
          d = t; gsub(/[.]/, "", d); sub(/^0+/, "", d)
          if (length(d) >= 6) print $0
        } else if (length(t) >= 9) print $0
      }' \
    | sort -u > "$TOKENS"
  COUNT=$(wc -l < "$TOKENS" | tr -d ' ')
  LEAKED="$(grep -nFf "$TOKENS" "${CHECK[@]}" 2>/dev/null || true)"
  rm -f "$TOKENS"
  if [ -n "$LEAKED" ]; then
    echo "$LEAKED"
    echo "   ↑ 실거래 값입니다. 가짜 값으로 바꾸거나 그 파일을 .gitignore 에 넣으세요"
    FAIL=1
  else
    echo "   없음 (대조한 실데이터 토큰 ${COUNT}개)"
  fi
fi

# 3) 원본 파일이 실수로 추적되고 있지 않은지
echo "== 3. 거래소 원본 파일 추적 여부 =="
TRACKED_RAW="$(git ls-files | grep -iE '\.(pdf|xlsx|xls)$|거래내역|입출금' || true)"
if [ -n "$TRACKED_RAW" ]; then
  echo "$TRACKED_RAW" | sed 's/^/   /'
  echo "   ↑ 추적 중입니다"
  FAIL=1
else
  echo "   없음"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PII CHECK OK"
else
  echo "PII CHECK FAILED — 위 항목을 정리한 뒤 커밋하세요"
fi
exit "$FAIL"
