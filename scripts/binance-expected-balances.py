#!/usr/bin/env python3
"""바이낸스 원본에서 **앱과 무관하게** 잔고를 다시 계산해 정답지를 만든다.

바이낸스 화면 CSV 에는 거래소가 찍어준 잔고 열이 없다. 빗썸·OKX 는 그 열로 자동 대조(V-BAL)가
되는데 바이낸스만 사각지대로 남는다. 그래서 원본 CSV 를 **Swift 코드를 전혀 쓰지 않고**
여기서 따로 계산해 두고, 테스트가 앱 결과와 맞춰 본다.

한계 (정직하게):
  같은 사람이 쓴 두 번째 구현이라 «규칙 자체를 잘못 이해한» 오류는 둘 다 똑같이 틀릴 수 있다.
  잡아내는 것은 파싱(단위 접미사·타임존·건너뛴 행)과 산술, 그리고 이후의 회귀다.
  바이낸스 입금액은 빗썸·OKX 출금과 짝이 맞으므로 그쪽은 외부 근거가 따로 있다.

사용:
  python3 scripts/binance-expected-balances.py
    → docs/samples/raw/derived/binance-expected-balances.json  (원본 폴더 = .gitignore)
"""
import csv
import io
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "docs", "samples", "raw")
OUT_DIR = os.path.join(RAW, "derived")
KST = timezone(timedelta(hours=9))

UNIT_RE = re.compile(r"^\s*(-?[\d,.]+)\s*([A-Za-z0-9]*)\s*$")


def read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        text = f.read().replace("﻿", "")
    rows = list(csv.reader(io.StringIO(text)))
    return rows


def split_amount_unit(raw):
    """`0.3699XAUT` → (Decimal('0.3699'), 'XAUT')"""
    m = UNIT_RE.match(raw or "")
    if not m:
        return None, None
    num = m.group(1).replace(",", "")
    if num in ("", "-", "."):
        return None, None
    return Decimal(num), (m.group(2) or None)


def file_timezone(name):
    """파일명의 `(UTC+9)` 표기. 없으면 UTC."""
    m = re.search(r"UTC([+-]\d{1,2})(?::(\d{2}))?", name)
    if not m:
        return timezone.utc
    hours = int(m.group(1))
    minutes = int(m.group(2) or 0)
    sign = 1 if hours >= 0 else -1
    return timezone(timedelta(hours=hours, minutes=sign * minutes))


def parse_time(value, tz):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(value.strip(), fmt).replace(tzinfo=tz)
        except ValueError:
            continue
    return None


def find_files():
    out = {"spot": [], "deposit": [], "withdraw": []}
    for dirpath, _, names in os.walk(RAW):
        if os.path.basename(dirpath) == "derived":
            continue
        for n in names:
            low = n.lower()
            if not low.endswith(".csv") or "binance" not in low:
                continue
            path = os.path.join(dirpath, n)
            if "spot" in low:
                out["spot"].append(path)
            elif "deposit" in low:
                out["deposit"].append(path)
            elif "withdraw" in low:
                out["withdraw"].append(path)
    return out


def collect_events():
    """(시각, 자산, 증감) 목록. 앱과 같은 규칙이지만 코드는 완전히 별개다."""
    files = find_files()
    events = []

    for path in files["spot"]:
        tz = file_timezone(os.path.basename(path))
        rows = read_csv(path)
        header = [h.strip() for h in rows[0]]
        idx = {h: i for i, h in enumerate(header)}
        for row in rows[1:]:
            if len(row) < len(header):
                continue
            ts = parse_time(row[idx["Time"]], tz)
            if ts is None:
                continue
            side = row[idx["Side"]].strip().upper()
            executed, base = split_amount_unit(row[idx["Executed"]])
            amount, quote = split_amount_unit(row[idx["Amount"]])
            fee, fee_unit = split_amount_unit(row[idx["Fee"]])
            if executed is None or amount is None or base is None or quote is None:
                continue
            if side == "BUY":
                gained = executed
                # 기초자산으로 낸 수수료는 받는 수량에서 깎인다
                if fee and fee_unit == base:
                    gained -= fee
                events.append((ts, base, gained))
                events.append((ts, quote, -amount))
            elif side == "SELL":
                events.append((ts, base, -executed))
                events.append((ts, quote, amount))
                # 매도의 기초자산 수수료는 체결 수량과 **별도로** 빠진다
                if fee and fee_unit == base:
                    events.append((ts, base, -fee))
            else:
                continue
            # 그 밖의 코인 수수료 (BNB 등)
            if fee and fee_unit and fee_unit not in ("KRW",) and fee_unit != base:
                events.append((ts, fee_unit, -fee))

    for path in files["deposit"]:
        tz = file_timezone(os.path.basename(path))
        rows = read_csv(path)
        header = [h.strip() for h in rows[0]]
        idx = {h: i for i, h in enumerate(header)}
        date_key = next(k for k in ("Date(UTC+0)", "Date(UTC)", "Time") if k in idx)
        for row in rows[1:]:
            if len(row) < len(header):
                continue
            if "Status" in idx and row[idx["Status"]].strip().lower() not in ("", "completed"):
                continue
            ts = parse_time(row[idx[date_key]], tz)
            amount, _ = split_amount_unit(row[idx["Amount"]])
            if ts is None or amount is None:
                continue
            events.append((ts, row[idx["Coin"]].strip(), amount))

    for path in files["withdraw"]:
        tz = file_timezone(os.path.basename(path))
        rows = read_csv(path)
        header = [h.strip() for h in rows[0]]
        idx = {h: i for i, h in enumerate(header)}
        date_key = next(k for k in ("Date(UTC+0)", "Date(UTC)", "Time") if k in idx)
        for row in rows[1:]:
            if len(row) < len(header):
                continue
            if "Status" in idx and row[idx["Status"]].strip().lower() not in ("", "completed"):
                continue
            ts = parse_time(row[idx[date_key]], tz)
            amount, _ = split_amount_unit(row[idx["Amount"]])
            fee, _ = split_amount_unit(row[idx["Fee"]]) if "Fee" in idx else (None, None)
            if ts is None or amount is None:
                continue
            coin = row[idx["Coin"]].strip()
            # 출금 수수료는 원금과 **별도로** 지갑에서 빠진다 (상대 거래소 입금액 = Amount 로 확인됨)
            events.append((ts, coin, -amount))
            if fee:
                events.append((ts, coin, -fee))

    return events


def main():
    if not os.path.isdir(RAW):
        print(f"원본 폴더가 없습니다: {RAW}", file=sys.stderr)
        return 1
    events = collect_events()
    if not events:
        print("바이낸스 원본을 찾지 못했습니다", file=sys.stderr)
        return 1

    events.sort(key=lambda e: e[0])
    running = defaultdict(Decimal)
    daily = defaultdict(dict)   # 'YYYY-MM-DD' -> {asset: balance}
    for ts, asset, delta in events:
        running[asset] += delta
        day = ts.astimezone(KST).strftime("%Y-%m-%d")
        daily[day][asset] = str(running[asset])

    payload = {
        "note": "앱과 무관하게 원본에서 다시 계산한 바이낸스 잔고 (정답지). 개인 재무정보 — 커밋 금지.",
        "eventCount": len(events),
        "final": {a: str(v) for a, v in sorted(running.items())},
        "dailyClose": {d: daily[d] for d in sorted(daily)},
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "binance-expected-balances.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"기록: {out}")
    print(f"  이벤트 {len(events)}건 · 자산 {len(running)}종 · 일자 {len(daily)}일")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
