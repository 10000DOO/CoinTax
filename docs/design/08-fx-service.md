# 08. 환율 서비스

| 버전 | 1.0 |
|------|-----|

---

## 1. 역할

KRW 환산이 필요한 이벤트에 **거래일(KST 일자) 기준환율**을 제공한다.

우선순위:

1. 이벤트에 KRW 금액 있음 → FX 불필요  
2. 로컬 캐시 / 수동 입력  
3. 옵트인 원격 조회  
4. 그래도 없음 → missing dates → 계산 preflight 실패  

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
    func fetchRemote(days: [DayKey], pair: CurrencyPair) async throws  // 옵트인
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

## 4. 휴일

고시 없으면 **직전 영업일** rate, `sourceDate`에 실제 고시일 기록.  
Verifier: sourceDate 누락 시 warning.

---

## 5. 원격 소스

구현 시 1개 선택 (잔여 미결):

- 한국은행 등 공개 API  
- 실패 시 수동 전용으로 동작해야 함 (앱 사용 불가 상태 금지)

**프라이버시:** 요청에 거래 목록·수량 넣지 않음. 날짜 배열 + 통화쌍만.

---

## 6. UI

- Settings: “환율 자동 채우기” 토글  
- Missing FX 시트: 날짜 | 필요 건수 | 입력칸  
- 리포트: 사용 환율 출처 요약  

---

## 7. 다음

[09-csv-and-matching.md](./09-csv-and-matching.md)
