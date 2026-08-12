# 13. 테스트 · 구현 로드맵

| 버전 | 2.0 |
|------|-----|
| 수치 정본 | [14-implementation-spec.md](./14-implementation-spec.md) §8 |

---

## 1. 테스트 피라미드

| 층 | 대상 |
|----|------|
| Unit | MA/FIFO, TransferCost abandon, Deemed max, Tax 공식, Verifier V-* |
| Golden | **G1 / G1b / G2** 수치 (14-spec §8) |
| Golden | G3 OKX Order 멀티레그 → 매매 1건 |
| Golden | G4 파서 헤더 detect (6 파서) |
| Integration | synthetic import → match → calc → verify |
| Regression | 엔진 fail-closed (재고 부족·코인 견적·링크 중복·제3자산 수수료) — `EngineFailClosedTests` |
| Regression | 파서 견고성 (BOM·중복 헤더·Type 누락·빗썸 2단 병합) — `ParserTests` |
| UI smoke | 미구현 (`CoinTaxUITests` 는 템플릿 상태이며 스킴에 포함되지 않음) |

**규약:** CostBasis/Tax PR에 Verifier 테스트 없으면 머지하지 않음.

---

## 2. 구현 Phase

| Phase | 산출 | 설계 문서 |
|-------|------|-----------|
| 0 | 폴더, PolicyBundle, Money/Decimal, macOS 15 | 01–04 |
| 1 | SwiftData project/events, Import generic | 09, 11 |
| 2 | 빗썸 PDF · 바이낸스 XLSX · OKX CSV 파서 | 09, 04-import |
| 3 | Matching | 09 |
| 4 | CostBasis MA+FIFO + TransferPolicy | 06, 04 |
| 5 | FX | 08 |
| 6 | Deemed + Holdings UI | 07, 12 |
| 7 | Tax + Integrity fail-closed | 07, 10, 06-integrity |
| 8 | Report export + disclaimers | 12 |

---

## 3. PR 순서 (권장)

1. skeleton + policies + TaxCopy  
2. persistence  
3. csv generic  
4. exchange presets  
5. matching  
6. cost basis + abandon policy tests  
7. fx  
8. deemed + holdings  
9. verifier (gate)  
10. tax report export  

---

## 4. 정책 변경 체크리스트 (세법 확정 시)

- [ ] 새 `TransferCostPolicy` 구현  
- [ ] G3 골든 추가  
- [ ] Verifier 분기  
- [ ] `PolicyBundle` id bump  
- [ ] `TaxCopy.transferCost` 문구 교체  
- [ ] 05-decisions / 03-tax-rules 한 줄 갱신  

엔진 루프·UI 골격은 **수정 최소화**.

---

## 5. 완료 정의 (설계 단계)

요구사항 MVP + 본 design/* 문서 합의 후 구현 착수.

### 5.1 현재 상태 (2026-08-11)

- 단위 테스트 **55건 · 실패 0 · 컴파일 경고 0**
- 실행: `./scripts/smoke.sh` (서명 없이도 동작)

### 5.2 남은 결정 (세무 확인 필요)

[../fix-review-findings.md](../fix-review-findings.md) §9 Q1~Q4:
의제취득가 lot별/평균 · 환율 공개 폴백 유지 여부 · 총수입금액 정의 · 세액 절사 규칙.

### 5.3 남은 구현

- UI 스모크 테스트 (export 잠금 상태 확인)
- 시가 자동 조회 소스
- SwiftData `VersionedSchema` (배포 전 필수)
