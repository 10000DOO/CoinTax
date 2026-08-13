import Foundation

/// 세무 확인이 필요하거나, 향후 법령·고시가 나오면 다시 봐야 하는 항목.
///
/// 앱이 지금 쓰는 가정을 화면·export에 그대로 드러내기 위한 목록이다.
/// 문서(`docs/fix-review-findings.md` §9)에만 두면 사용자가 볼 수 없다.
struct TaxOpenQuestion: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        /// 지금 확인이 필요한 항목 (세무사·국세청)
        case needsConfirmation
        /// 법령·고시가 나오면 다시 봐야 하는 항목
        case watchLegislation
        /// 법령·공식 문서로 근거가 확인된 항목 (기록 목적으로 남김)
        case confirmed

        var label: String {
            switch self {
            case .needsConfirmation: return "확인 필요"
            case .watchLegislation: return "개정 감시"
            case .confirmed: return "근거 확인됨"
            }
        }
    }

    /// 세액에 미치는 영향 크기
    enum Weight: String, Sendable {
        case high, medium, low

        var label: String {
            switch self {
            case .high: return "세액 영향 큼"
            case .medium: return "세액 영향 보통"
            case .low: return "표시·형식만"
            }
        }
    }

    var id: String
    var kind: Kind
    var weight: Weight
    /// 무엇이 미결인가
    var title: String
    /// 앱이 지금 쓰고 있는 가정
    var currentAssumption: String
    /// 세무사·국세청에 무엇을 물어야 하는가 (그대로 읽어 쓸 수 있게)
    var whatToAsk: String
    /// 결론이 바뀌면 앱에서 어디가 달라지는가
    var impact: String
    /// 근거·참고
    var basis: String?
    /// 결정 후 바꿀 지점 (설정 항목 또는 코드 위치)
    var switchPoint: String?
}

