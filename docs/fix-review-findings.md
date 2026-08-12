# 리뷰 지적사항 일괄 수정

> 상태: `검증중` · 갱신: 2026-08-11 · 브랜치: `main` · 다음 액션: 7-2 사람 검증 7건 (실파일·서명 빌드 필요) 후 `완료` 전환
> 상태 단계(고정): `분석중` → `원인확정` → `설계확정` → `구현중` → `검증중` → `완료`
> ⚠️ 본문의 file:line은 드리프트할 수 있음 — 실행 전 반드시 심볼명으로 재확인할 것

---

## 0. 문서 규칙

`~/.claude/templates/ISSUE_TEMPLATE.md` 0장 규칙을 따른다. 본 건은 단일 버그가 아니라
[리뷰 리포트](./review-2026-08-11.html)에서 도출된 38개 카드의 일괄 수정이므로,
2~5장은 리뷰 리포트를 근거 문서로 대체하고 6장 WO 중심으로 운용한다.

---

# Part A — 분석·설계

## 1. 개요

- **출처**: `docs/review-2026-08-11.html` (문서 15개 + 코드 6,355줄 교차 검토)
- **범위**: 치명 5 · 높음 9 · 보통 9 · 낮음 4 · 문서 4묶음 · 자료조사 7 (→ 전부 처리, 세법 해석은 앱 「세무 확인」 18건으로 노출)
- **기준 커밋**: `2c3063b`
- **검토 시점 상태**: 빌드 성공 · 단위 테스트 43개 통과 (서명 비활성화 시)

## 2~4. 분석 / 근본 원인 / 영향 범위

→ [review-2026-08-11.html](./review-2026-08-11.html) 각 카드의 「근거 · 결과」 절이 정본.
카드 ID(1-1 … 8-7)를 WO의 `커버:` 키로 사용한다.

## 5. 수정 방향

### 5-1. 원칙

1. **세액에 영향 있는 것 먼저.** 조용히 틀린 숫자 > 눈에 보이는 오류.
2. **거래소별 관례 차이는 파서가 흡수한다.** 엔진은 정규화된 의미만 다룬다.
3. **잠금 문서(`IMPLEMENTATION.md`)와 코드가 어긋나면 코드를 문서에 맞춘다.**
   문서끼리 어긋나면 `IMPLEMENTATION.md` 우선(문서 §1 우선순위).
4. **예외로 계산을 죽이지 않는다.** fail-closed는 `blocked` 상태 + 이슈 목록으로 표현한다.
5. **세법 해석이 갈리는 것은 임의 결정하지 않는다** → 9장.

### 5-2. 폐기안

| 대안 | 폐기 이유 |
|---|---|
| OKX 파서에서 base 수수료를 그냥 버리기 | 수수료 추적 불가 → 감사 가능성(NF-05) 훼손 |
| 엔진에 거래소별 `switch` 추가 | 정책 플러그인 설계 위반(design/04-policies §2.2 "switch 난립 금지") |
| SwiftData `VersionedSchema` 전면 도입 | 릴리스 이력이 없어 스냅샷 근거 부재. `try!` 제거 + 안전 폴백으로 축소 |

---

# Part B — 작업 지시

## 6. 작업 지시서 (Work Orders)

