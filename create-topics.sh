#!/usr/bin/env bash
set -euo pipefail

# === 依你現在的 compose 設定 ===
# 外部可連的 broker（從主機執行腳本時的預設）
BROKER="${1:-localhost:9092}"

# compose 服務名（你的 docker-compose.yml 裡是 single-kafka）
KAFKA_SERVICE="${KAFKA_SERVICE:-single-kafka}"

# 在容器裡面連用的 internal listener（避免被回拋 localhost）
INTERNAL_BROKER="${INTERNAL_BROKER:-single-kafka:9094}"

# docker compose 指令（可用 DC=... 覆寫）
DC="${DC:-docker compose}"

# 要建立的 topics
TOPICS=("orders" "trades" "dlq.orders" "dlq.trades" "dlq.etl")

echo "✅ 將建立 topics：${TOPICS[*]}"
echo "✅ 預設外部 broker：${BROKER}"
echo "✅ compose 服務名：${KAFKA_SERVICE}（若偵測到運行，將改用內部 broker：${INTERNAL_BROKER}）"

# 小工具：等待 broker 就緒
wait_for_broker() {
  local cmd="$1"
  local bs="$2"
  local tries=30
  local i=1
  echo "⏳ 等待 Kafka (${bs}) 就緒..."
  until $cmd --bootstrap-server "$bs" --list >/dev/null 2>&1; do
    if (( i >= tries )); then
      echo "❌ 等待 Kafka 逾時（$tries 次）"
      return 1
    fi
    sleep 2
    ((i++))
  done
  echo "👍 Kafka (${bs}) 就緒"
}

# 檢查 compose 服務是否存在且在跑
use_compose_exec=false
if $DC ps --services >/dev/null 2>&1; then
  if $DC ps --services | grep -qx "${KAFKA_SERVICE}"; then
    # 有時新版 compose 的狀態顯示為 "running" 或 "Up"
    if $DC ps | grep -E "^\s*${KAFKA_SERVICE}\s" | grep -qE 'running|Up'; then
      use_compose_exec=true
    fi
  fi
fi

if $use_compose_exec; then
  echo "🧩 偵測到 compose 服務 '${KAFKA_SERVICE}' 正在運行，改用 compose exec + 內部 broker：${INTERNAL_BROKER}"

  # 等待 broker
  wait_for_broker "$DC exec -T ${KAFKA_SERVICE} kafka-topics.sh" "${INTERNAL_BROKER}"

  # 建立 topics
  for t in "${TOPICS[@]}"; do
    $DC exec -T "${KAFKA_SERVICE}" kafka-topics.sh \
      --bootstrap-server "${INTERNAL_BROKER}" \
      --create --topic "${t}" --if-not-exists \
      --partitions 3 --replication-factor 1
  done

  echo "📃 Topics："
  $DC exec -T "${KAFKA_SERVICE}" kafka-topics.sh --bootstrap-server "${INTERNAL_BROKER}" --list

else
  echo "🧭 未偵測到 compose 服務 '${KAFKA_SERVICE}'"
fi
