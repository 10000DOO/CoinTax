import Foundation

// HoldingsSnapshot / HoldingsRow defined in Domain/Models/TaxModels.swift
enum HoldingsBuilder {
    static func empty(asOf: Date = Date()) -> HoldingsSnapshot {
        HoldingsSnapshot(asOf: asOf, rows: [], aggregated: [])
    }
}
