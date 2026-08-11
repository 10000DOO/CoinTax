import Foundation

enum TaxCopy {
    static let notTaxAdvice =
        "본 결과는 세무 자문이 아니며 예상 참고용입니다. 신고 전 전문가·국세청 안내를 확인하세요."

    static let transferCost =
        "전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다."

    static let usdtPeg =
        "USDT는 USD 1:1로 가정한 뒤 해당일 USD/KRW 기준환율로 환산합니다."

    static let costMethods =
        "빗썸 계정은 이동평균법, 바이낸스·OKX 계정은 선입선출법으로 취득가액을 계산합니다."

    static var all: [String] {
        [notTaxAdvice, transferCost, usdtPeg, costMethods]
    }
}
