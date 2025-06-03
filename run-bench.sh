#!/usr/bin/env bash
set -euo pipefail

# ──────────── Defaults ───────────────────────────────────────────────
NAMESPACE="llm-d"
IMAGE="ghcr.io/nerdalert/vllm-bench:latest"
JOB_BASE_NAME="vllm-bench-job"
TIMEOUT="2000s"

MODEL=""
BASE_URL=""
DATASET_NAME="random"
RANDOM_INPUT_LEN="1000"
RANDOM_OUTPUT_LEN="100"
IGNORE_EOS="true"

# always-on
SAVE_RESULT="true"
RESULT_FILENAME="results.json"
METADATA="deployment=no-features gpu=4xL40 prefill=0 decode=4"

# loop settings
DURATION=30
RATES="10,20,inf"

# optional override for number of prompts, used only for the Inf run
PROMPTS_OVERRIDE=""

die(){ echo "❌ $*" >&2; exit 1; }
usage(){
  cat <<EOF
Usage: $0 [wrapper-opts] --model MODEL --base_url URL[:PORT] [--request-rates R1,R2,..] [--duration S]
                 [--input-len N] [--output-len N] [--num-prompts N]

Wrapper options:
  --namespace       K8s namespace          (default $NAMESPACE)
  --image           Container image        (default $IMAGE)
  --timeout         kubectl wait timeout   (default $TIMEOUT)
  --metadata        metadata key=val…      (default "$METADATA")
  --result-file     local filename         (default "$RESULT_FILENAME")

Benchmark flags:
  --model            MODEL                 (required)
  --base_url         URL[:PORT]            (required)
  --dataset-name     NAME                  (default $DATASET_NAME)
  --input-len        tokens per prompt     (default $RANDOM_INPUT_LEN)
  --output-len       tokens generated      (default $RANDOM_OUTPUT_LEN)
  --ignore-eos        (flag)
  --request-rates            comma list of QPS     (default "$RATES")
  --duration         seconds per QPS       (default $DURATION)
  --num-prompts      override total prompts for Inf run

Example:
  $0 --model meta-llama/... \\
     --base_url http://gateway:80 \\
     --request-rates 1,5,10,inf --duration 120 \\
     --input-len 1000 --output-len 200 \\
     --num-prompts 10000
EOF
  exit 1
}

# ────────── Parse CLI ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)      NAMESPACE="$2";       shift 2;;
    --image)          IMAGE="$2";           shift 2;;
    --timeout)        TIMEOUT="$2";         shift 2;;
    --metadata)       METADATA="$2";        shift 2;;
    --result-file)    RESULT_FILENAME="$2";  shift 2;;
    --model)          MODEL="$2";           shift 2;;
    --base_url)       BASE_URL="$2";        shift 2;;
    --dataset-name)   DATASET_NAME="$2";    shift 2;;
    --input-len)      RANDOM_INPUT_LEN="$2";shift 2;;
    --output-len)     RANDOM_OUTPUT_LEN="$2";shift 2;;
    --ignore-eos)     IGNORE_EOS="true";     shift 1;;
    --request-rates)  RATES="$2";           shift 2;;
    --duration)       DURATION="$2";        shift 2;;
    --num-prompts)    PROMPTS_OVERRIDE="$2";shift 2;;
    -h|--help)        usage;;
    *) die "Unknown option: $1";;
  esac
done

# ────────── Validate required ───────────────────────────────────────
[[ -z "$MODEL"    ]] && die "--model is required"
[[ -z "$BASE_URL" ]] && die "--base_url is required"
[[ -z "${HF_TOKEN:-}" ]] && die "HF_TOKEN must be set in your environment"

# ────────── Ensure results file exists (don’t overwrite if present) ────
if [[ ! -e "$RESULT_FILENAME" ]]; then
  touch "$RESULT_FILENAME"
fi

# ensure namespace & HF_TOKEN secret
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl -n "$NAMESPACE" delete secret hf-token-secret --ignore-not-found
kubectl -n "$NAMESPACE" create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN"

# split rates
IFS=',' read -r -a ALL_RATES <<<"$RATES"

# compute max numeric rate (for Inf fallback)
max_rate=0
for r in "${ALL_RATES[@]}"; do
  if [[ "$r" =~ ^[0-9]+$ ]] && (( r > max_rate )); then
    max_rate=$r
  fi
done

echo "▶️  Benchmarking MODEL=$MODEL at rates: ${ALL_RATES[*]} QPS for $DURATION seconds each"
echo "🔖 Results will go into ./$RESULT_FILENAME"

