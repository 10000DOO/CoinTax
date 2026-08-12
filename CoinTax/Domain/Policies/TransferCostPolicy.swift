import Foundation

struct TransferCostResult: Equatable, Sendable {
    var transferredCostKRW: Decimal
    var abandonedCostKRW: Decimal
    var deductibleExpenseKRW: Decimal
    var notes: String
}

protocol TransferCostPolicy: Sendable {
    var id: String { get }
    var displayName: String { get }
    var userDisclaimerKO: String { get }

    func apply(
        outboundCostKRW: Decimal,
        withdrawnQty: Decimal,
        receivedQty: Decimal,
        explicitFeeCostKRW: Decimal
    ) -> TransferCostResult
}

struct AbandonLostCostPolicy: TransferCostPolicy {
    let id = "abandon_lost_cost"
    let displayName = "소실 원가 포기"
    var userDisclaimerKO: String { TaxCopy.transferCost }

    func apply(
        outboundCostKRW: Decimal,
        withdrawnQty: Decimal,
        receivedQty: Decimal,
        explicitFeeCostKRW: Decimal
    ) -> TransferCostResult {
        // 정책은 어떤 입력에도 프로세스를 죽이지 않는다 (호출부가 하나가 아니다).
        // 출금 수량이 0이면 비율을 정의할 수 없으므로 원가를 그대로 소멸 처리하고 사유를 남긴다.
        guard withdrawnQty > 0 else {
            return TransferCostResult(
                transferredCostKRW: 0,
                abandonedCostKRW: outboundCostKRW + explicitFeeCostKRW,
                deductibleExpenseKRW: 0,
                notes: "abandon_lost_cost/invalid_withdrawn_qty"
            )
        }
        let ratio = Money.clamp(receivedQty / withdrawnQty, 0, 1)
        let transferred = outboundCostKRW * ratio
        let abandoned = outboundCostKRW - transferred + explicitFeeCostKRW
        return TransferCostResult(
            transferredCostKRW: transferred,
            abandonedCostKRW: abandoned,
            deductibleExpenseKRW: 0,
            notes: "abandon_lost_cost"
        )
    }
}
