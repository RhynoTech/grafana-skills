# Example Kafka presets (committed, generic).
#
# Copy this pattern into presets/local/<group>.sh (gitignored) with your real
# metric names / topics. incident.sh loads presets/local/*.sh if present,
# otherwise presets/example/*.sh. See the author-preset skill for help
# writing new ones.
#
#   define_preset <name> <promql|logql> <query> [description]

define_preset "kafka/topic-produce-rate" promql \
  'sum by (topic) (rate(kafka_topic_partition_current_offset{topic="my-topic"}[5m]))' \
  "Produce rate into a topic (messages/sec)"

define_preset "kafka/consumer-lag" promql \
  'sum by (consumergroup, topic) (kafka_consumergroup_lag{topic="my-topic"})' \
  "Consumer group lag for a topic"

define_preset "kafka/consumer-errors" logql \
  '{app="my-consumer"} |~ "(?i)rebalance|timeout|failed|exception"' \
  "Consumer error/rebalance log lines"