| WO | 제목 | 커버 | 상태 |
|----|------|------|------|
| WO-1 | OKX 수수료 이중 차감 — 수량 순액 플래그 도입 | 1-1 | [x] |
| WO-2 | 견적 자산 환산 조건 수정 + 비USD 견적 누락 처리 | 1-2 | [x] |
| WO-3 | OKX Trading History Transfer 행 = 내부 이동 | 1-3 | [x] |
| WO-4 | 환율 출처 정직화 (되짚기 단일화 · sourceDate · 리포트 노출) | 1-4, 8-4 | [x] |
| WO-5 | 빗썸 PDF 2단 레이아웃 줄 병합 | 1-5 | [x] |
| WO-6 | 재고 부족을 예외 대신 Critical 이슈로 | 1-7 | [x] |
| WO-7 | 과세 대상 아닌 처분의 환율 요구 제거 | 1-8 | [x] |
| WO-8 | BNB 등 제3자산 수수료 처리 | 1-9 | [x] |
| WO-9 | 파서 견고성 (BOM · 헤더 중복 · 날짜 실패 경고 · Type 검증) | 2-2, 2-3, 4-1, 6-4 | [x] |
| WO-10 | 검증기 보강 (V-QTY/COST/DEM/FX/TAX/IMP/RE) | 3-1 | [x] |
| WO-11 | 매칭 1:1 강제 · 거부 유지 · 수동 매칭/해제 UI | 1-6, 2-4 | [x] |
| WO-12 | Import 중복 차단 · 임시파일 정리 | 4-3, 4-4 | [x] |
| WO-13 | Export (쓰기 권한 · PDF 다중 페이지 · CSV 형식) | 2-1, 4-5 | [x] |
| WO-14 | 결정성·상태 (정렬 · ForEach ID · 스냅샷 제한 · verified 판정) | 3-1, 4-6, 6-4 | [x] |
| WO-15 | 감사 추적 (환율/의제 출처 · TransferLink 원가 기록) | 3-1 | [x] |
| WO-16 | 구조·정리 (MainActor 기본값 · try! · 죽은 코드 · 경고 · 별칭 · 제네릭 TZ) | 4-2, 6-1, 6-4 | [x] |
| WO-17 | CI·스모크 (서명 비활성화 · macos-15) | 5-1, 5-2 | [x] |
| WO-18 | 문서 정정 (모순 4 · 오기·링크 6 · 사실 6 · MVP 체크 7) | 7-1~7-4 | [x] |
| WO-19 | Q1 의제 비교 단위 2안 지원 + 결과 비교 표시 | 8-1 | [x] |
| WO-20 | Q2 ECOS 전용 + 발급 안내 + 공개 시세 기본 차단 | 8-4 | [x] |
| WO-21 | Q3 총수입금액 총액 통일 | 8-6 | [x] |
| WO-22 | 세무 확인 항목 18건을 앱 화면·export에 노출 | 8-2·8-3·8-5·8-7 전부 | [x] |

세부 변경 내역은 10장 작업 로그 참조.

## 7. 검증 체크리스트

### 7-1. 에이전트 검증

- [x] 빌드: 클린 빌드 — 결과: **TEST BUILD SUCCEEDED · 컴파일 경고 0건**
      (변경 전에는 경고 4건 + "Swift 6 에서는 오류" 20건)
- [x] 단위 테스트: `./scripts/smoke.sh` — 결과: **Executed 98 tests, with 0 failures** (변경 전 43건)
- [x] 회귀: 골든 수치 불변 확인 — 결과: G1 `138,600 / 1,400` · G1b `1,472,280 / 147,228` · G2 `1,500` 모두 통과
- [x] 신규 테스트 12건 추가 후 통과 — 결과:
      `EngineFailClosedTests` 6건 (재고 부족·코인 견적·과거 매도 환율·링크 중복·BNB 수수료)
      `ParserTests` 6건 (OKX 순액 수량·중복 헤더·BOM·Type 누락·빗썸 2단 병합·추출 0건 오류)
- [x] 서명 없는 환경에서 스모크 재현 — 결과: `SMOKE OK` (기존 스크립트는 서명 오류로 실패했음)

### 7-2. 사람 검증 (에이전트 체크 금지)

- [ ] 서명된 빌드로 실행 → CSV/PDF 내보내기 저장 성공 (WO-13, 샌드박스 권한)
- [ ] 실제 빗썸 확인서 PDF import → 거래 행 추출 확인 (WO-5)
- [ ] 실제 OKX Trading + Funding 두 파일 동시 import → 보유 수량 검증 (WO-3)
- [ ] 전송 매칭 화면에서 수동 연결 / 해제 동작 확인 (WO-11)
- [ ] 한국은행 ECOS 인증키 발급 → 설정에 등록 → 「지금 자동 채우기」 정상 조회 확인 (WO-20)
- [ ] 설정에서 의제 산정 방식을 바꿔 재계산 → 리포트의 두 방식 비교 수치 확인 (WO-19)
- [ ] 「세무 확인」 화면 → 전체 질문 복사 → 세무사 전달 (WO-22)

## 8. 주의사항 (누적)

### 8.0 근거 강도 재점검 (2026-08-11 자기 검토)

수정의 근거가 **실측 문서**인지 **문서 안의 합성 예시**인지 다시 구분했다.
합성 예시에 근거한 것은 관례를 단정하지 않고 **데이터로 판정**하도록 바꿨다.

