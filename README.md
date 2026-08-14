# CoinTax

국내·해외 거래소 원본(PDF/XLSX/CSV)으로 **가상자산 기타소득** 예상 손익·세액을 정리하는 **macOS 15+** 로컬 앱입니다.

> **세무 자문이 아닙니다.** 신고 전 전문가·국세청 안내를 확인하세요.

## 기능 (MVP)

- 파서: 빗썸 확인서 PDF/텍스트, 바이낸스 Spot·Deposit·Withdraw XLSX, OKX Trading·Funding CSV, **제네릭 컬럼 매핑**
- 전송 매칭 (72h, 확정 후 원가 이전, 소실 원가 **abandon 미공제**)
- 원가: **거주자별 총평균법** (소득세법 시행령 §88① · 거래소·지갑 구분 없음)
- 의제: 2026-12-31 스냅샷 후 `max(장부, 시가)`
- 세금: 공제 250만, 국세 20% + 지방 2%, **Verify fail-closed export**
- 환율: **한국은행 ECOS 전용** (인증키 발급 안내 내장), 휴일·미고시 → **직전 고시일**(실제 고시일 기록), 수동·CSV 옵션
- Export: CSV / PDF (검증 통과 시에만)
- **세무 확인 화면**: 확정 해석이 없는 가정 28건 + 세무사에게 물어볼 질문 문장 (복사 가능)
- 필요경비 의제 50% (§37⑥): 자산별 on/off · **켰을 때·껐을 때를 나란히** 표시

## 문서

| 문서 | 내용 |
|------|------|
| [IMPLEMENTATION.md](./docs/IMPLEMENTATION.md) | 잠금값·구현 계약 |
| [01-requirements §10](./docs/01-requirements.md) | MVP 수용 기준 |
| [design/14-implementation-spec](./docs/design/14-implementation-spec.md) | 알고리즘·골든·DoD |
| [parsers/](./docs/parsers/) | 거래소 포맷 정본 |

## 검증 상태

단위 테스트 **55건 통과 · 컴파일 경고 0** (합성 fixture 기준).
실파일 확인이 남은 항목과 세무 결정 대기 항목은
[docs/fix-review-findings.md](./docs/fix-review-findings.md) §7-2 · §9 참조.
전체 교차 검토 리포트: [docs/review-2026-08-11.html](./docs/review-2026-08-11.html)

## 빌드·테스트

```bash
# Xcode
open CoinTax.xcodeproj

# CLI 스모크 (합성 fixture만, 실거래 raw 불필요)
chmod +x scripts/smoke.sh
./scripts/smoke.sh
```

실거래 파일은 `docs/samples/raw/` (gitignore). 합성은 `docs/samples/synthetic/`.

## CI

워크플로 정의: [`docs/ci/github-actions.yml`](./docs/ci/github-actions.yml) — `macos-15` 러너, 서명 없이 빌드·테스트.
(GitHub에 올리려면 PAT에 `workflow` scope가 필요합니다. 적용 방법은 [`docs/ci/README.md`](./docs/ci/README.md).)

로컬: `./scripts/smoke.sh`

## 면책

본 앱이 산출하는 세액·손익은 참고용입니다.
