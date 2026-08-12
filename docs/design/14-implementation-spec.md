# 14. 구현 명세 (알고리즘 · 타입 · 골든 · 에러)

| 버전 | 1.0 |
|------|-----|
| 상위 | [../IMPLEMENTATION.md](../IMPLEMENTATION.md) |

이 문서는 **코드로 옮길 수 있는 수준**의 계약이다. 모호하면 이 문서의 잠금값을 따른다.

---

## 1. 전체 타입 필드 (Swift 스케치)

구현 시 이름 변경 가능하나 **필드 의미·필수**는 유지.

```swift
// MARK: - IDs
struct ProjectID: Hashable, Codable { var raw: UUID }
struct AccountID: Hashable, Codable { var raw: UUID }
struct EventID: Hashable, Codable { var raw: UUID }
struct SourceFileID: Hashable, Codable { var raw: UUID }
struct LinkID: Hashable, Codable { var raw: UUID }

enum VenueKind: String, Codable { case domestic, overseas, unknown }
enum ExchangeCode: String, Codable { case bithumb, binance, okx, generic }
enum CostBasisMethod: String, Codable { case movingAverage, fifo }
enum EventType: String, Codable {
    case buy, sell, deposit, withdrawal, fee, income
    case transferInternal  // OKX funding↔trading 등
    case fiatDeposit, fiatWithdraw  // KRW
    case other, ignored
}
enum LinkStatus: String, Codable { case suggested, confirmed, rejected }
enum SummaryStatus: String, Codable { case draft, verified, blocked }
enum SourceFormat: String, Codable { case pdf, xlsx, csv, text, unknown }

struct AssetSymbol: Hashable, Codable {
    var code: String  // uppercased "USDT","BTC","KRW"
    // 대문자화 + 네트워크 접미사 제거 + 별칭 표 적용 (F-TX-02): XBT→BTC, USDT-TRC20→USDT …
    init(_ s: String) { /* Domain/Models/Identifiers.swift 참조 */ }
}

struct Project: Identifiable, Codable {
    var id: ProjectID
    var name: String
    var createdAt: Date
    var defaultTaxYear: Int
    var notes: String?
    var lastPolicyBundleID: String?
}

struct Account: Identifiable, Codable {
    var id: AccountID
    var projectID: ProjectID
    var exchangeCode: ExchangeCode
    var venueKind: VenueKind
    var displayName: String
    var costMethod: CostBasisMethod
}

struct SourceFile: Identifiable, Codable {
    var id: SourceFileID
    var projectID: ProjectID
    var fileName: String
    var format: SourceFormat
    var parserID: String
    var sha256: String
    var importedAt: Date
    var meta: [String: String]  // timezone, period, ignoredCount…
}

struct LedgerEvent: Identifiable, Codable {
    var id: EventID
    var projectID: ProjectID
    var accountID: AccountID
    var sourceFileID: SourceFileID?
    var externalID: String?
    var fingerprint: String          // 중복 제거 키
    var timestamp: Date              // UTC absolute
    var type: EventType
    var baseAsset: AssetSymbol
    var quoteAsset: AssetSymbol?
    var quantity: Decimal            // signed, § IMPLEMENTATION
    var price: Decimal?              // quote per base
    var quoteAmount: Decimal?        // in quote asset
    var quoteAmountKRW: Decimal?     // if known
    var feeAmount: Decimal?          // abs value
    var feeAsset: AssetSymbol?
    var network: String?
    var addressHash: String?
    var txidHash: String?
    var memo: String?
    var counterpartyHint: String?    // "binance" from 비고
    var sourceKind: String           // parser id
    var rawRef: String?              // "page3-row12" / "row5"
    var needsFX: Bool
    var quantityIsNetOfFee: Bool     // 원본 수량이 이미 수수료 차감 후인지 (OKX=true, 바이낸스=false)
}

struct TransferLink: Identifiable, Codable {
    var id: LinkID
    var projectID: ProjectID
    var fromEventID: EventID         // withdrawal
    var toEventID: EventID           // deposit
    var status: LinkStatus
    var withdrawnQty: Decimal        // abs
    var receivedQty: Decimal         // abs
    var score: Double?
    var note: String?
    // filled after calc:
    var transferredCostKRW: Decimal?
    var abandonedCostKRW: Decimal?
}

struct FXRate: Codable {
    var day: String                  // "yyyy-MM-dd" KST calendar for pairing
    var pair: String                 // "USD/KRW"
    var rate: Decimal
    var source: String               // manual|cache|remote|previousBusinessDay
    var sourceDate: String?          // actual quote day if rolled
}

struct MarketPrice: Codable {
    var asOf: String                 // "2026-12-31"
    var asset: AssetSymbol
    var priceKRW: Decimal
    var source: String
}

struct DisposalRecord: Codable, Identifiable {
    var id: UUID
    var eventID: EventID
    var timestamp: Date
    var accountID: AccountID
    var asset: AssetSymbol
    var quantity: Decimal            // abs sold
    var proceedsKRW: Decimal
    var costKRW: Decimal
    var feesKRW: Decimal
    var pnlKRW: Decimal              // proceeds - cost - fees
    var method: CostBasisMethod
    var taxYear: Int
    // 감사 추적 (06-integrity §2.3)
    var fxRateUsed: Decimal?         // 양도가 환산에 쓴 USD/KRW (원화 직기입이면 nil)
    var fxSourceDate: String?        // 그 환율의 실제 고시일 (휴일 대체 시 직전 고시일)
    var deemedApplied: Bool          // 의제취득가로 재기동된 뒤의 처분인지
}

struct DeemedPosition: Codable {
    var accountID: AccountID
    var asset: AssetSymbol
    var quantity: Decimal
    var bookUnitKRW: Decimal
    var marketUnitKRW: Decimal?
    var deemedUnitKRW: Decimal
    var reason: String               // "actual" | "market"
}

struct HoldingsRow: Codable {
    var accountID: AccountID?
    var asset: AssetSymbol
    var quantity: Decimal
    var averageUnitKRW: Decimal
    var totalCostKRW: Decimal
    var method: CostBasisMethod?
}

struct HoldingsSnapshot: Codable {
    var asOf: Date
    var rows: [HoldingsRow]          // per account+asset
    var aggregated: [HoldingsRow]    // accountID nil
}

struct TaxYearSummary: Codable {
    var projectID: ProjectID
    var taxYear: Int
    var status: SummaryStatus
    var policyBundleID: String
    var totalProceedsKRW: Decimal
    var totalCostsKRW: Decimal       // cost + fees + deductibleExpense
    var netIncomeKRW: Decimal
    var basicDeductionKRW: Decimal
    var taxBaseKRW: Decimal
    var nationalTaxKRW: Decimal
    var localTaxKRW: Decimal
    var totalTaxKRW: Decimal
    var abandonedTransferCostKRW: Decimal
    var disposals: [DisposalRecord]
    var deemed: [DeemedPosition]
    var disclaimers: [String]
    var calculatedAt: Date
    var verification: VerificationReport?
    var fxSources: [String]          // 적용 환율 출처 요약 (리포트·export 노출)
}

struct VerificationIssue: Codable, Identifiable {
    var id: String                   // "V-QTY-02"
    var severity: String             // critical|warning|info
    var message: String
    var context: String?
}

struct VerificationReport: Codable {
    var runID: UUID
    var status: String               // passed|passedWithWarnings|failed
    var issues: [VerificationIssue]
    var calculatedAt: Date
}
```