| 수정 | 근거 | 강도 | 조치 |
|------|------|------|------|
| OKX 수수료 이중 차감 | `okx-trading-history.md` **§6 합성 예시** 숫자 (0.01 − 0.00001 = 0.00999) | ⚠️ 약함 — 문서 작성자가 만든 값 | 파서가 `Amount`·`Fee`·`Balance Change` 관계로 **런타임 판정**. 판정 불가 시 기존 동작(총액) 유지 + 경고 |
| 바이낸스 `Amount` 는 총액 | `IMPLEMENTATION.md` §6.3 **잠금값** + 기존 코드 동작 | ✅ 강함 | 변경하지 않음 (기존 동작 유지) |
| OKX Transfer = 내부 이동 | OKX 계정 구조(입출금은 펀딩 지갑) + `okx-funding-history.md` §3 실측 Type 목록 | ⚠️ 보통 — 저장소 문서는 반대로 적혀 있었음 | 유지하되 Funding History 없으면 **V-IMP-04 Critical** 로 차단 |
| 빗썸 `거래금액 − 정산금액 = 수수료` | `bithumb-transaction-certificate.md` **§2.1 실측** | ✅ 강함 | 채택 |
| 환율 되짚기 단일화 | 코드 경로 자체 (`setRate` 의 `sourceDate ?? day`) | ✅ 강함 — 도메인 지식 불필요 | 채택 |
| 견적 자산 조건문 | Swift `||` 단축 평가 | ✅ 강함 — 기계적 사실 | 채택 |
| 재고 부족 → 이슈 | `06-integrity.md` §1 fail-closed 설계 | ✅ 강함 | 채택 |
| 자산 별칭 표 | 없음 (내 판단) | ❌ **틀렸음** | `WBTC`/`WETH`/`USDT.E`/`KRWT`/`IOTA` 및 네트워크 접미사 제거 **철회**. 서로 다른 자산을 합치는 오류였다 |

### 8.0.1 웹 근거 조사 결과 (2026-08-11)

거래소·법령 **1차 자료**로 확인한 내용. 조사 전에는 저장소 문서와 내 추론이 근거의 전부였다.

| 항목 | 확인 결과 | 출처 |
|------|-----------|------|
| OKX Trading History 의 Transfer | ✅ **내 수정이 맞음.** OKX: Trading History = "filled orders, trading fees, and **transfers related to trading**", Funding History = "**deposits, withdrawals**, P2P…, or transfers". 입출금은 Funding History 소관 → Trading 의 Transfer 는 외부 전송이 아니다. **저장소 문서(`okx-trading-history.md`)가 틀렸던 것** | OKX 「How do I download my statements?」 |
| 바이낸스 `Amount` 는 수수료 차감 전 | ✅ **기존 동작이 맞음.** "Trading fees are always charged in the asset you receive" — BTC/USDT 매수 시 수수료는 BTC(받는 자산)에서 차감되므로 실수령 = Amount − Fee. 엔진의 차감이 옳다 | Binance 「How to Calculate Binance Spot Trading Fees?」 |
| 바이낸스 **매도** 수수료 자산 | 매도는 받는 자산이 quote(USDT) → base 수수료가 붙는 경우는 사실상 없다. 내 `skipAsset` 변경은 무해하고 엔진·검증기 일치만 얻는다 | 위와 같음 |
| OKX `Balance Change` 가 순액인지 | ❓ **공개 정의 없음.** OKX 도움말·API 문서 모두 컬럼 의미를 정의하지 않는다 → **런타임 판정이 유일하게 옳은 대응** | OKX docs-v5 / 도움말 (정의 부재 확인) |
| 의제취득가 「시가」 정의 | ✅ **확정.** 소득세법 시행령 제88조제2항 — 시가고시 사업자 사업장에서 **2027-01-01 0시** 공시가격의 **평균**. 「2026-12-31 종가」가 아니다. 홈택스·손택스 「가상자산 일평균가격 조회」 제공 | 시행령 제88조제2항 · 국세청 |
| 의제 비교 단위 (lot vs 평균) | ❓ **법령·안내에 명시 없음** → 두 방식 지원이 옳은 대응 (TQ-01 유지) | 국세청 과세 개요 |
| 총수입금액 정의 | ✅ **총액 기준이 맞음.** 소득금액 = 양도·대여 대가 − 취득가액 − **부대비용**, 부대비용에 거래수수료 포함 → Q3 결정 타당. TQ-02 를 「근거 확인됨」으로 변경 | 국세청 과세 개요 |
| 손실 이월공제 | ✅ **불가 확정.** 금융투자소득과 달리 결손금 이월공제가 인정되지 않는다 → 앱 가정 맞음. TQ-16 을 「근거 확인됨」으로 변경 | 공개 해설 일치 |
| 원가법·공제·세율 | ✅ 가상자산주소별 이동평균/선입선출, 기본공제 250만원, 20% — 앱 잠금값과 일치 | 국세청 과세 개요 |
| 환율 | ⚠️ **새 변수 발견.** 2027년 1월부터 원/달러 매매기준율 산출이 **MAR → TWAP** 로 변경. 과세 시작과 겹침 → TQ-05 에 반영 | 외국환거래규정 개정 |

