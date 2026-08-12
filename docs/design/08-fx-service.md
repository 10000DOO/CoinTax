# 08. 환율 서비스

| 버전 | 1.0 |
|------|-----|

---

## 1. 역할

KRW 환산이 필요한 이벤트에 **거래일(KST 일자) 기준환율**을 제공한다.

우선순위:

1. 이벤트에 KRW 금액 있음 → FX 불필요  
2. 로컬 캐시 (당일 고시)  
3. **자동 원격 조회(기본 ON)** — **한국은행 ECOS 전용** (인증키 필요).
   공개 시세 폴백은 **기본 차단**이며, 켜면 사용 날짜가 리포트에 경고로 남는다 (TQ-05)  
4. 당일 미고시 → **직전 고시일** (`FXHolidayPolicy`)  
5. 그래도 없음 → missing dates → 수동/CSV → 계산 preflight 실패  

---

## 2. 인터페이스

```swift
protocol FXProvider {
    func rate(on day: Date, pair: CurrencyPair) -> Decimal?
    func source(on day: Date, pair: CurrencyPair) -> FXSourceMeta?
}

protocol FXService {
    func missingDays(required: Set<DayKey>, pair: CurrencyPair) -> [DayKey]
    func putManual(day: DayKey, pair: CurrencyPair, rate: Decimal)
    func importCSV(_ url: URL) throws
    func fetchRemote(days: [DayKey], pair: CurrencyPair) async throws  // 기본 자동
}
```

`FXSourceMeta`: `{ rate, sourceDate, origin: manual|cache|remote|previousBusinessDay }`

---

## 3. USDT

`FXAssumptionPolicy.treatUSDTAsUSD == true` (v1):

```text
USDT → KRW  :=  USD/KRW 기준환율 (당일)
```

---

## 4. 휴일·미고시일 (잠금)

| 항목 | 잠금값 |
|------|--------|
| policy id | `previous_published_rate_v1` |
| 당일 고시 있음 | 당일 기준환율, `sourceDate = eventDay` |
| 당일 고시 없음 (토·일·공휴일·미제공) | **직전 고시일** 기준환율, `sourceDate = 고시일`, `source=previousBusinessDay` |
| lookback | 최대 14 달력일 |
| 채택하지 않음 | 법인통칙 일부의 「공휴일 → **다음날**」 기장 규칙 |

### 근거 (공개 자료)

1. **국세청 서삼46015-11986 (2002.11.19)**  
   공급시기가 **공휴일**인 경우 「**그 전날**의 기준환율 또는 재정환율」로 환산.  
   (부가가치세 외화 환산 질의회신; 외화 환산 일반 취지로 준용)
2. 국세청 「거주자의 가상자산소득 과세 개요」: 외국통화 연동 기축가상자산은  
   「외국환거래법에 따른 **기준환율 또는 재정환율**」로 환산 — **휴일 전용 별도 조항 없음**  
   → 미고시일은 위 일반 환산 취지(직전 고시)로 통일.
3. 서울외국환중개 매매기준율은 **은행 영업일** 고시가 원칙 → 주말·공휴일은 통상 미고시.

구현: `FXHolidayPolicy` + 엔진 `rateFor` + Verifier **V-FX-03** (`sourceDate` 누락 시 warning).

---

## 5. 원격 소스

**확정: 한국은행 ECOS Open API** (통계표 `731Y001`, 항목 `0000001`, 주기 D).

- 인증키는 사용자가 발급해 Keychain 에 저장한다. 설정 화면에 발급 절차 5단계를 안내한다.
- 키가 없거나 응답이 비면 자동 조회를 하지 않고 수동 입력·CSV 를 안내한다 (앱은 계속 동작).
- `CompositeFXClient.Outcome` 으로 `noKey / keyRejected / publicFallbackUsed` 를 UI에 알린다.
- 공개 시세(`currency-api`)는 **외국환거래법상 기준환율이 아니다.** 기본 차단, 켜면 경고 표시.

**프라이버시:** 요청에 거래 목록·수량 넣지 않음. 날짜 배열 + 통화쌍만.

---

## 6. UI

- Settings: “환율 자동 채우기” 토글  
- Missing FX 시트: 날짜 | 필요 건수 | 입력칸  
- 리포트: 사용 환율 출처 요약  

---

## 7. 다음

[09-import-and-matching.md](./09-import-and-matching.md)