### Account 생성 시 costMethod

```text
bithumb → movingAverage, venue=domestic
binance → fifo, venue=overseas
okx → fifo, venue=overseas
generic → 사용자 선택 (기본 fifo)
```

---

## 2. PolicyBundle.v1Default

```swift
PolicyBundle(
  id: "cointax-v1.0",
  transferCost: "abandon_lost_cost",
  costMethodResolver: "vasp_ma_else_fifo",
  deemed: "max_book_market_2026-12-31",
  taxRate: "kr_other_20_2_deduct_2_5m",
  rounding: "plain_krw_1",
  fxAssumption: "usdt_eq_usd",
  disclaimers: [TaxCopy.notTaxAdvice, TaxCopy.transferCost, TaxCopy.usdtPeg, TaxCopy.costMethods]
)
```

`AbandonLostCostPolicy.apply`:

```text
require withdrawnQty > 0
ratio = receivedQty / withdrawnQty
// clamp ratio to [0, 1]
transferredCostKRW = outboundCostKRW * ratio
abandonedCostKRW = outboundCostKRW - transferredCostKRW
// if explicitFeeCostKRW provided, add to abandoned, not to transferred
deductibleExpenseKRW = 0
```

---

## 3. Import 알고리즘

### 3.1 공통

```text
function importFile(url, project, accountHint?):
  probe = FormatProbe.probe(url)
  candidates = Registry.all.map { ($0, $0.detect(probe)) }.filter score>0.3
  sort by score desc
  parser = userPick or top if score >= 0.85
  if parser is withholding-bithumb: reject with E_NOT_TRADE_DOC
  result = parser.parse(url, account)
  for e in result.events:
    e.fingerprint = makeFingerprint(e)
    if exists fingerprint in project: skip (dedupe)
    else insert
  save SourceFile meta
  run matching.suggest async
  return result
```

