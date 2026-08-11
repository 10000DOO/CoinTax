# 11. 영속화

| 버전 | 1.0 |
|------|-----|

---

## 1. 저장소

| 항목 | 선택 |
|------|------|
| 기술 | SwiftData |
| 위치 | `~/Library/Application Support/CoinTax/` |
| 단위 | Project 단위 격리 |

원본 CSV 사본: 사용자 동의 시 `Projects/{id}/imports/` (gitignore 대상 아님 — 로컬 only).

---

## 2. 엔티티 매핑

| SwiftData Entity | Domain |
|------------------|--------|
| ProjectEntity | Project |
| AccountEntity | Account |
| SourceFileEntity | format(pdf/xlsx/csv), parserId, sha256, metaJSON |
| LedgerEventEntity | LedgerEvent + sourceFile + sourceKind |
| TransferLinkEntity | TransferLink |
| FXRateEntity | FXRate |
| MarketPriceEntity | deemed 시가 |
| CalculationSnapshotEntity | summary + verification JSON |

Domain ↔ Entity **Mapper**만 Infrastructure에. Domain은 Entity 모름.

---

## 3. 계산 스냅샷

재현을 위해 저장:

- policyBundle JSON  
- summary JSON  
- verification JSON  
- calculatedAt  

재계산 시 이전 스냅샷은 이력으로 보관(최대 N개, v1 단순 덮어쓰기 가능).

---

## 4. 백업

v1: 사용자가 프로젝트 export zip (선택). iCloud 없음.

---

## 5. 다음

[12-ui-navigation.md](./12-ui-navigation.md)
