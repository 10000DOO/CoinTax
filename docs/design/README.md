# CoinTax 설계 문서 (Architecture → Detail)

요구사항·결정 이후 **큰 틀 → 세부**. **v2: 실측 원본 포맷 반영.**

## 원본 포맷 (구현 전제)

| 거래소 | 원본 | 파서 |
|--------|------|------|
| 빗썸 | **PDF** 거래내역 확인서 | PDF only (엑셀 없음) |
| 바이낸스 | **XLSX** Spot Trade History | 체결만 · 입출금 별도 |
| OKX | **CSV** Trading History | 메타 1행 · Spot + Transfer |

스키마: [../parsers/](../parsers/) · 총괄: [../04-import-formats.md](../04-import-formats.md)

## 읽기 순서

| 순서 | 문서 | 수준 | 내용 |
|------|------|------|------|
| 1 | [01-architecture.md](./01-architecture.md) | 큰 틀 | 컨텍스트, 레이어, 멀티포맷 입력 |
| 2 | [02-module-structure.md](./02-module-structure.md) | 구조 | `Import/` 모듈, DI |
| 3 | [03-domain-model.md](./03-domain-model.md) | 도메인 | LedgerEvent, TransferLink |
| 4 | [04-policies.md](./04-policies.md) | 정책 | 전송 수수료 플러그인 등 |
| 5 | [05-pipelines.md](./05-pipelines.md) | 흐름 | Import→Match→Calc→Verify |
| 6 | [06-cost-basis-engine.md](./06-cost-basis-engine.md) | 엔진 | MA / FIFO |
| 7 | [07-tax-deemed-holdings.md](./07-tax-deemed-holdings.md) | 세금 | 의제·세액·보유 |
| 8 | [08-fx-service.md](./08-fx-service.md) | 환율 | 기준환율 |
| 9 | [09-import-and-matching.md](./09-import-and-matching.md) | **Import** | PDF/XLSX/CSV 파서·매칭 |
| 10 | [10-integrity-engine.md](./10-integrity-engine.md) | 검증 | fail-closed |
| 11 | [11-persistence.md](./11-persistence.md) | 저장 | SwiftData · SourceFile.format |
| 12 | [12-ui-navigation.md](./12-ui-navigation.md) | UI | Import 포맷 배지 |
| 13 | [13-testing-roadmap.md](./13-testing-roadmap.md) | 구현 | Phase·PR |
| **14** | [14-implementation-spec.md](./14-implementation-spec.md) | **구현 계약** | 타입·알고리즘·골든·에러 |

## 다른 세션에서 구현할 때

**시작점:** [../IMPLEMENTATION.md](../IMPLEMENTATION.md)  
→ 그다음 **14-implementation-spec** + parsers/ + 05-decisions.

## 상위 문서

| 문서 | 역할 |
|------|------|
| [../IMPLEMENTATION.md](../IMPLEMENTATION.md) | **구현 핸드북 (최우선)** |
| [../01-requirements.md](../01-requirements.md) | 요구·MVP |
| [../03-tax-rules.md](../03-tax-rules.md) | 세금 가정 |
| [../04-import-formats.md](../04-import-formats.md) | Import 포맷 |
| [../05-decisions.md](../05-decisions.md) | 결정 |
| [../06-integrity.md](../06-integrity.md) | 검증 전문 |
| [../02-design.md](./02-design.md) | 요약 포인터 |

## 설계 버전

| 항목 | 값 |
|------|-----|
| 버전 | **2.1** (구현 명세 보강) |
| 일자 | 2026-08-11 |
| 플랫폼 | macOS 15+, Swift / SwiftUI, 로컬 개인 사용 |