### 3.2 Fingerprint · 중복 제거

**두 개의 키를 쓴다.**

```text
// ① fingerprint — 원본 위치까지 포함한 고유 식별 (감사·추적용)
if externalID nonempty:
  fp = accountID + "|" + parserID + "|ext|" + externalID
else:
  fp = accountID + "|" + parserID + "|h|" + sha256(
        iso8601(timestamp) + type + base + qty + (price??) + (quoteAmount??) + (fee??) + (rawRef??)
      )

// ② contentKey — **행 번호를 뺀 내용 기준 키** (중복 판정용)
if externalID nonempty:
  key = accountID + "|" + parserID + "|ext|" + externalID
else:
  key = accountID + "|" + parserID + "|c|" + sha256(
        iso8601(timestamp) + type + base + quote + qty + (price??) + (quoteAmount??) + (quoteAmountKRW??) + (fee??)
      )
```

**왜 두 개인가** — `rawRef`(행 번호)를 중복 판정에 쓰면, 기간이 겹치는 export 를 다시 가져올 때
같은 거래가 다른 행 번호를 달고 와서 중복으로 쌓인다. 거래ID가 없는
바이낸스 Spot·빗썸 확인서·제네릭에서 실제로 발생한다.

**개수까지 맞춰서 비교한다.** 같은 초에 같은 수량·가격으로 체결된 **서로 다른** 두 건이 있을 수 있으므로,
내용키별로 세어 `기존 개수`를 넘는 만큼만 새로 넣는다.

```text
existing[key] = 프로젝트에 이미 있는 같은 내용의 건수
for e in incoming:
  n[key] += 1
  if n[key] <= existing[key]: skip      // 이미 있는 만큼은 건너뛴다
  else: insert                          // 늘어난 만큼만 넣는다
```

같은 externalID 인데 수량이 다르면(기간 경계에서 잘린 주문 등) 기존 값을 유지하고 경고한다.

파일 단위로는 **원본 바이트 SHA-256** 이 같으면 import 자체를 거부한다 (`E_DUPLICATE_FILE`).

검증기 `V-IMP-05`: 같은 내용의 거래가 **서로 다른 파일**에서 발견되면 경고
(이 규칙 도입 전에 쌓인 데이터 대비).

### 3.3 바이낸스 Spot

[parsers/binance-spot-trade-history.md](../parsers/binance-spot-trade-history.md)

```text
BUY: type=buy, qty=+Amount, quote=Total USDT, price=Price
SELL: type=sell, qty=-Amount, ...
feeAmount=Fee, feeAsset=FeeCoin
timestamp = parse "yyyy-MM-dd HH:mm:ss" as UTC (header Date(UTC))
```

### 3.4 바이낸스 Deposit

```text
type=deposit, qty=+Amount, base=Coin
timestamp = parse "yy-MM-dd HH:mm:ss" as UTC  // 2-digit year → 20xx
Status != Completed → ignored
addressHash=sha256(Address), txidHash=sha256(TXID), externalID=TXID
network=Network
// NO fee column
```

### 3.5 바이낸스 Withdraw

```text
type=withdrawal, qty=-Amount
feeAmount=Fee, feeAsset=Coin
Status Completed only
timestamp yy-MM-dd UTC
```

### 3.6 OKX Trading History

[parsers/okx-trading-history.md](../parsers/okx-trading-history.md)

