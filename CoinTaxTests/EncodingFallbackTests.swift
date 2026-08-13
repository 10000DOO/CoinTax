import XCTest
@testable import CoinTax

/// 국내 인코딩(CP949/EUC-KR) 파일을 실제로 읽는가 (5차 감사).
///
/// 국내 거래소·엑셀이 내보내는 CSV 는 UTF-8 이 아니라 **CP949** 인 경우가 흔하다.
/// 제네릭 표 매핑은 `거래일시`·`거래구분`·`매수`/`매도` 같은 **한글 값을 기준으로**
/// 열과 거래 종류를 알아본다 — 인코딩을 못 읽으면 그 지원이 통째로 죽는다.
final class EncodingFallbackTests: XCTestCase {

    /// CP949 로 인코딩한 원본 바이트 (테스트가 인코딩 상수에 기대지 않도록 **바이트를 직접** 넣는다).
    ///
    /// ```text
    /// 거래일시,자산명,거래구분,거래수량,거래금액
    /// 2026-05-01 10:00:00,BTC,매수,0.5,25000000
    /// 2026-06-01 09:30:00,BTC,매도,0.2,12000000
    /// ```
    private static let cp949Hex = """
    b0c5b7a1c0cfbdc32cc0dabbeab8ed2cb0c5b7a1b1b8bad02cb0c5b7a1bcf6b7\
    ae2cb0c5b7a1b1ddbed70a323032362d30352d30312031303a30303a30302c42\
    54432cb8c5bcf62c302e352c32353030303030300a323032362d30362d303120\
    30393a33303a30302c4254432cb8c5b5b52c302e322c31323030303030300a
    """

    private func writeTemp(_ data: Data, ext: String = "csv") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private static func hexData(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testCP949FileIsDecodedAsKorean() throws {
        let url = try writeTemp(Self.hexData(Self.cp949Hex))
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try CSVUtil.readText(url: url)
        XCTAssertTrue(text.contains("거래일시"), "국내 인코딩 파일이 한글로 읽히지 않았다 — 읽힌 첫 줄: \(text.prefix(40))")
        XCTAssertTrue(text.contains("매수"))
        XCTAssertTrue(text.contains("매도"))
    }

    /// UTF-8 파일이 국내 인코딩으로 잘못 해석되면 안 된다 (순서 회귀)
    func testUTF8StillWins() throws {
        let url = try writeTemp(Data("거래일시,자산명\n2026-01-01,BTC\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try CSVUtil.readText(url: url).contains("거래일시"))
    }

    /// 엑셀이 「유니코드 텍스트」로 저장하면 UTF-16 이 나온다. BOM 방향도 두 가지다.
    func testBOMVariantsAllDecode() throws {
        let text = "거래일시,자산명\n2027-01-05,BTC\n"
        let variants: [(String, Data)] = [
            ("UTF-8 + BOM", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
            ("UTF-16LE + BOM", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            ("UTF-16BE + BOM", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!)
        ]
        for (label, data) in variants {
            let url = try writeTemp(data)
            defer { try? FileManager.default.removeItem(at: url) }
            let read = try CSVUtil.readText(url: url)
            XCTAssertTrue(read.hasPrefix("거래일시"), "\(label): 앞에 표식이 남았거나 깨졌다 — \(read.prefix(12).debugDescription)")
        }
    }

    /// 빈 파일은 **조용히 0건으로 넘기면 안 된다** — 오류로 알려야 한다
    func testEmptyFileIsReported() throws {
        let url = try writeTemp(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CSVUtil.readText(url: url))
    }

    /// 제네릭 표 매핑까지 이어져야 의미가 있다 — 한글 헤더·한글 거래구분으로 거래가 만들어지는가
    func testGenericMapperReadsKoreanCP949CSV() throws {
        let url = try writeTemp(Self.hexData(Self.cp949Hex))
        defer { try? FileManager.default.removeItem(at: url) }

        let mapper = GenericTabularMapper(timeZoneIdentifier: "Asia/Seoul")
        let result = try mapper.parse(url: url, projectID: ProjectID(), accountID: AccountID())
        XCTAssertEqual(result.events.count, 2, "오류: \(result.errors)")

        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertEqual(buy.baseAsset.code, "BTC")
        XCTAssertEqual(Money.abs(buy.quantity), Decimal(string: "0.5")!)
        XCTAssertEqual(buy.quoteAmount, 25_000_000)

        let sell = try XCTUnwrap(result.events.first { $0.type == .sell })
        XCTAssertEqual(Money.abs(sell.quantity), Decimal(string: "0.2")!)
        XCTAssertEqual(sell.quoteAmount, 12_000_000)
    }
}
