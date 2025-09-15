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