```text
meta = parse line0 → timezone (e.g. UTC+8)
header = line1
rows = rest

// Spot: group by Order id
for each orderId group:
  baseAsset, quoteAsset = split Symbol "BTC-USDT"
  baseLegs = rows where Balance Unit == base (or Action Buy with base)
  quoteLegs = rows where Balance Unit == quote
  // Preferred synthesis (v1 lock):
  netBase = sum(Balance Change where Balance Unit == base)
  netQuote = sum(Balance Change where Balance Unit == quote)
  feeBase = sum(abs(Fee) where Fee Unit == base)
  // If netBase > 0: buy base with cost = abs(netQuote) in USDT
  // If netBase < 0: sell base proceeds = abs(netQuote)
  // LOCK: Balance Change 는 수수료가 이미 빠진 순증분 → quantityIsNetOfFee = true 로 표시.
  //       (바이낸스 Amount 는 차감 전이므로 false. 엔진이 base 수수료를 두 번 빼면 수량이 이중 축소된다.)
  // Use Filled Price from any leg as price
  emit one buy OR one sell (+ fee fields)
  // Do NOT emit 4 raw legs as 4 trades

// Transfer:  ※ 거래 계정 ↔ 펀딩 계정 **내부 이동**이다 (외부 입출금은 Funding History 담당)
  Action Transfer in  → transferInternal, qty = +abs(Balance Change), asset = Balance Unit
  Action Transfer out → transferInternal, qty = -abs(Balance Change)
  // deposit/withdrawal 로 잡으면 Funding History 와 함께 import 할 때 같은 이동이 이중 반영된다.
```

### 3.7 OKX Funding History

[parsers/okx-funding-history.md](../parsers/okx-funding-history.md)

```text
Deposit / Received → deposit +Amount
Withdrawal → withdrawal (Amount already negative)
From unified trading account → transferInternal +
To unified trading account → transferInternal -
Fee rebate → income +
timestamp with meta TZ
```

### 3.8 빗썸 PDF

[parsers/bithumb-transaction-certificate.md](../parsers/bithumb-transaction-certificate.md)

```text
// Implementation strategy v1:
// 1) PDFKit page string extraction OR Vision if needed
// 2) Split lines; merge date line + time line
// 3) Detect rows starting with yyyy-MM-dd
// 4) Parse columns by regex / fixed positions from sample layout
// 5) Unit line follows (USDT/KRW)

map:
  매수 → buy, qty=+거래수량, quoteAmountKRW=abs(정산금액), price=체결가격
  매도 → sell, qty=-거래수량, quoteAmountKRW=정산금액 (양수 유입)
  입금 + asset!=KRW → deposit
  출금 + asset!=KRW → withdrawal, counterpartyHint from 비고 (바이낸스→binance)
  KRW 입금/출금 → fiatDeposit/fiatWithdraw
  비고 contains 예치금 이용료 → income/fiat tag, exclude from crypto tax disposals

password PDFs: unlock with user password before extract
reject if title is 원천징수영수증
```

**합성 fixture:** 실 PDF 커밋 금지. `docs/samples/synthetic/bithumb_certificate_sample.txt` 에 표 형태 텍스트를 두고 파서가 텍스트 입력 모드를 지원하거나, 테스트 전용 미니 PDF 생성 스크립트 사용.

---

## 4. 매칭 알고리즘 (상세)

```text
candidates = []
for w in withdrawals where asset not KRW and not already linked confirmed:
  for d in deposits where asset == w.asset and not linked:
    if d.account == w.account: continue // 같은 계정 스킵(내부는 transferInternal)
    dt = abs(d.timestamp - w.timestamp)
    if dt > 72h: continue
    wQty = abs(w.quantity)
    dQty = abs(d.quantity)
    if dQty > wQty * 1.0001: continue  // 입고가 출고보다 유의미하게 크면 제외
    lost = wQty - dQty
    // allow lost up to max(wQty * 0.01, fee if known, 1e-6)  // 정본: ../IMPLEMENTATION.md §7
    if lost < 0: continue
    score = 0
    score += 1.0 - min(dt / 72h, 1) * 0.5
    score += (1 - lost/wQty) * 0.3
    if w.venue==domestic && d.venue==overseas: score += 0.15
    if d.venue==domestic && w.venue==overseas: score += 0.15
    if w.counterpartyHint matches d.exchange: score += 0.2
    if txid/address hash overlap: score += 0.5
    candidates.append(score, w, d)

suggest top per withdrawal if score >= 0.35
user confirms → LinkStatus.confirmed
```

