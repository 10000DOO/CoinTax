# 설계 요약 (포인터)

| 항목 | 내용 |
|------|------|
| 버전 | 2.1 |
| 일자 | 2026-08-11 |
| 상태 | **구현 시작점 = [IMPLEMENTATION.md](./IMPLEMENTATION.md)** |

## 원본 포맷 (확정)

| 거래소 | 형식 | 비고 |
|--------|------|------|
| 빗썸 | **PDF** 거래내역 확인서 | 엑셀 없음 |
| 바이낸스 | **XLSX** Spot Trade History | 입출금 별도 파일 필요 |
| OKX | **CSV** Trading History | 1행 메타, Spot+Transfer |

- **구현 핸드북:** [IMPLEMENTATION.md](./IMPLEMENTATION.md)  
- **알고리즘·타입·골든:** [design/14-implementation-spec.md](./design/14-implementation-spec.md)  
- Import 총괄: [04-import-formats.md](./04-import-formats.md)  
- 스키마: [parsers/](./parsers/)  
- 아키텍처→상세: [design/README.md](./design/README.md)  

CSV 전용 가정·`ExchangeCSVParser`·`CSV/` 모듈명은 **폐기**.  
→ `ExchangeDocumentParser` · `Import/` 모듈.

구 `04-csv-import.md` · `design/09-csv-and-matching.md` 는 리다이렉트만 남김.
