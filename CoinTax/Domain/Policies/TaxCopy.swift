import Foundation

enum TaxCopy {
    static let notTaxAdvice =
        "본 결과는 세무 자문이 아니며 예상 참고용입니다. 신고 전 전문가·국세청 안내를 확인하세요."

    static let transferCost =
        "전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다."

    static let usdtPeg =
        "USDT·USDC는 USD 1:1로 가정한 뒤 해당일 USD/KRW 기준환율로 환산합니다."

    static let costMethods =
        "빗썸 계정은 이동평균법, 바이낸스·OKX 계정은 선입선출법으로 취득가액을 계산합니다."

    // MARK: - 의제취득가 기준시점 표기 (한 곳에서만 정의)
    //
    // 소득세법 시행령 제88조제2항의 기준 시점은 **2027-01-01 0시**다.
    // 「2026-12-31 시가」라고만 적으면 사용자가 12월 31일 **종가**를 넣기 쉬운데,
    // 그건 법령이 말하는 값이 아니다. 두 표기가 같은 순간임을 함께 보여준다.
    // (저장 키 `asOf`는 `2026-12-31` 그대로 둔다 — 같은 시점이고, 바꾸면 기존 데이터가 끊긴다)
    static let deemedAsOfLabel = "2027-01-01 0시 시가"
    static let deemedAsOfDetail =
        "기준 시점은 2027-01-01 0시(= 2026-12-31 24시)입니다. 12월 31일 종가가 아니라 그 시점 공시가격입니다."

    /// 잠금된 필수 고지 4종 (`PolicyBundle.v1Default.disclaimers`). 순서·문구 변경 시 policy id 를 올린다.
    static var all: [String] {
        [notTaxAdvice, transferCost, usdtPeg, costMethods]
    }

    // MARK: - 추가 주의사항 (잠금 4종과 별개 · 리뷰 8-7)
    //
    // 필수 고지 4종은 PolicyBundle 에 잠겨 있어 개수를 늘리면 골든 테스트가 깨진다.
    // 사용자에게 알려야 하지만 정책 고지가 아닌 항목은 여기에 둔다.

    static let zeroCostAcquisition =
        "에어드롭·수수료 리베이트·연결되지 않은 입금은 취득가 0원으로 처리됩니다. 처분 시 거의 전액이 이익으로 잡히므로, 실제 취득가가 있으면 상대 거래를 연결하거나 직접 확인하세요."

    static let lossNotCarriedForward =
        "가상자산 기타소득의 손실은 다음 해로 이월되지 않는 것으로 가정했습니다. 연간 통산만 반영됩니다."

    static let scheduleMayChange =
        "2027-01-01 시행·기본공제 250만 원·세율 20%+2% 는 2026-08 기준 공개 안내에 따른 가정입니다. 시행 유예·개정 시 결과가 달라집니다."

    static let unmatchedWithdrawalCost =
        "연결되지 않은 출금의 취득원가는 소멸 처리됩니다(세액이 커지는 방향). 상대 입금을 연결하거나, 개인지갑으로 보낸 것이면 「전송 연결」 화면에서 개인지갑으로 지정하면 원가가 이어집니다."

    static var notices: [String] {
        [zeroCostAcquisition, lossNotCarriedForward, scheduleMayChange, unmatchedWithdrawalCost]
    }
}