---

## 5. 원가 엔진 (전체 루프)

```text
function replay(events, links, policies, fx, marketPrices, options):
  books = Map<AccountID, Map<Asset, AssetBook>>()
  disposals = []
  abandonedTotal = 0
  extraDeductible = 0
  deemedApplied = false
  deemedPositions = []

  confirmed = links where status==confirmed
  linkByFrom = index by fromEventID

  events = events.filter type not in {ignored}
           .sorted by (timestamp asc, id asc)

  T_deemed_end = 2026-12-31 15:00:00 UTC  // = 2027-01-01 00:00 KST exclusive end of day
  // Lock: treat "as of end of 2026-12-31 KST" as timestamp < 2027-01-01 00:00:00 KST
  T_tax_start = 2027-01-01 00:00:00 KST as Date

  function ensureBook(acc, asset):
    method = account.costMethod
    return books[acc][asset] or create(method)

  function costKRWForBuy(event):
    if event.quoteAmountKRW != nil: return abs(event.quoteAmountKRW)
    // else FX path
    usdt = abs(event.quoteAmount ?? event.quantity * event.price)
    rate = fx.rate(dayKST(event.timestamp), "USD/KRW")
    if rate nil: record Critical V-FX-01 (throw 하지 않는다 — 계산은 끝까지 진행)
    if quoteAsset 이 USDT/USD/KRW 가 아니면: record Critical V-FX-01 (임의 환산 금지)
    return usdt * rate + feeKRW(event)

  function feeKRW(event): ...

  for e in events:
    // Deemed once when first event at/after tax start is about to process
    // Better: after processing all events with timestamp < T_tax_start, apply deemed once
    ...

  // Two-pass clearer implementation LOCK:

  pass1 = events where timestamp < T_tax_start
  pass2 = events where timestamp >= T_tax_start

  process(pass1)  // no disposals count for tax, still track books
  // apply deemed:
  for each (acc, asset, book) where book.qty > 0:
    market = marketPrices[asset]
    if market nil: mark missingDeemed
    bookUnit = book.totalCost / book.qty
    deemedUnit = max(bookUnit, market)
    reason = deemedUnit == bookUnit ? "actual" : "market"
    deemedPositions.append(...)
    book.reset(); book.acquire(book.qty, deemedUnit * book.qty)  // careful: save qty first
  if any missingDeemed && qty>0: status can be blocked later

  process(pass2):
    on sell:
      cost = book.dispose(abs(qty))
      proceeds = sellProceedsKRW(e)
      fees = sellFeeKRW(e)
      pnl = proceeds - cost - fees
      if e.timestamp >= T_tax_start:
        disposals.append(...)
    on buy:
      book.acquire(abs(qty), costKRWForBuy(e))
    on deposit:
      if linked as 'to' side of confirmed: skip acquire here (done at withdrawal processing)
      else: acquire with cost 0 or needs cost basis warning (external deposit unknown cost → cost 0 + warning)
    on withdrawal:
      if confirmed link:
        wQty = abs(e.quantity)
        d = link.to event
        rQty = abs(d.quantity)
        outboundCost = book.dispose(wQty)  // dispose full withdrawn including portion that will be abandoned
        // Actually: dispose wQty from book; cost is full outbound
        result = transferPolicy.apply(outboundCost, wQty, rQty, feeCost)
        abandonedTotal += result.abandoned
        extraDeductible += result.deductible
        destBook.acquire(rQty, result.transferredCost)
      else:
        // unmatched external out: dispose qty, cost abandoned from portfolio (realized loss? LOCK: treat as non-taxable movement of inventory write-off without disposal income — cost disappears, abandonedTotal += cost, NO disposal record)
        cost = book.dispose(abs(qty))
        abandonedTotal += cost
    on transferInternal:
      // same account exchange internal: move cost between logical wallets if modeled as one account — v1: single book per account+asset, treat as no-op OR fee only
      // LOCK v1: transferInternal does not change total cost; if amounts match ignore; if fee, abandon fee qty cost
    on fiatDeposit/fiatWithdraw: ignore for crypto books
    on income (crypto): acquire qty cost 0

  holdings = snapshot(books)
  return ReplayResult(disposals, holdings, deemedPositions, abandonedTotal, extraDeductible)
```