### 8.0.2 겹치는 파일 재import 점검 (2026-08-11)

「같은 거래소의 거래내역·입출금이 겹치면 한 번만 계산되는가」를 케이스별로 확인했다.

| 상황 | 조사 전 | 조치 |
|------|---------|------|
| 같은 파일을 두 번 | ✅ 파일 SHA-256 으로 거부 | 유지 |
| 바이낸스 입출금 기간 겹침 | ✅ TXID 로 걸러짐 | 유지 |
| OKX Trading/Funding 기간 겹침 | ✅ 행 `id`·`Order id` 로 걸러짐 | 유지 |
| OKX 같은 내부 이동이 두 파일에 | ✅ 양쪽 모두 `transferInternal` → 수량 불변 | 유지 |
| 빗썸 출금 ↔ 해외 입금 | ✅ 중복이 아니라 **두 거래소의 별개 이벤트** — 매칭으로 연결 | 유지 |
| **바이낸스 Spot 기간 겹침** | ❌ **중복 삽입** — 지문에 행 번호가 섞여 있어 행이 밀리면 다른 거래로 인식 | 내용키(행 번호 제외) + 개수 비교 도입 |
| **빗썸 확인서 기간 겹침** | ❌ 위와 동일 | 동일 |
| **제네릭 표 기간 겹침** | ❌ 위와 동일 (id 컬럼 없을 때) | 동일 |

같은 초·같은 수량의 **서로 다른** 체결이 합쳐지지 않도록 개수까지 맞춰 비교한다.
이미 쌓인 중복은 `V-IMP-05` 경고로 알린다.

### 8.0.3 3차 전수 점검 (2026-08-11) — 처음부터 다시 훑음

수정이 누적된 뒤 코드 전체를 다시 읽고 찾은 것. 9건 모두 수정 완료.

| # | 문제 | 왜 위험한가 | 조치 |
|---|------|-------------|------|
| G1 | **의제 시가 자산 코드가 장부 키와 다른 정규화를 씀** (`uppercased()` vs `AssetSymbol`) | 공백이 섞이거나 별칭 티커(XBT)를 입력하면 시가가 있는데도 「시가 누락」으로 **계산이 막힘** | 양쪽 모두 `AssetSymbol(...).code` 로 통일 |
| G2 | **무효한 확정 링크가 입금을 삼킴** — 출금 수량 0, 출금이 `ignored`, 이벤트 삭제 시 입금은 건너뛰고 입고도 안 됨 | 자산이 통째로 사라져 **보유·손익이 과소** | 링크 채택 전 양쪽 이벤트 존재·수량>0 검증, 실패 시 `V-QTY-03` Critical + 입금은 일반 입금으로 남김 |
| G3 | `TransferCostPolicy.apply` 의 `precondition` | 다른 호출부가 생기면 프로세스가 죽는다 | 안전한 결과 반환 + 사유 기록 |
| G4 | **다른 과세연도 처분이 조용히 빠짐** | 리포트는 한 해만 보여주므로 **다른 해 신고 누락** | `V-TAX-06` 경고 — "2028년 N건" 형태로 알림 |
| G5 | **소액 전송이 매칭 후보에서 탈락** — 10 USDT 전송에 수수료 1 USDT면 손실률 10%로 1% 창을 넘음 (문서 05-decisions §7.1 예시 자체가 해당) | 미매칭 → 취득원가 소멸 → **세액 과대** | 고신뢰 창(1%)은 유지하고, 최대 50%까지는 점수를 깎아 후보로 제시 + 「수수료 확인 필요」 표시 |
| G6 | **환율 필요일 계산이 수수료 환산분을 누락** | 원화 금액이 있는 매수라도 수수료가 USDT면 환율이 필요한데 자동 채우기 대상에서 빠져 Critical | `missingDays` 에 수수료 환산 필요일 추가 |
| G7 | **재고 부족이 하나 있으면 수량 대조를 전체 면제** | 다른 자산의 진짜 수량 불일치를 놓친다 | `shortfallKeys` 도입 — 해당 (계정\|자산)만 면제 |
| G8 | **데이터가 바뀐 뒤에도 낡은 검증 결과로 내보내기 가능** | 최신 자료라고 오해한 리포트가 나감 | import·매칭 변경 시 `calculationStale` → 배너 + 내보내기 잠금 |

