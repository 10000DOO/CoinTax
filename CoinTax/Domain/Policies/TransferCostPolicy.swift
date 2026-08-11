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
        precondition(withdrawnQty > 0)
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