### 5.1 MovingAverageBook

```text
state: qty=0, totalCost=0
acquire(q,c): qty+=q; totalCost+=c
dispose(q):
  require q>0 && q <= qty + eps
  unit = totalCost/qty
  cost = unit*q
  qty-=q; totalCost-=cost
  if qty≈0: qty=0; totalCost=0
  return cost
```

### 5.2 FIFOBook

```text
lots: [(q, unitCost)]  // unitCost = KRW per unit
acquire(q,c): lots.append((q, c/q))
dispose(q):
  remain=q; cost=0
  while remain>0:
    take = min(lots[0].q, remain)
    cost += take * lots[0].unit
    lots[0].q -= take; remain -= take
    if lots[0].q≈0: lots.removeFirst()
  return cost
```

---

## 6. 세금 집계

```text
function aggregate(disposals, taxYear, extraDeductible, policy):
  ds = disposals.filter { calendarYearKST($0.timestamp) == taxYear && $0.timestamp >= T_tax_start }
  proceeds = sum(ds.proceedsKRW)
  costs = sum(ds.costKRW) + sum(ds.feesKRW) + extraDeductible
  income = proceeds - costs   // == sum(pnl) - extraDeductible adjustments
  // LOCK: income = sum(ds.pnlKRW) - extraDeductible (with extra usually 0)
  income = sum(ds.pnlKRW) - extraDeductible
  deduction = 2_500_000
  taxBase = max(0, income - deduction)
  national = roundKRW(taxBase * 0.20)
  local = roundKRW(taxBase * 0.02)
  total = national + local
```

`abandonedTransferCost`는 **costs에 넣지 않음**. 리포트 참고 필드만.

---

## 7. Verification (필수 구현 목록)

정본은 [06-integrity.md](../06-integrity.md) **§3 전체**이며 현재 전 항목이 구현되어 있다.
아래는 착수 시 최소 범위였던 목록(이력):

| ID | 검사 |
|----|------|
| V-RE-01 | 동일 입력 2회 계산 결과 세액·income 동일 |
| V-TAX-01 | sum(pnl) == netIncome (+extra) |
| V-TAX-02 | taxBase == max(0, income-deduction) |
| V-TAX-03/04 | national/local rates |
| V-COST-02 | transfer transferred == outbound * ratio (abandon) |
| V-COST-03 | abandoned not in deductible |
| V-DEM-02 | deemedUnit == max(book, market) |
| V-QTY-02 | no negative qty |
| V-FX-01 | no needsFX left when status verified |

`status=failed` if any critical → UI export off.

---

## 8. 골든 테스트 G1 (수치 고정)

시나리오 (KRW only 단순, 환율 불필요):

```text
Account Bithumb MA:
  t1 buy 10 USDT cost 14_000 KRW/USDT → totalCost 140_000, qty 10
  t2 withdraw 10 USDT → linked to Binance deposit 9.9 USDT
      outboundCost=140_000
      transferred=140_000 * 9.9/10 = 138_600
      abandoned=1_400
Account Binance FIFO:
  deposit acquires 9.9 @ 138_600
  sell 9.9 USDT proceeds 150_000 KRW (after fee)
      cost=138_600, fees=0, pnl=11_400

Tax year of sell (assume >=2027):
  income=11400
  taxBase=max(0, 11400-2500000)=0
  tax=0
  abandonedTransferCost=1400  // reference only
```

G1b 세금 발생:

```text
same but proceeds=10_000_000
pnl = 10_000_000 - 138_600 = 9_861_400
taxBase = 9_861_400 - 2_500_000 = 7_361_400
national = round(7_361_400 * 0.2)
local = round(7_361_400 * 0.02)
```

G2 의제:

```text
book unit 1000, market 1500, qty 2 → deemed unit 1500, total 3000
book 2000, market 1500 → deemed 2000
```

G3 OKX multi-leg: 한 Order id 여러 행 → **매매 이벤트 1개** (레그 수 ≠ 매매 수).

---

## 9. 에러 코드