| G9 | **정책 번들 사본이 두 곳에 있었다** — 설정에서 의제 방식을 바꾸면 파이프라인만 갱신되고 화면이 보는 정책은 이전 값 | 지금은 화면에 드러나지 않지만(표시하는 건 번들 id 뿐), 정책 값을 더 노출하면 **표시와 계산이 어긋난다** | `PolicyBundle.current` 한 곳에서만 만들고 화면·파이프라인 모두 그걸 읽는다. 저장 사본 제거. 기본값이 아닌 선택은 번들 id 에 표시(`cointax-v1.0+deemed_perLot`)해 과거 스냅샷과 구분 |

부수 정리: 사전 생성 시 중복 키 방어(`uniquingKeysWith`), 건별 의제의 채택 근거를 `mixed(n/m)` 로 표기,
공개 시세 경고를 **실제 사용된 고시일**로 한정(오탐 제거), PDF 비밀번호를 취소 시에도 즉시 삭제,
앱 시작 시 강제 종료로 남은 import 임시 사본 정리.

### 8.1 자기 검토에서 새로 찾은 결함 (내가 만든 것)

| # | 문제 | 영향 | 조치 |
|---|------|------|------|
| S1 | 별칭 표가 래핑·브릿지 토큰을 원본과 합침. `KRWT → KRW` 는 엔진이 원화로 보고 **원장에서 제외** | 취득 이력 혼입 / 자산 소실 | 표를 티커 동의어 3건으로 축소, 접미사 절단 삭제 |
| S2 | 매도 수수료가 기초자산일 때 엔진은 장부에서 빼고 검증기는 안 뺌 | 정상 계산에 **거짓 Critical** → 내보내기 잠김 | 매도도 매수와 같은 규칙(`skipAsset`) 적용 + 경고 |
| S3 | 의제 스냅샷 검사가 제3자산(BNB) 수수료 차감을 누락 | BNB 보유 사용자에게 **거짓 Critical** | 검증기 `preTaxQty` 에 제3자산 수수료 반영 |
| S4 | `scripts/smoke.sh` 가 개별 스위트 줄을 grep 해 **실패 2건을 통과로 판정** | 검증 자체를 신뢰할 수 없음 | 마지막 합계 줄만으로 판정. CI 워크플로도 동일 수정 |
| S5 | OKX 순액 판정이 `Trading Unit` 을 기준으로 삼아 견적 레그 수량까지 합산 | 판정 실패 → 경고 + 총액 처리 | 잔고가 움직인 레그(`Balance Unit == base`)만 합산 |
| S6 | 중복 판정 키에 행 번호(`rawRef`)가 들어 있어 기간이 겹치는 재export 가 중복 삽입됨 | 거래ID 없는 파서(바이낸스 Spot·빗썸·제네릭)에서 **보유·손익 과대** | 내용키 + 개수 비교로 분리, `V-IMP-05` 경고 추가 |

