import XCTest
@testable import CoinTax

/// **연도에 천 단위 쉼표가 붙으면 안 된다.**
///
/// SwiftUI 의 `Text("\(정수)")` 는 `LocalizedStringKey` 보간이라 로캘 숫자 형식을 적용한다.
/// 연도를 그대로 넣으면 화면에 **"2,026년"** 이 찍힌다.
/// 빌드도 되고 테스트도 통과하며 **실제로 앱을 띄워야만 보인다** — 6차 감사에서 UI 를
/// 처음 실행해 보고 잡았다.
///
/// 여기서는 소스에 그 패턴이 되살아나지 않는지 본다. 화면을 띄우지 않고 잡는 유일한 방법이다.
final class YearFormattingTests: XCTestCase {

    private var featureSources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CoinTax/Features")
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = en?.nextObject() as? URL {
            if u.pathExtension == "swift" { out.append(u) }
        }
        return out
    }

    func testYearIsNeverInterpolatedRawIntoSwiftUIText() throws {
        var offenders: [String] = []
        for url in featureSources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // `\(taxYear)년` 처럼 **정수를 그대로** 문자열에 넣은 자리
                if line.contains("\\(taxYear)년") || line.contains("\\(year)년") {
                    offenders.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "연도를 그대로 보간하면 「2,026년」이 됩니다 — String(taxYear) 로 감싸세요: \(offenders.joined(separator: ", "))"
        )
    }
}