| Code | 의미 | 사용자 메시지 예 |
|------|------|------------------|
| E_FORMAT_UNKNOWN | 확장자/내용 불명 | 지원 형식이 아닙니다 |
| E_PARSER_REJECT | 원천징수 등 | 거래내역 확인서가 아닙니다 |
| E_PDF_PASSWORD | 암호 필요/실패 | PDF 비밀번호를 확인하세요 |
| E_PARSE_ROW | 행 파싱 실패 | n행을 읽지 못했습니다 |
| E_MISSING_FX | 환율 없음 | 환율을 입력하세요 (날짜 목록) |
| E_MISSING_MARKET | 의제 시가 없음 | 2026-12-31 시가를 입력하세요 |
| E_NEGATIVE_LOT | 재고 부족 | 보유 수량보다 많은 매도 |
| E_VERIFY_FAIL | 검증 실패 | 계산 검증 실패 — 내보내기 불가 |
| E_QUOTE_UNCONVERTIBLE | 코인 견적 환산 불가 | 원화 환산 근거가 없습니다 |
| E_DUPLICATE_FILE | 같은 파일 재import | 이미 가져온 파일입니다 |
| E_STORE_UNAVAILABLE | 저장소 열기 실패 | 저장소를 열 수 없습니다 |

---

## 10. UI 최소 와이어

| 화면 | 필수 컨트롤 |
|------|-------------|
| Import | 파일 추가, 인식 배지, 미리보기 테이블, 오류 리스트, 바이낸스 3파일 체크리스트 |
| 거래내역 | 필터: 계정/자산/type/기간 |
| 전송 매칭 | 후보 리스트, 확정/거부, 미매칭 배지 |
| 보유 | 자산, 수량, 평단 KRW, 총원가 |
| 리포트 | 연도, 소득/세액, 의제 표, 검증 배지, 고지, export |
| 설정 | 환율 표, 시가 표, 가정 문구 읽기 전용 |

사이드바 순서: 대시보드 / Import / 거래내역 / 전송 매칭 / 보유 / 리포트 / 설정

---

## 11. SwiftData 엔티티 매핑

| Entity | Domain |
|--------|--------|
| ProjectEntity | Project |
| AccountEntity | Account |
| SourceFileEntity | SourceFile |
| LedgerEventEntity | LedgerEvent (Decimal as String or Transformable) |
| TransferLinkEntity | TransferLink |
| FXRateEntity | FXRate |
| MarketPriceEntity | MarketPrice |
| SnapshotEntity | TaxYearSummary JSON blob + status |

Decimal 저장: **String** 권장 (정밀도).

---

## 12. FX (v1 최소)

```text
// Remote optional
protocol FXClient {
  func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal]
}
// Default: ManualFXStore only — user pastes rates
// day key = yyyy-MM-dd in KST for the event local KST day
```

이벤트 시각 → KST 달력일:

```text
dayKST(date) = Calendar(identifier:.gregorian) timezone Asia/Seoul startOfDay string
```

휴일 미고시: 직전 영업일 rate, source=previousBusinessDay.

---

## 13. 시가 (의제)

```text
MarketPrice CSV: asOf,asset,priceKRW
asOf must be 2026-12-31 for v1 deemed
```

UI: 자산 목록(스냅샷 보유) + 시가 입력.

---

## 14. 파서 레지스트리 등록 순서

detect 동점 시 파일명 힌트:

1. Funding History → okx-funding  
2. Trading History → okx-trading  
3. Deposit-History → binance-deposit  
4. Withdraw-History → binance-withdraw  
5. Spot Trade → binance-spot  
6. 거래내역 확인서 → bithumb-pdf  

---

## 15. 완료 정의 (다른 세션 Definition of Done)

1. [x] macOS 15 빌드 (경고 0)  
2. [x] 6개 파서 + 합성 fixture 테스트 (+ `generic-tabular-v1` 폴백)  
3. [x] G1/G1b/G2 수치 테스트  
4. [x] Verify fail-closed export  
5. [~] MVP requirements §10 — 실파일 검증 2건 잔여 (§10-1 빗썸 PDF, §10-10 샌드박스 저장)  
6. [x] 실파일 없이도 CI 가능 (synthetic only, 서명 없이 빌드)  

> 체크 갱신: 2026-08-11 (테스트 55건 통과).

---

## 16. 관련

- [../IMPLEMENTATION.md](../IMPLEMENTATION.md)  
- [04-policies.md](./04-policies.md)  
- [06-cost-basis-engine.md](./06-cost-basis-engine.md)  
- [../06-integrity.md](../06-integrity.md)  