enum TaxOpenQuestions {
    static let all: [TaxOpenQuestion] = [
        .init(
            id: "TQ-01",
            kind: .needsConfirmation,
            weight: .high,
            title: "의제취득가를 매입 건별로 볼지, 보유 전체 평균으로 볼지",
            currentAssumption: """
            기본은 **보유 전체 평균**입니다. 2026-12-31 시점의 평균 취득단가와 그날 시가를 비교해 \
            비싼 쪽을 취득가로 씁니다. 설정에서 **매입 건별** 비교로 바꿀 수 있고, 리포트에 두 방식의 차이를 함께 표시합니다.
            """,
            whatToAsk: """
            소득세법 부칙의 가상자산 의제취득가액(2026-12-31 시가와 실제 취득가액 중 큰 금액)을 적용할 때, \
            선입선출법 대상 계정에서 그 비교를 **개별 취득 단위(lot)별로** 하는지, \
            아니면 해당 자산의 **보유 전체 평균 취득단가**로 하는지 알고 싶습니다.
            """,
            impact: """
            취득가액 총액이 달라져 세액이 직접 바뀝니다. 예: 4천만원·8천만원에 각 1개 보유, 시가 6천만원이면 \
            평균 방식 1.2억 / 건별 방식 1.4억 → 차이 2천만원(세액 약 440만원).
            """,
            basis: "소득세법 부칙 의제취득가액 규정 · 시행령 제88조(가상자산주소별 평가) · 국세청 「거주자의 가상자산소득 과세 개요」",
            switchPoint: "설정 → 의제취득가 산정 방식"
        ),
        .init(
            id: "TQ-02",
            kind: .confirmed,
            weight: .medium,
            title: "신고서 총수입금액에 매도 수수료를 반영할지",
            currentAssumption: """
            **판 금액 전체를 총수입금액으로** 적고, 매도 수수료는 필요경비에 넣습니다(전 계정 통일). \
            빗썸 확인서는 「거래금액」을 양도가액으로 쓰고 (거래금액 − 정산금액)을 수수료로 분리합니다. \
            소득금액과 세액은 어느 방식이든 같고, 신고서 두 칸의 숫자만 달라집니다.
            """,
            whatToAsk: """
            가상자산 기타소득을 신고할 때 「총수입금액」 칸에 적는 금액이 \
            (가) 양도대가 **총액**이고 매도 시 부담한 거래수수료는 필요경비로 따로 적는 것인지, \
            (나) 수수료를 **차감한 순수입액**을 적는 것인지 알고 싶습니다.

            국내 거래소(빗썸) 거래내역 확인서는 「정산금액(수수료 포함)」으로 수수료가 이미 차감된 순액을 주고, \
            해외 거래소는 총액과 수수료를 따로 주기 때문에, 두 자료를 한 신고서에 담을 때 기준을 통일해야 합니다.
            """,
            impact: """
            소득금액·세액은 바뀌지 않습니다. 신고서의 「총수입금액」과 「필요경비」 두 칸에 적히는 숫자와, \
            거래소 자료와 대조할 때 맞춰야 하는 금액이 달라집니다.
            """,
            basis: """
            국세청 「거주자의 가상자산소득 과세 개요」: 소득금액 = 양도·대여 대가 − 취득가액 − 부대비용. \
            필요경비에 실제 취득가액과 **거래수수료 등 부대비용**이 포함된다고 안내한다. \
            → 총수입금액은 양도대가 **총액**으로 보는 것이 안내에 부합한다 (2026-08 확인). \
            다만 신고서 서식 기재 지침까지 확인한 것은 아니므로 신고 직전 재확인 권장.
            """,
            switchPoint: "코드: CostBasisEngine 의 sell 처리 (현재 총액 + 수수료 필요경비)"
        ),
        .init(
            id: "TQ-03",
            kind: .confirmed,
            weight: .low,
            title: "세액의 원 단위 절사 방법",
            currentAssumption: """
            **버림**입니다. 과세표준은 **1원 미만**, 납부할 세액은 **10원 미만**을 버립니다. \
            국세와 지방소득세는 별개의 징수금이라 **각각** 버립니다(합계를 버리면 국세청 계산과 어긋납니다). \
            엔진과 검증기가 같은 규칙을 공유합니다.
            """,
            whatToAsk: "확인 완료 — 개정 시 재확인.",
            impact: "표시·신고 금액이 최대 수십 원 단위로 달라집니다. 예전의 사사오입 대비 세액이 같거나 조금 줄어듭니다.",
            basis: """
            「국고금 관리법」 제47조 — ① 국고금의 수입·지출에서 **10원 미만**의 끝수는 계산하지 아니한다. \
            ② 국세의 **과세표준액**을 산정할 때 **1원 미만**의 끝수가 있으면 계산하지 아니한다. \
            지방소득세도 「지방세기본법」 제59조가 같은 조문을 준용한다. \
            (법제처 국가법령정보 원문 대조 2026-08-13 · 백서 부록)
            """,
            switchPoint: "코드: StatutoryKRWRoundingPolicy"
        ),
        .init(
            id: "TQ-04",
            kind: .needsConfirmation,
            weight: .medium,
            title: "지방소득세를 과세표준 기준으로 볼지, 산출세액 기준으로 볼지",
            currentAssumption: "**과세표준 × 2%** 로 계산합니다. 「산출세액 × 10%」와 결과가 같습니다.",
            whatToAsk: """
            가상자산 기타소득의 지방소득세를 「과세표준 × 2%」로 계산하는지 \
            「소득세 산출세액 × 10%」로 계산하는지, 그리고 절사 시점이 어디인지 알고 싶습니다.
            """,
            impact: "현재 세율에서는 결과가 같습니다. 다만 절사를 어느 단계에서 하느냐에 따라 원 단위가 달라집니다.",
            basis: "docs/03-tax-rules.md §2.2",
            switchPoint: "코드: TaxRatePolicy.compute"
        ),
        .init(
            id: "TQ-05",
            kind: .needsConfirmation,
            weight: .high,
            title: "환율 원천 — 어떤 환율이 「기준환율」로 인정되는지",
            currentAssumption: """
            **한국은행 ECOS 일별 원/달러 환율**만 씁니다. 인증키가 없으면 자동 조회를 하지 않고 \
            수동 입력·CSV 가져오기를 안내합니다. 공개 시세 폴백은 기본으로 꺼져 있고, \
            켜면 그 값을 「참고 시세」로 구분해 표시합니다.
            """,
            whatToAsk: """
            외국통화 연동 기축가상자산(USDT 등)을 원화로 환산할 때 쓰는 \
            「외국환거래법 제5조에 따른 기준환율 또는 재정환율」의 구체적 원천을 알고 싶습니다. \
            서울외국환중개 매매기준율이어야 하는지, 한국은행이 공표하는 일별 환율로 갈음할 수 있는지, \
            그리고 어느 시점(종가·평균)의 값을 써야 하는지 확인이 필요합니다.
            """,
            impact: """
            환산 금액이 달라져 해외 거래의 취득가·양도가 전체가 바뀝니다.

            ⚠️ **2027년 1월부터 원/달러 매매기준율 산출 방식이 바뀝니다** \
            (기존 시장평균환율(MAR) → 시간가중평균(TWAP)). 과세 시작 시점과 겹치므로, \
            어느 값을 「기준환율」로 볼지 확인이 더 중요해졌습니다.
            """,
            basis: """
            소득세법 시행령 제88조 · 외국환거래법 제5조 · 국세청 「거주자의 가상자산소득 과세 개요」 \
            (외국통화 연동 기축가상자산은 「기준환율 또는 재정환율」로 환산). \
            매매기준율 고시 주체는 서울외국환중개이며, 한국은행 ECOS 일별 원/달러 환율이 \
            같은 계열 수치인지 대조가 필요하다 (2026-08 확인).
            """,
            switchPoint: "설정 → USD/KRW 환율 (ECOS 인증키 / 공개 시세 허용)"
        ),
        .init(
            id: "TQ-06",
            kind: .needsConfirmation,
            weight: .medium,
            title: "환율이 고시되지 않은 날(주말·공휴일)의 처리",
            currentAssumption: """
            **직전 고시일**의 기준환율을 쓰고, 실제 고시일을 함께 기록합니다. \
            리포트에 「토요일 거래 → 금요일 고시 환율 적용」처럼 그대로 표시합니다.
            """,
            whatToAsk: """
            거래일이 환율 미고시일(주말·공휴일)인 경우 「직전 고시일」 환율을 쓰는 것이 맞는지 확인하고 싶습니다. \
            부가가치세 질의회신(서삼46015-11986)은 공휴일이면 「그 전날」 기준환율을 쓰라고 하는데, \
            일부 통칙에는 「다음날」로 보는 취지도 있어 가상자산 기타소득에 어느 쪽을 준용하는지 알고 싶습니다.
            """,
            impact: "미고시일 거래의 환산 금액이 달라집니다. 연휴 직후 거래가 많으면 영향이 커집니다.",
            basis: "국세청 서삼46015-11986 (2002.11.19) · docs/design/08-fx-service.md §4",
            switchPoint: "코드: FXHolidayPolicy (현재 previous_published_rate_v1)"
        ),
        .init(
            id: "TQ-07",
            kind: .needsConfirmation,
            weight: .high,
            title: "전송 중 소실된 수량의 취득원가 처리",
            currentAssumption: """
            **보수적으로 폐기**합니다. 출금 10개 중 9개가 도착하면 원가의 90%만 도착 계정으로 옮기고, \
            나머지 10%는 필요경비에도 넣지 않고 도착 취득가에도 넣지 않습니다. \
            세액이 다소 커지는 방향입니다.
            """,
            whatToAsk: """
            거래소 간 전송 시 네트워크 수수료로 차감된 수량에 대응하는 취득원가를 \
            (가) 도착 수량의 취득가액에 안분하는지, (나) 필요경비로 공제하는지, \
            (다) 공제 대상이 아닌지 알고 싶습니다. 현재 공개된 해설을 찾지 못해 (다)로 가정하고 있습니다.
            """,
            impact: "전송이 많을수록 차이가 커집니다. 리포트의 「전송 소실 원가」 금액만큼 필요경비가 달라질 수 있습니다.",
            basis: "docs/05-decisions.md §7 · 공개 해설 부재 (정책 id: abandon_lost_cost)",
            switchPoint: "코드: TransferCostPolicy 구현체 교체 (allocate_to_arrival / deduct_as_expense 예약)"
        ),
        .init(
            id: "TQ-08",
            kind: .needsConfirmation,
            weight: .medium,
            title: "USDT·USDC를 미국 달러 1:1로 보는 가정",
            currentAssumption: """
            **1 USDT = 1 USDC = 1 USD** 로 보고 거래일 원/달러 기준환율로 환산합니다. \
            이 두 가지만 달러 연동으로 취급하고, 그 밖의 코인은 환산 근거가 없다고 보아 계산하지 않습니다.
            """,
            whatToAsk: """
            USDT·USDC 등 외국통화 연동 기축가상자산을 원화로 환산할 때 \
            액면 1:1(1 USDT = 1 USDC = 1 USD)로 보아 원/달러 환율만 적용하는 것이 맞는지, \
            아니면 실제 시세(페그 이탈 구간 포함)를 반영해야 하는지 알고 싶습니다.
            """,
            impact: "페그가 흔들린 구간(예: 0.95달러)에 거래가 있으면 그만큼 환산 금액이 틀립니다.",
            basis: "docs/05-decisions.md §3.2 · TaxCopy.usdtPeg",
            switchPoint: "코드: FXAssumptionPolicy (usdt_eq_usd)"
        ),
        .init(
            id: "TQ-09",
            kind: .needsConfirmation,
            weight: .medium,
            title: "코인으로 값을 매긴 거래(예: ETH/BTC)의 원화 환산",
            currentAssumption: """
            환산 근거가 없어 **계산하지 않고 오류로 표시**합니다. 임의로 달러 환율을 곱하지 않습니다. \
            해당 거래가 있으면 검증이 실패하고 내보내기가 잠깁니다.
            """,
            whatToAsk: """
            원화도 아니고 달러 연동 스테이블코인도 아닌 자산으로 값을 매긴 교환거래(예: ETH를 BTC로 매수)의 \
            원화 환산 방법을 알고 싶습니다. 교환 시점의 각 코인 시가를 쓰는지, \
            달러를 경유해 재정환율로 환산하는지 확인이 필요합니다.
            """,
            impact: "이런 거래가 있으면 현재는 계산이 막힙니다. 방법이 정해지면 자동 환산이 가능해집니다.",
            basis: "소득세법 시행령 제88조 교환거래 관련 · docs/IMPLEMENTATION.md §6.2",
            switchPoint: "코드: CostBasisEngine.krwFromQuote"
        ),
        .init(
            id: "TQ-10",
            kind: .needsConfirmation,
            weight: .high,
            title: "의제취득가에 쓰는 「시가」를 어떻게 구할지",
            currentAssumption: """
            사용자가 자산별로 입력한 원화 단가 하나를 씁니다. 출처는 리포트·export에 함께 기록합니다. \
            **2027-01-01 이 지나기 전까지는** 시가가 없어도 경고만 하고 실제 산 값으로 계산합니다 — \
            그 시가는 그 시점이 지나야 존재하기 때문입니다. 과세 시작 후에는 시가가 없는 자산이 있으면 계산이 막힙니다.

            **법령상 기준은 확인되었습니다** — 소득세법 시행령 제88조제2항:
            ① 시가고시 가상자산사업자가 취급하는 자산 → 각 사업자 사업장에서 **2027-01-01 0시** 공시한 가격의 **평균**
            ② 그 외 자산 → 시가고시 사업자 외의 사업자가 같은 시점에 공시한 가격
            즉 기준 시점은 「2026-12-31 종가」가 아니라 **2027-01-01 0시**입니다.
            """,
            whatToAsk: """
            (기준 자체는 시행령 제88조제2항으로 확인되었습니다. 남은 것은 실무 확인입니다.)
            ① 「시가고시 가상자산사업자」에 어느 거래소가 해당하는지,
            ② 국세청·홈택스가 제공하는 가상자산 가격 조회 서비스의 값을 그대로 써도 되는지,
            ③ 국내 거래소에 상장되지 않은 해외 전용 코인의 시가를 어떻게 잡아야 하는지
            확인이 필요합니다.
            """,
            impact: "의제취득가가 직접 바뀌므로 2027년 이후 처분 손익 전체에 영향을 줍니다.",
            basis: """
            소득세법 시행령 제88조제2항 (시가 산정) · 소득세법 제37조제5항 (의제취득가액) · \
            국세청 「거주자의 가상자산소득 과세 개요」. \
            홈택스·손택스에 「가상자산 일평균가격 조회」 서비스가 있어 값 확보에 쓸 수 있다 (2026-08 확인).
            """,
            switchPoint: "설정 → 의제 시가"
        ),
        .init(
            id: "TQ-11",
            kind: .needsConfirmation,
            weight: .medium,
            title: "연결되지 않은 입금·출금의 취득가 처리",
            currentAssumption: """
            상대 거래를 못 찾은 **입금은 취득가 0원**, **출금은 취득원가 소멸**로 처리합니다. \
            둘 다 세액이 커지는 방향이고, 리포트에 경고로 표시합니다.
            """,
            whatToAsk: """
            거래소 간 전송 기록이 한쪽만 남아 상대 거래를 확인할 수 없는 경우 \
            해당 자산의 취득가액을 어떻게 인정받을 수 있는지(소명 자료 범위 포함) 알고 싶습니다.
            """,
            impact: "누락된 전송이 많으면 세액이 크게 과대 계상될 수 있습니다. 가능하면 매칭 화면에서 손으로 연결하세요.",
            basis: "docs/IMPLEMENTATION.md §7",
            switchPoint: "전송 매칭 화면 → 수동 연결"
        ),
        .init(
            id: "TQ-12",
            kind: .needsConfirmation,
            weight: .medium,
            title: "에어드롭·수수료 리베이트의 취득가와 소득 구분",
            currentAssumption: "**취득가 0원**으로 잡습니다. 처분 시 거의 전액이 이익이 됩니다. 받은 시점에는 소득으로 계상하지 않습니다.",
            whatToAsk: """
            에어드롭·스테이킹 보상·거래소 수수료 리베이트로 받은 가상자산의 \
            (가) 취득가액을 수령 시점 시가로 볼 수 있는지, \
            (나) 수령 시점에 별도 소득(기타소득 등)으로 신고해야 하는지 알고 싶습니다.
            """,
            impact: "취득가를 인정받으면 처분 시 이익이 줄어듭니다. 반대로 수령 시점 과세 대상이면 신고 항목이 늘어납니다.",
            basis: "docs/03-tax-rules.md §8",
            switchPoint: "코드: CostBasisEngine 의 income 처리"
        ),
        .init(
            id: "TQ-13",
            kind: .needsConfirmation,
            weight: .low,
            title: "거래소 안에서 지갑을 옮긴 기록의 취급",
            currentAssumption: "**과세 대상이 아닌 내부 이동**으로 보고 수량·원가를 그대로 둡니다 (OKX 펀딩↔거래 계정 등).",
            whatToAsk: "같은 거래소 계정 안에서 지갑 간 이동(펀딩↔거래 계정)이 양도에 해당하지 않는다는 점을 확인하고 싶습니다.",
            impact: "양도로 본다면 처분 건수가 크게 늘어납니다.",
            basis: "docs/parsers/okx-funding-history.md §3",
            switchPoint: "코드: CostBasisEngine 의 transferInternal 처리"
        ),
        .init(
            id: "TQ-14",
            kind: .needsConfirmation,
            weight: .low,
            title: "빗썸 예치금 이용료(이자)의 처리",
            currentAssumption: "가상자산 기타소득 계산에서 **제외**합니다. 이자소득·원천징수 영역으로 보고 별도 취급합니다.",
            whatToAsk: "거래소 예치금 이용료가 이자소득으로 원천징수되는 것이 맞는지, 별도 신고 의무가 있는지 확인하고 싶습니다.",
            impact: "가상자산 손익 계산에는 영향이 없습니다. 종합소득 신고 시 별도 항목일 수 있습니다.",
            basis: "docs/parsers/bithumb-transaction-certificate.md §5",
            switchPoint: nil
        ),
        .init(
            id: "TQ-15",
            kind: .watchLegislation,
            weight: .high,
            title: "시행일·세율·기본공제가 바뀔 가능성",
            currentAssumption: """
            **2027-01-01 이후 양도분**부터 과세, 기본공제 **연 250만원**, 세율 **20% + 지방소득세 2%** 로 계산합니다. \
            2026-08 기준 공개 안내에 따른 가정입니다.
            """,
            whatToAsk: "시행 시기 유예 여부와 공제액·세율의 최종 확정 내용을 신고 직전에 다시 확인해야 합니다.",
            impact: "시행이 미뤄지면 과세 대상 거래가 없어질 수 있고, 공제·세율이 바뀌면 세액이 전부 바뀝니다.",
            basis: "docs/03-tax-rules.md §1",
            switchPoint: "코드: TaxRatePolicy · TaxTime.taxStartDate"
        ),
        .init(
            id: "TQ-16",
            kind: .confirmed,
            weight: .medium,
            title: "손실을 다음 해로 넘길 수 있는지",
            currentAssumption: "**이월되지 않습니다.** 같은 해 안에서만 이익·손실을 합산합니다.",
            whatToAsk: "가상자산 결손금의 이월공제 가능 여부 (확인 완료 — 개정 시 재확인).",
            impact: "손실이 큰 해가 있어도 다음 해 세액을 줄이지 못합니다. 연내 실현 시점 조절이 유일한 수단입니다.",
            basis: """
            가상자산 결손금은 금융투자소득과 달리 **다음 과세연도로 이월공제되지 않는다**는 것이 \
            공개 해설의 일치된 설명이다 (2026-08 확인). 향후 개정 시 재확인.
            """,
            switchPoint: "코드: TaxAggregator"
        ),
        .init(
            id: "TQ-17",
            kind: .watchLegislation,
            weight: .high,
            title: "원가 산정 방법이 총평균법으로 바뀔 가능성",
            currentAssumption: """
            **빗썸(신고수리 사업자)은 이동평균법, 바이낸스·OKX는 선입선출법**을 씁니다. \
            2026-08 국세청 안내의 이원 체계를 따릅니다.
            """,
            whatToAsk: "세법 개정 논의에서 언급된 총평균법 전환이 확정되었는지, 적용 시기가 언제인지 확인이 필요합니다.",
            impact: "취득가액 배분이 전부 바뀌어 실현손익이 달라집니다.",
            basis: "docs/05-decisions.md §1.1 · 소득세법 시행령 제88조",
            switchPoint: "코드: CostMethodResolver + 새 AssetBook 구현"
        ),
        .init(
            id: "TQ-18",
            kind: .watchLegislation,
            weight: .low,
            title: "선물·마진 거래 손익",
            currentAssumption: "**계산에서 제외**하고 제외 건수만 표시합니다.",
            whatToAsk: "가상자산 파생상품 거래 손익의 과세 방법과 기타소득 통산 여부를 확인해야 합니다.",
            impact: "통산 대상이면 선물 거래 자료를 추가로 가져와야 합니다.",
            basis: "docs/05-decisions.md §4",
            switchPoint: nil
        ),
        .init(
            id: "TQ-19",
            kind: .confirmed,
            weight: .high,
            title: "코인 ↔ 코인 교환을 처분으로 볼지",
            currentAssumption: """
            **처분으로 봅니다.** USDT 로 알트코인을 사면 그 시점에 USDT 를 양도한 것으로 보고
            USDT 의 손익을 인식하고, 알트코인은 그 원화가액으로 취득합니다. 반대로 알트코인을 팔아
            받은 USDT 는 그 시점 원화가액이 취득가액이 됩니다.
            """,
            whatToAsk: """
            가상자산을 다른 가상자산과 교환한 시점에 넘겨준 코인의 양도소득을 인식하는지,
            아니면 원화로 바꿀 때까지 취득가액을 그대로 이어가는지 확인이 필요합니다.
            """,
            impact: """
            처분으로 보면 총수입금액이 교환 횟수만큼 커지고 손익 인식 시점이 앞당겨집니다.
            전체 경제적 이익 합계는 같지만 **어느 과세연도에 귀속되는지**가 달라집니다.
            """,
            basis: """
            소득세법 시행령 제88조 — 가상자산 교환거래의 양도가액 산정 방법을 별도로 정하고 있습니다.
            (교환을 양도로 보지 않으면 이 조항이 필요하지 않습니다.)
            """,
            switchPoint: "코드: CostBasisEngine.processQuoteLeg"
        )
    ]

    static var needsConfirmation: [TaxOpenQuestion] {
        all.filter { $0.kind == .needsConfirmation }
    }

    static var watchLegislation: [TaxOpenQuestion] {
        all.filter { $0.kind == .watchLegislation }
    }

    static var confirmed: [TaxOpenQuestion] {
        all.filter { $0.kind == .confirmed }
    }

    /// export 한 줄 요약
    static func exportLines() -> [String] {
        all.map { q in
            "[\(q.id)/\(q.kind.label)/\(q.weight.label)] \(q.title) — 현재 가정: \(q.currentAssumption.replacingOccurrences(of: "\n", with: " "))"
        }
    }
}
