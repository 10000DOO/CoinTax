# CoinTax

국내·해외 거래소 원본(PDF/XLSX/CSV)으로 **가상자산 기타소득** 예상 손익·세액을 정리하는 **macOS 15+** 로컬 앱입니다.

> **세무 자문이 아닙니다.** 신고 전 전문가·국세청 안내를 확인하세요.

## 기능 (MVP)

- 파서: 빗썸 확인서 PDF/텍스트, 바이낸스 Spot·Deposit·Withdraw XLSX, OKX Trading·Funding CSV, **제네릭 컬럼 매핑**
- 전송 매칭 (72h, 확정 후 원가 이전, 소실 원가 **abandon 미공제**)
- 원가: 빗썸 **이동평균**, 해외 **FIFO**
- 의제: 2026-12-31 스냅샷 후 `max(장부, 시가)`
- 세금: 공제 250만, 국세 20% + 지방 2%, **Verify fail-closed export**
- 환율: **자동 조회 기본 ON** (ECOS 키 선택 / 공개 폴백), 휴일·미고시 → **직전 고시일**, 수동·CSV 옵션
- Export: CSV / PDF (검증 통과 시에만)

## 문서

| 문서 | 내용 |
|------|------|
| [IMPLEMENTATION.md](./docs/IMPLEMENTATION.md) | 잠금값·구현 계약 |
| [01-requirements §10](./docs/01-requirements.md) | MVP 수용 기준 |
| [design/14-implementation-spec](./docs/design/14-implementation-spec.md) | 알고리즘·골든·DoD |
| [parsers/](./docs/parsers/) | 거래소 포맷 정본 |

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

워크플로 정의: [`docs/ci/github-actions.yml`](./docs/ci/github-actions.yml)  
(GitHub에 올리려면 PAT에 `workflow` scope가 필요합니다. 적용 방법은 [`docs/ci/README.md`](./docs/ci/README.md).)

로컬: `./scripts/smoke.sh`

## 면책

본 앱이 산출하는 세액·손익은 참고용입니다.