- `LedgerEventEntity`에 필드 추가 시 SwiftData 경량 마이그레이션 범위 내에서만 (기본값 있는 non-optional 또는 optional). 기존 저장소를 못 여는 변경 금지.
- 앱 타깃에만 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`가 걸려 있어 테스트 타깃과 격리 규칙이 다르다. 이 설정을 건드리면 테스트 경고 20건이 함께 움직인다.
- 로컬에 실거래 raw 샘플이 없다(`docs/samples/raw/` 부재). 빗썸 PDF 관련 변경은 **실파일 검증 불가** — 합성 fixture로만 검증했음을 항상 병기한다.
- 골든 테스트 수치(G1: 138,600 / 1,400 · G1b: 1,472,280 / 147,228 · G2: 1,500)는 문서 잠금값이다. 이 숫자가 바뀌는 변경은 문서 동시 갱신 없이는 금지.
- `xcodebuild test-without-building`이 출력 없이 종료되는 경우가 있다. `-xctestrun` 직접 지정이 안정적.

---

## 9. 미결 사항 (사용자 결정 필요 — 에이전트 임의 결정 금지)

**전부 결정 완료 (2026-08-11).** 세법 해석 자체는 여전히 확인이 필요하므로,
앱 안 **「세무 확인」 화면**(`TaxOpenQuestions`, 18항목)에 전부 남겨 화면·CSV·PDF에 노출한다.

| # | 질문 | 결정 | 구현 |
|---|---|---|---|
| Q1 | 의제취득가 비교 단위 | **두 방식 모두 지원.** 기본은 보수적인 「보유 전체 평균」, 설정에서 「매입 건별」로 전환. 리포트·설정에 다른 방식의 결과(의제취득가·소득·세액)와 차이를 함께 표시 | `DeemedBasisMode` · `CostBasisEngine` per-lot 경로 · `TaxYearSummary.deemedAlternative` · `DeemedBasisModeTests` |
| Q2 | 환율 원천 | **한국은행 ECOS 전용.** 공개 시세 폴백은 **기본 차단**, 켜면 사용된 날짜가 리포트에 경고로 남는다. 설정에 ECOS 인증키 발급 절차 5단계 안내 + 등록 여부 배지 | `FXPreferences.allowPublicFallback` (기본 false) · `CompositeFXClient.Outcome` · `SettingsView.ecosGuide` · 파이프라인 V-FX-02 warning |
| Q3 | 총수입금액 정의 | **총액으로 통일** (수수료는 필요경비). 빗썸도 「거래금액」을 양도가액으로 쓰고 (거래금액 − 정산금액)을 수수료로 분리. **세무 확인 항목으로 등록(TQ-02)** — 확인해야 할 내용은 그 항목의 질문 문장에 그대로 적어 두었다 | `BithumbCertificatePDFParser.makeEvent` · `GrossProceedsBasisTests` |
| Q4 | 세액 절사 | **1원 사사오입 유지** (v1 잠금값 그대로). 확인 항목으로 등록(TQ-03) | 변경 없음 |

### 9.1 앱에 남긴 확인 항목 (`Domain/Policies/TaxOpenQuestions.swift`)

「세무 확인」 사이드바 화면에서 볼 수 있고, 항목마다 **세무사에게 그대로 읽어 물어볼 질문 문장**을 담았다.
개별·전체 복사 버튼 제공. CSV·PDF export 에도 포함된다.

| 구분 | 항목 |
|------|------|
| 확인 필요 (14) | TQ-01 의제 비교 단위 · TQ-02 총수입금액 정의 · TQ-03 세액 절사 · TQ-04 지방소득세 기준 · TQ-05 환율 원천 · TQ-06 미고시일 환율 · TQ-07 전송 소실 원가 · TQ-08 USDT 페그 · TQ-09 코인 견적 환산 · TQ-10 의제 시가 정의 · TQ-11 미매칭 전송 취득가 · TQ-12 에어드롭·리베이트 · TQ-13 거래소 내부 이동 · TQ-14 예치금 이용료 |
| 개정 감시 (4) | TQ-15 시행일·세율·공제 · TQ-16 손실 이월 · TQ-17 총평균법 전환 · TQ-18 선물·마진 |

## 10. 작업 로그 (append-only)

### 2026-08-11 — 리뷰 후속 일괄 수정 세션

**한 일 (WO-1~22 전부 구현)**

| 영역 | 핵심 변경 | 파일 |
|------|-----------|------|
| 수량 규약 | `LedgerEvent.quantityIsNetOfFee` 도입 — 거래소별 「수수료 차감 전/후」 차이를 파서가 흡수 | `LedgerEvent` · `Entities` · `EntityMappers` · OKX 파서 · 엔진 |
| 환산 | USD 연동 견적만 환율 적용, 코인 견적은 Critical 보고 (임의 환산 금지) | `CostBasisEngine.krwFromQuote` |
| OKX | Trading History `Transfer` → `transferInternal` + 경고 | `OKXTradingHistoryCSVParser` |
| 환율 | 되짚기를 `FXHolidayPolicy` 한 곳으로. 원격은 고시일만 반환. 합성 행 저장 폐지 | `ECOSFXClient` · `FXService` |
| fail-closed | `disposeClamped` 추가, 예외 대신 `ReplayResult.issues` 수집 → 검증기 승계 → `blocked` | `AssetBook` · `CostBasisEngine` · `Verifier` · `CalculationPipeline` |
| 빗썸 | `mergeCertificateRows` — 날짜 시작 줄 기준 블록 병합 후 토큰 분류. 추출 0건은 오류 | `BithumbCertificatePDFParser` |
| 수수료 | 제3자산(BNB) 수수료를 그 자산 장부에서 처분해 부대비용 가산 | `CostBasisEngine.feeCostKRW` |
| 검증기 | 06-integrity §3 전 항목 구현 + 이슈 중복 제거 | `Verifier` |
| 매칭 | 1:1 배정 · 거부 유지 · `linkManually` / `unlink` + UI | `TransferMatchingEngine` · `MatchingService` · `MatchingView` |
| Import | 원본 바이트 SHA-256 중복 차단 · 파일 내 중복 차단 · 임시 사본 삭제 | `ImportService` · `ImportView` |
| 파서 견고성 | `CSVUtil.headerIndex` / `stripBOM` / `readText`, 날짜·Type 실패 경고 | 전 파서 |
| Export | entitlement `read-write`, PDF 다중 페이지, CSV 고정 5열, 환율 출처·주의사항 포함 | `CoinTax.entitlements` · 두 Exporter |
| 감사 | `DisposalRecord.fxRateUsed/fxSourceDate/deemedApplied`, `TransferLink` 원가 기록 | `TaxModels` · `CalculationPipeline` |
| 구조 | `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, `try!` 제거 + 메모리 폴백, 죽은 코드 제거 | `project.pbxproj` · `CoinTaxApp` · `XLSXReader` · `LocalFXCache` |
| 성능 | 화면 본문의 전체 이벤트 변환 제거 (Dashboard·Settings·Ledger), 원격 요청 상한 | 3개 View · `PublicUSDKRWClient` |
| 정규화 | 자산 별칭 표 + 네트워크 접미사 제거 (F-TX-02) | `Identifiers` |
| CI | `macos-15` · 서명 비활성화 · 실패 판정 강화 | `docs/ci/github-actions.yml` · `scripts/smoke.sh` |
| 문서 | 모순 4 · 오기·링크 6 · 사실 6 · MVP 체크 7 정정, 모듈 트리 실제화 | `docs/**` |
| 의제 2안 | `DeemedBasisMode` (평균/건별) + 미채택 방식 결과 동시 계산 → 리포트·설정 비교 표시 | `DeemedCostPolicy` · `AssetBook.replaceLots` · `CostBasisEngine` · `CalculationPipeline` |
| 환율 원천 | ECOS 전용 + 발급 안내 5단계 + 공개 시세 기본 차단(켜면 경고) | `ECOSFXClient` · `FXPreferences` · `SettingsView` |
| 총수입금액 | 총액 기준 통일 (빗썸 거래금액 − 정산금액 = 수수료 분리) | `BithumbCertificatePDFParser` |
| 세무 확인 | 18항목 + 질문 문장 + 복사 기능. 사이드바 화면 신설, CSV·PDF 포함 | `TaxOpenQuestions` · `TaxOpenQuestionsView` · `RootSplitView` · 두 Exporter |

**알아낸 것**

- 바이낸스 `Amount`는 수수료 차감 **전**, OKX `Balance Change`는 차감 **후**.
  동일 엔진 규칙을 두 관례에 적용한 것이 1-1의 근본 원인이었다. 파서가 관례를 흡수해야 한다.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 한 줄 제거로 6-1과 테스트 경고 20건이 동시에 해소됐다.
  도메인 코드에 `@MainActor` 를 붙인 곳이 없어 부작용이 없었다.
- 저장소의 빗썸 합성 fixture(`bithumb_certificate_sample.txt`)는 출금 후 매도로 재고가 비는 구조라
  기존 엔진에서는 계산이 예외로 죽었다. fail-closed 전환으로 이제 이슈 목록이 나온다.
- `xcodebuild test-without-building` 이 출력 없이 종료되는 문제는 `-xctestrun` 직접 지정으로 우회된다.

**바뀐 결정**: 없음. Q1~Q4는 미결 유지 — 현행 동작 + `// DECISION Q1` 주석(`CostBasisEngine` 의제 블록) 및
리포트 「주의사항」 문구로 노출.
