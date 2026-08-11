import SwiftUI

/// F-IM-06: 제네릭 표 컬럼 → 표준 필드 매핑 UI
struct GenericMappingSheet: View {
    let headers: [String]
    var onConfirm: ([String: String]) -> Void
    var onCancel: () -> Void

    @State private var map: [String: String] = [:]

    private let fields: [(key: String, label: String, required: Bool)] = [
        ("timestamp", "시각", true),
        ("type", "유형", true),
        ("baseAsset", "자산", true),
        ("quantity", "수량", true),
        ("quoteAsset", "견적자산", false),
        ("price", "가격", false),
        ("quoteAmount", "견적금액", false),
        ("quoteAmountKRW", "KRW금액", false),
        ("feeAmount", "수수료", false),
        ("feeAsset", "수수료자산", false),
        ("externalID", "외부ID", false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("제네릭 컬럼 매핑")
                .font(.title2.bold())
            Text("CSV/XLSX 헤더를 표준 필드에 연결하세요. 자동 추정값을 고칠 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                ForEach(fields, id: \.key) { f in
                    Picker("\(f.label)\(f.required ? " *" : "")", selection: binding(for: f.key)) {
                        Text("(없음)").tag("")
                        ForEach(headers, id: \.self) { h in
                            Text(h).tag(h)
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("취소", role: .cancel, action: onCancel)
                Spacer()
                Button("이 매핑으로 Import") {
                    var out: [String: String] = [:]
                    for (k, v) in map where !v.isEmpty {
                        out[k] = v
                    }
                    onConfirm(out)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!requiredOK)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 400)
        .onAppear { seedGuesses() }
    }

    private var requiredOK: Bool {
        ["timestamp", "type", "baseAsset", "quantity"].allSatisfy { key in
            !(map[key] ?? "").isEmpty
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { map[key] ?? "" },
            set: { map[key] = $0 }
        )
    }

    private func seedGuesses() {
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.lowercased(), $0) })
        for (field, aliases) in GenericTabularMapper.defaultAliases {
            if map[field] != nil { continue }
            for a in aliases {
                if let h = lower[a.lowercased()] {
                    map[field] = h
                    break
                }
            }
        }
    }
}
