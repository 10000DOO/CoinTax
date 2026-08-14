import XCTest
@testable import CoinTax

/// Trezor Suite CSV 의 **방향 판정과 가스비** 회귀 (7차 감사 D-2 · D-3).
///
/// 합성 fixture 만 쓴다 — 실데이터 수치는 소스에 옮기지 않는다.
final class TrezorDirectionTests: XCTestCase {

    private let pid = ProjectID()
    private let aid = AccountID()

    private static let header = "Timestamp,Date,Time,Type,Transaction ID,Fee,Fee unit,Address,Label,Amount,Amount unit,Fiat (USD),Other"

    private func parse(_ body: String, file: String) throws -> ParseResult {
        try TrezorSuiteCSVParser().parse(text: "\(Self.header)\n\(body)",
                                         fileName: file, projectID: pid, accountID: aid)
    }

    /// 수량 규칙 한 벌이 보는 자산별 순변화 (엔진·검증기가 함께 쓰는 진실)
    private func netQty(_ r: ParseResult) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for e in r.events {
            for c in LedgerDelta.bookChanges(for: e) { out[c.asset.code, default: 0] += c.delta }
        }
        return out
    }

    // MARK: - D-2 비트코인은 **받을 때마다 주소가 새로 생긴다**
    //
    // 하드웨어 지갑(HD 지갑)의 기본 동작이다. 받은 내역 3건이 서로 다른 주소면 3건 모두 입금이다.
    // 예전에는 「가장 많이 나온 주소 하나만 내 것」으로 봐서 나머지를 **출금으로 뒤집었다** —
    // 실사용 파일에서 받은 내역 13건 중 9건(수량 기준 76.5%)이 뒤집혀 보유가 음수가 됐다.
    func test_D2_받을때마다_주소가_달라도_전부_입금() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx1,,,addr-A,,0.5,BTC,10000,
        1767312000,2026. 1. 2.,12:00:00,RECV,tx2,,,addr-B,,0.5,BTC,10000,
        1767398400,2026. 1. 3.,12:00:00,RECV,tx3,,,addr-C,,0.5,BTC,10000,
        """, file: "Bitcoin_1_x.csv")
        XCTAssertEqual(r.events.filter { $0.type == .withdrawal }.count, 0, "받은 것이 출금으로 뒤집히면 안 된다")
        XCTAssertEqual(r.events.filter { $0.type == .deposit }.count, 3)
        XCTAssertEqual(netQty(r)["BTC"], Decimal(string: "1.5")!, "보유 1.5 BTC")
    }

    // MARK: - D-2 대조군 — 보낸 내역은 여전히 출금이어야 한다
    func test_D2_보낸_내역은_출금() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx1,,,addr-A,,2,BTC,20000,
        1767312000,2026. 1. 2.,12:00:00,RECV,tx2,,,addr-B,,1,BTC,10000,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx3,0.0001,BTC,addr-someone-else,,0.5,BTC,5000,
        """, file: "Bitcoin_1_x.csv")
        XCTAssertEqual(r.events.filter { $0.type == .withdrawal }.count, 1)
        XCTAssertEqual(netQty(r)["BTC"], Decimal(string: "2.4999")!, "2 + 1 − 0.5 − 0.0001")
    }

    // MARK: - D-2 디파이 예치 — 두 행 모두 SENT 인데 받은 쪽에는 내 주소가 찍힌다
    //
    // 이 갈래를 잃으면 안 되므로 함께 고정한다. 내 주소는 **받은 행에서** 알아낸다.
    func test_D2_두_행_모두_SENT_인_예치를_주소로_가른다() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx0,,,addr-me,,100,USDT,100,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx2,0.01,ETH,addr-pool,,100,USDT,100,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx2,,,addr-me,,100,trUSDT,,
        """, file: "Ethereum_1_x.csv")
        let received = r.events.filter { $0.type == .deposit }.map(\.baseAsset.code).sorted()
        XCTAssertEqual(received, ["TRUSDT", "USDT"], "영수증 토큰은 받은 것이다")
        XCTAssertEqual(netQty(r)["USDT"], 0, "USDT 는 들어왔다 나갔다")
        XCTAssertEqual(netQty(r)["TRUSDT"], 100)
    }

    // MARK: - D-3 토큰을 보낼 때 낸 **다른 자산** 가스가 수량에서 빠져야 한다
    //
    // USDT 를 보내며 ETH 로 가스를 낸다. 수량 규칙 한 벌은 「수수료 자산이 보내는 자산과
    // 다르면 장부를 건드리지 않는다」이므로, 파서가 수수료로 붙이면 **가스가 통째로 사라진다.**
    // 자산이 다르면 별도 출금으로 빼야 한다 (파서 문서 §5: 「빼지 않으면 장부 수량이 체인과 어긋난다」).
    func test_D3_다른_자산_가스가_수량에서_빠진다() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx0,,,addr-me,,1,ETH,3000,
        1767312000,2026. 1. 2.,12:00:00,RECV,tx1,,,addr-me,,100,USDT,100,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx2,0.01,ETH,addr-other,,100,USDT,100,
        """, file: "Ethereum_1_x.csv")
        let q = netQty(r)
        XCTAssertEqual(q["USDT"] ?? 0, 0, "USDT 는 들어왔다 나갔다")
        XCTAssertEqual(q["ETH"] ?? 0, Decimal(string: "0.99")!, "ETH 1 − 가스 0.01")
    }

    // MARK: - D-3 대조군 — 가스 자산과 보내는 자산이 같으면 이중으로 빠지면 안 된다
    func test_D3_같은_자산_가스는_한_번만_빠진다() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx0,,,addr-me,,1,BTC,10000,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx2,0.0001,BTC,addr-other,,0.5,BTC,5000,
        """, file: "Bitcoin_1_x.csv")
        XCTAssertEqual(netQty(r)["BTC"], Decimal(string: "0.4999")!, "1 − 0.5 − 0.0001 (가스는 한 번만)")
    }

    // MARK: - D-3 코인이 안 움직이고 가스만 나간 트랜잭션 (기존 동작 유지)
    func test_D3_가스만_나간_트랜잭션() throws {
        let r = try parse("""
        1767225600,2026. 1. 1.,12:00:00,RECV,tx0,,,addr-me,,1,ETH,3000,
        1767398400,2026. 1. 3.,12:00:00,SENT,tx1,0.002,ETH,addr-contract,,0,ETH,,
        """, file: "Ethereum_1_x.csv")
        XCTAssertEqual(netQty(r)["ETH"], Decimal(string: "0.998")!, "1 − 가스 0.002")
        XCTAssertTrue(r.events.contains { $0.lostForever }, "가스는 되돌아오지 않는다")
    }

    // MARK: - 받은 내역이 없으면 여전히 막아야 한다 (방향의 근거가 없다)
    func test_받은_내역이_없으면_거부() throws {
        XCTAssertThrowsError(try parse("""
        1767398400,2026. 1. 3.,12:00:00,SENT,tx1,0.0001,BTC,addr-other,,0.5,BTC,5000,
        """, file: "Bitcoin_1_x.csv"))
    }
}
