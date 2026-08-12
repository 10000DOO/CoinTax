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

재현을 위해 저장 (`SnapshotEntity`):

- `policyBundleID` (정책 번들은 프로토콜 존재 타입이라 JSON 직렬화 대상이 아님 — id 로 추적)
- `payloadJSON` = `TaxYearSummary` (검증 리포트·환율 출처·감사 필드 포함)
- `taxYear` · `status` · `calculatedAt`

재계산 시 이전 스냅샷은 **최근 10개**만 보관하고 초과분은 삭제한다
(`CalculationPipeline.snapshotHistoryLimit`).

### 3.1 스키마 변경

현재 `VersionedSchema`/`MigrationPlan` 은 없다. 필드 추가는 **선언부 기본값이 있는 속성**으로만 하고
(경량 마이그레이션 범위), 저장소를 열지 못하면 앱은 죽지 않고 메모리 모드로 실행하며 사유를 표시한다
(`CoinTaxApp.init`). 배포 전에는 버전 스키마 도입이 필요하다.

---

## 4. 백업

v1: 사용자가 프로젝트 export zip (선택). iCloud 없음.

---

## 5. 다음

[12-ui-navigation.md](./12-ui-navigation.md)
