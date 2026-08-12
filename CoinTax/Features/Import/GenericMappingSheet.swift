import SwiftUI

/// F-IM-06: 제네릭 표 컬럼 → 표준 필드 매핑 UI
struct GenericMappingSheet: View {
    let headers: [String]
    var onConfirm: ([String: String], String) -> Void
    var onCancel: () -> Void

    @State private var map: [String: String] = [:]
    /// 원본 시각의 시간대. 국내 파일은 KST 이므로 UTC 고정이면 9시간 밀린다 (리뷰 6-4).
    @State private var timeZoneID = "UTC"

    private let timeZoneOptions: [(id: String, label: String)] = [
        ("UTC", "UTC (해외 거래소 기본)"),
        ("Asia/Seoul", "KST · 한국 시간 (국내 거래소)"),
        ("Asia/Shanghai", "UTC+8 (OKX 등)"),
        ("Asia/Tokyo", "UTC+9"),
        ("America/New_York", "미국 동부")
    ]

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
                Picker("원본 시간대", selection: $timeZoneID) {
                    ForEach(timeZoneOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                ForEach(fields, id: \.key) { f in
                    Picker("\(f.label)\(f.required ? " *" : "")", selection: binding(for: f.key)) {
                        Text("(없음)").tag("")
                        // 열 이름이 중복될 수 있어 인덱스를 식별자로 쓴다 (리뷰 4-1/4-6)
                        ForEach(Array(uniqueHeaders.enumerated()), id: \.offset) { _, h in
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
                    onConfirm(out, timeZoneID)
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

    /// 중복 열 이름은 하나만 노출 (Dictionary 중복 키 크래시 방지 — 리뷰 4-1)
    private var uniqueHeaders: [String] {
        var seen: Set<String> = []
        return headers.filter { seen.insert($0).inserted }
    }

    private func seedGuesses() {
        var lower: [String: String] = [:]
        for h in headers {
            let key = h.lowercased()
            if lower[key] == nil { lower[key] = h }
        }
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
