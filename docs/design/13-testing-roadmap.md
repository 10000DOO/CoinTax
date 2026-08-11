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
| UI smoke | 런치, export disabled when blocked |

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

남은 구현 디테일만:

- FX 원격 벤더 1순위  
- 시가 자동 소스  
- 반올림 모드 최종 표기  

이상은 코드 착수와 병행 가능.
