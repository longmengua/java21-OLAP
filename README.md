# java21-OLAP

一個基於 **Java 21 + Spring Boot + Kafka + Flink + ClickHouse** 的簡易 OLAP 實驗專案。  
目標是模擬「下單 → 撮合 → 成交 → ETL → OLAP 查詢」的完整鏈路，並能在 ClickHouse 中進行即時分析。

---

## 架構描述

[Order Generator] --(orders topic)--> [Matching Service] --(trades topic)--> [Flink ETL] --> [ClickHouse] --> [OLAP API / BI]

- Order Generator (Spring Boot)
    - Cron job 定時產生模擬下單事件
    - 發送到 Kafka `orders` topic

- Matching Service (Spring Boot, 獨立模組)
    - 消費 `orders` topic
    - In-memory order book 撮合邏輯
    - 成交後寫 `trades` topic
    - 同時寫 WAL + 快照，避免重啟丟狀態

- Kafka (KRaft)
    - topics: `orders`, `trades`, `dlq.*`

- Flink ETL (DataStream Job)
    - Source: Kafka `trades`
    - Transformation: schema 驗證、清洗、補欄位
    - Sink: 批量 INSERT INTO ClickHouse
    - Checkpoint 開啟，保證一致性

- ClickHouse
    - Table: `spot_trade` (ReplacingMergeTree)
    - Key: (symbol, trade_time, trade_id)
    - 可保證幂等寫入、支援 OLAP 查詢

- OLAP API (Spring Boot)
    - REST API 提供每日成交量/額、TopN 用戶、分位數查詢
    - BI 工具 (Superset/Grafana) 可直接連 CH 做分析

---

## 任務分解

### Phase 0｜基礎設施與骨架（P0）

目標：開出最小可跑鏈路：Cron → orders → match → trades → Flink → ClickHouse。

- **P0-1｜Repo 初始化（Maven 多模組）**  
  `olap-pipeline/`（parent）＋ `order-app/`、`matching-svc/`、`flink-etl/`、`olap-api/`  
  ✅ `mvn -T 1C -DskipTests package` 成功

- **P0-2｜Docker Compose：Kafka(KRaft) + ClickHouse**  
  Topics: `orders`, `trades`, `dlq.orders`, `dlq.trades`, `dlq.etl`  
  ✅ `docker compose up -d` healthy

- **P0-3｜事件契約 v1（Avro/Protobuf + Schema Registry）**  
  定義 `OrderCreated.avsc`、`TradeExecuted.avsc`，Producer/Consumer 使用 Schema Registry  
  ✅ 驗收：schema 發佈，兼容策略設為 **BACKWARD**

- **P0-4｜Order Generator（order-app）**  
  `@Scheduled(cron)` 產單（隨機化），發送到 `orders`  
  ✅ 驗收：Kafka 消息率、錯誤率 < 1‰

- **P0-5｜Matching Service（matching-svc）**  
  消費 `orders`，撮合成交後寫入 `trades`，並保存 WAL + 快照  
  ✅ 驗收：重啟後可回放 WAL 恢復，trade 序列連續

- **P0-6｜Flink ETL（flink-etl）**  
  Kafka Source(`trades`) → schema 驗證 → 清洗 → 批量 JDBC sink 到 CH  
  Checkpoint enabled  
  ✅ 驗收：重啟/回放不重覆；CH count == trades 去重 count

- **P0-7｜ClickHouse DDL**  
  `spot_trade` (ReplacingMergeTree)，必要索引與 partition  
  ✅ 驗收：`SELECT count(), uniqExact(trade_id)` 相等

---

### Phase 1｜可靠性與觀測性（P0）

- **P1-1｜幂等與去重**  
  `trade_id` 主鍵；ReplacingMergeTree + `version`；Flink sink buffer + 重試  
  ✅ 驗收：壓測下重播 10x 無重覆

- **P1-2｜DLQ 與重處理**  
  三條 DLQ：`dlq.orders` / `dlq.trades` / `dlq.etl`；提供 `dlq-replayer`  
  ✅ 驗收：壞消息進 DLQ，重放後恢復

