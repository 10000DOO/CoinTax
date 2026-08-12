import Foundation

/// 거래소 파일의 행 순서를 **시간 오름차순**으로 바로잡고, 그 순서를 `rawRef` 에 새긴다.
///
/// ## 왜 필요한가
///
/// 거래소 export 는 대부분 **최신 거래가 맨 위**다. 원장은 시간순으로 재생해야 하는데,
/// 같은 시각(초 단위까지 같은) 거래가 여러 건이면 엔진은 `rawRef` 로 순서를 가른다.
/// 파일 순서를 그대로 두면 그 순간의 순서가 **거꾸로** 들어간다.
///
/// 실데이터에서 실제로 일어났다 — 거래소가 찍어준 잔고와 앱 계산이 어긋나 V-BAL 이 잡아냈다.
/// 빗썸은 같은 초의 매수 두 건이 뒤집혔고, OKX 는 매수에 쓴 입금이 그 매수보다 **뒤에** 처리됐다.
/// 순서가 뒤집히면 이동평균 평단이 달라지고, 「보유보다 많은 처분」이 거짓으로 뜬다.
///
/// ## 파일 방향은 파일 자체로 판정한다
///
/// 거래소마다·판본마다 다르므로 문서를 보고 단정하지 않는다.
/// 첫 행과 마지막 행의 시각을 비교해 최신순이면 뒤집는다.
enum RowOrder {
    /// `rawRef` 앞에 붙는 시간순 순번의 자릿수. 10만 행까지 사전식 비교가 시간순과 일치한다.
    private static let width = 5

    /// - Parameter events: **파일에 적힌 순서 그대로** 의 이벤트 목록
    /// - Returns: 시간 오름차순으로 정렬되고 `rawRef` 에 순번이 새겨진 목록
    static func chronological(_ events: [LedgerEvent]) -> [LedgerEvent] {
        guard events.count > 1 else { return stamp(events) }

        // 파일 방향 판정: 처음으로 시각이 다른 두 지점을 찾아 비교한다.
        // 앞뒤 몇 건이 같은 시각일 수 있으므로 첫 행·끝 행만 보면 판정이 안 된다.
        var newestFirst = false
        outer: for a in events.indices {
            for b in stride(from: events.count - 1, through: a + 1, by: -1) {
                if events[a].timestamp != events[b].timestamp {
                    newestFirst = events[a].timestamp > events[b].timestamp
                    break outer
                }
            }
        }

        let fileOrdered = newestFirst ? events.reversed().map { $0 } : events
        // 안정 정렬 — Swift 의 `sort` 는 안정성을 보장하지 않으므로 원래 위치를 키에 넣는다.
        let sorted = fileOrdered.enumerated()
            .sorted {
                if $0.element.timestamp != $1.element.timestamp {
                    return $0.element.timestamp < $1.element.timestamp
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
        return stamp(sorted)
    }

    /// 이미 시간 오름차순인 목록에 순번만 새긴다.
    static func stamp(_ events: [LedgerEvent]) -> [LedgerEvent] {
        events.enumerated().map { index, event in
            var e = event
            let seq = String(format: "s%0\(width)d", index + 1)
            // 원본 위치는 그대로 남긴다 — 사용자가 원본에서 그 행을 찾을 수 있어야 한다
            e.rawRef = e.rawRef.map { "\(seq)|\($0)" } ?? seq
            return e
        }
    }
}