# ────────── Numeric‐rate loop ────────────────────────────────────
for QPS in "${ALL_RATES[@]}"; do
  # skip Inf here
  if [[ "$(echo "$QPS" | awk '{print tolower($0)}')" == "inf" ]]; then
    continue
  fi

  NUM_PROMPTS=$(( QPS * DURATION ))
  JOB_NAME="${JOB_BASE_NAME}-${QPS}qps"

  kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found

  cat <<EOF >/tmp/${JOB_NAME}.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: bench
        image: ${IMAGE}
        imagePullPolicy: Always
        envFrom:
        - secretRef:
            name: hf-token-secret
        env:
        - name: MODEL
          value: "${MODEL}"
        - name: BASE_URL
          value: "${BASE_URL}"
        - name: DATASET_NAME
          value: "${DATASET_NAME}"
        - name: RANDOM_INPUT_LEN
          value: "${RANDOM_INPUT_LEN}"
        - name: RANDOM_OUTPUT_LEN
          value: "${RANDOM_OUTPUT_LEN}"
        - name: REQUEST_RATE
          value: "${QPS}"
        - name: NUM_PROMPTS
          value: "${NUM_PROMPTS}"
        - name: IGNORE_EOS
          value: "${IGNORE_EOS}"
        - name: SAVE_RESULT
          value: "true"
        - name: RESULT_FILENAME
          value: "${RESULT_FILENAME}"
        - name: METADATA
          value: "${METADATA}"
EOF

  echo "🚀 Launching $JOB_NAME (QPS=$QPS, prompts=$NUM_PROMPTS)…"
  kubectl apply -f /tmp/${JOB_NAME}.yaml
  kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "$NAMESPACE" --timeout="$TIMEOUT"

  POD=$(kubectl get pod -n "$NAMESPACE" -l job-name="$JOB_NAME" \
        -o jsonpath='{.items[0].metadata.name}')

  echo "📖 Logs from $JOB_NAME:"
  LOGS=$(kubectl logs -n "$NAMESPACE" "$POD")
  echo "$LOGS"

  # extract just the JSON between our markers
  echo "$LOGS" \
    | sed -n '/<<<RESULT_START>>>/,/<<<RESULT_END>>>/p' \
    | sed '1d;$d' >> "$RESULT_FILENAME"

  echo "Appended results block for ${QPS} QPS"

  echo "Cleaning up Job ${JOB_NAME}..."
  kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found

done

# ────────── Infinite‐rate run ─────────────────────────────────────
if printf '%s\n' "${ALL_RATES[@]}" | grep -iq '^inf$'; then
  QPS="inf"
  # use override if given, else fallback to max_rate * duration
  if [[ -n "$PROMPTS_OVERRIDE" ]]; then
    NUM_PROMPTS="$PROMPTS_OVERRIDE"
  else
    NUM_PROMPTS=$(( max_rate * DURATION ))
  fi

  JOB_NAME="${JOB_BASE_NAME}-inf"

  kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found

  cat <<EOF >/tmp/${JOB_NAME}.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: bench
        image: ${IMAGE}
        imagePullPolicy: Always
        envFrom:
        - secretRef:
            name: hf-token-secret
        env:
        - name: MODEL
          value: "${MODEL}"
        - name: BASE_URL
          value: "${BASE_URL}"
        - name: DATASET_NAME
          value: "${DATASET_NAME}"
        - name: RANDOM_INPUT_LEN
          value: "${RANDOM_INPUT_LEN}"
        - name: RANDOM_OUTPUT_LEN
          value: "${RANDOM_OUTPUT_LEN}"
        - name: REQUEST_RATE
          value: "inf"
        - name: NUM_PROMPTS
          value: "${NUM_PROMPTS}"
        - name: IGNORE_EOS
          value: "${IGNORE_EOS}"
        - name: SAVE_RESULT
          value: "true"
        - name: RESULT_FILENAME
          value: "${RESULT_FILENAME}"
        - name: METADATA
          value: "${METADATA}"
EOF

  echo "🚀 Launching $JOB_NAME (infinite QPS, prompts=$NUM_PROMPTS)…"
  kubectl apply -f /tmp/${JOB_NAME}.yaml
  kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "$NAMESPACE" --timeout="$TIMEOUT"

  POD=$(kubectl get pod -n "$NAMESPACE" -l job-name="$JOB_NAME" \
        -o jsonpath='{.items[0].metadata.name}')

  echo "📖 Logs from $JOB_NAME:"
  LOGS=$(kubectl logs -n "$NAMESPACE" "$POD")
  echo "$LOGS"

  echo "$LOGS" \
    | sed -n '/<<<RESULT_START>>>/,/<<<RESULT_END>>>/p' \
    | sed '1d;$d' >> "$RESULT_FILENAME"

  echo "Appended results block for infinite QPS"
fi

echo "Cleaning up Job ${JOB_NAME}..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "✅ All benchmarks complete. Combined results in ./$RESULT_FILENAME"