- **P1-3｜監控/告警**  
  指標：Kafka lag、Flink latency、CH insert error、QPS  
  ✅ 驗收：kill 任一組件 → 有告警 & 自恢復

---

### Phase 2｜可擴展性（P1）

- **P2-1｜撮合分片與水平擴展**  
  按 `symbol` 分片，每分片單 writer；WAL/快照分片管理  
  ✅ 驗收：雙倍輸入量下，延遲可控

- **P2-2｜Schema 演進流程**  
  PR → schema 發佈（compat check）→ Canary → 全量  
  ✅ 驗收：新增欄位不中斷

- **P2-3｜Flink 計算擴展（可選）**  
  加入撮合延遲、引擎序列號，支援維表 Join  
  ✅ 驗收：延遲/丟數可接受

---

### Phase 3｜OLAP API 與分析（P1）

- **P3-1｜OLAP API（Spring Boot）**  
  提供 `/olap/daily`, `/olap/top-users`, `/olap/quantiles`  
  ✅ 驗收：接口 p95 < 300ms

- **P3-2｜BI 儀表板**  
  Superset/Grafana：成交量、成交額、TopN、延遲分佈  
  ✅ 驗收：看板可用

---

## 風險 & 對策

- 撮合一致性：WAL + 快照，單分片單 writer，重放保序（`engine_seq`）
- 重覆寫入：ClickHouse ReplacingMergeTree + `trade_id` 唯一鍵；Flink sink 批量 + 重試
- 模式演進：Schema Registry 強制兼容策略
- 背壓與批量：Flink sink 批量大小/flush 週期調優，ClickHouse HTTP 壓縮
- DLQ 堆積：DLQ 消費速率 + 重放工具
- 觀測缺口：端到端延遲（source ts→sink ts）指標與告警

---

## Issue Checklist（建議優先順序）

### P0（必做）
- [x] 初始化 Maven 多模組與父 POM
- [ ] Docker Compose：Kafka(KRaft)、ClickHouse、Schema Registry
- [ ] 定義 Avro/Protobuf schema（orders/trades）+ 發佈
- [ ] order-app：Cron 產單
- [ ] matching-svc：撮合核心（FIFO、價格優先）；WAL/快照
- [ ] matching-svc：Producer 發 trades；失敗重試與 DLQ
- [ ] ClickHouse DDL：`spot_trade`
- [ ] flink-etl：Kafka Source(`trades`) → Avro 解析 → JDBC sink
- [ ] flink-etl：checkpoint、幂等處理
- [ ] 煙囪測試：端到端打通、重播驗證

### P1（可靠性/可觀測）
- [ ] DLQ 三條：`dlq.orders` / `dlq.trades` / `dlq.etl`；重放工具
- [ ] 監控：Kafka lag、Flink 指標、CH insert 失敗；告警規則
- [ ] 壓測：倍增輸入量，測 latency 與丟失率

### P1（擴展/OLAP）
- [ ] olap-api：REST 查詢接口
- [ ] BI 看板：成交量、成交額、TopN、延遲

---

## 驗收清單

- **端到端一致**：`orders -> trades -> CH` 總數（去重後）一致
- **重放一致**：清空快照 → 從 WAL 回放 → `trade_id` 集合一致
- **容錯**：隨機 kill Flink/Matching → 恢復後不重覆、不丟數
- **延遲**：端到端（產單→CH 查詢）符合 SLA
- **Schema 演進**：新增欄位不中斷

---

## ClickHouse DDL

```sql
CREATE TABLE IF NOT EXISTS spot_trade (
  trade_id     String,
  buy_order_id String,
  sell_order_id String,
  buy_user_id  UInt64,
  sell_user_id UInt64,
  symbol       LowCardinality(String),
  price        Decimal(18,8),
  quantity     Decimal(20,8),
  amount       Decimal(20,8),
  trade_time   DateTime('UTC'),
  version      UInt64 DEFAULT 1,
  etl_time     DateTime('UTC') DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(trade_time)
ORDER BY (symbol, trade_time, trade_id);
