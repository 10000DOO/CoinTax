# CoinTax

국내·해외 거래소 CSV 거래내역을 바탕으로 **가상자산 기타소득** 신고 보조 자료와 **예상 세액**을 정리하는 macOS 앱입니다. (Swift / SwiftUI)

> **세무 자문이 아닙니다.** 예상 계산·기록 정리 도구입니다.

## 문서

설계·요구사항은 [`docs/`](./docs/README.md) 를 보세요.

| 문서 | 내용 |
|------|------|
| [요구사항](./docs/01-requirements.md) | 목표, 시나리오, 기능/비기능, MVP 수용 기준 |
| [설계](./docs/02-design.md) | 아키텍처, 도메인, UI, 로드맵 |
| [과세 규칙](./docs/03-tax-rules.md) | 기타소득 계산 가정 |
| [Import 포맷](./docs/04-import-formats.md) | PDF/XLSX/CSV 실측 정규화 |
| [설계 v2](./docs/design/README.md) | 아키텍처 → 상세 |
| [확정 결정](./docs/05-decisions.md) | 원가·환율·수수료·의제·보유 |
| [정합성 검증](./docs/06-integrity.md) | 계산 후 검증 필수 (세금) |

**1차 범위:** 빗썸 + 바이낸스/OKX 현물, macOS 15, 로컬 개인 사용.  
**원가:** 빗썸 이동평균 · 해외 FIFO. 전송 소실 원가 **미공제(보수, 정책 플러그인)**.  
**의제 취득가:** 전 이력 재생 후 max(실제, 2026-12-31 시가) 자동.  
**보유:** 코인·수량·평단 표시.  
**정합성:** Verify 통과 전 신고용 export 금지.  

**구현 시작:** [`docs/IMPLEMENTATION.md`](./docs/IMPLEMENTATION.md)  
**설계 본문:** [`docs/design/`](./docs/design/README.md) (01–14)

## 저장소

```bash
git remote -v
# origin  https://github.com/10000DOO/CoinTax.git
```

## 상태

- Xcode 템플릿 앱 스캐폴드 + 설계 문서 (구현 전)

## 면책

본 소프트웨어가 산출하는 세액·손익은 참고용이며, 신고 전 전문가 및 국세청 안내를 확인해야 합니다.
