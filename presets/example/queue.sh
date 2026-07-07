# Example worker / job-queue presets (committed, generic).
#
#   define_preset <name> <promql|logql> <query> [description]

define_preset "queue/depth-by-name" promql \
  'sum by (queue) (job_queue_size{state="pending"})' \
  "Pending job count by queue"

define_preset "queue/errors" logql \
  '{app="my-worker"} |~ "(?i)error|fail|timeout"' \
  "Worker error log lines"
