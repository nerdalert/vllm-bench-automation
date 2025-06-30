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
# SEED_VALUE will store the user-provided seed. If empty, a new timestamp will be used per iteration.
SEED_VALUE=""

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
                 [--input-len N] [--output-len N] [--num-prompts N] [--seed N]

Wrapper options:
  --namespace       K8s namespace          (default $NAMESPACE)
  --image           Container image        (default $IMAGE)
  --timeout         kubectl wait timeout   (default $TIMEOUT)
  --metadata        metadata key=val…      (default "$METADATA")
  --result-file     local filename         (default "$RESULT_FILENAME")

Benchmark flags (passed to the container):
  --model            MODEL                 (required)
  --base_url         URL[:PORT]            (required)
  --dataset-name     NAME                  (default $DATASET_NAME)
  --input-len        tokens per prompt     (default $RANDOM_INPUT_LEN)
  --output-len       tokens generated      (default $RANDOM_OUTPUT_LEN)
  --ignore-eos       (flag, default if not specified: false, here: $IGNORE_EOS)
  --seed             Random seed for vLLM  (default: timestamp, e.g., $(date +%s))
  --request-rates    comma list of QPS     (default "$RATES")
  --duration         seconds per QPS       (default $DURATION)
  --num-prompts      override total prompts for Inf run (optional)

Example:
  $0 --model meta-llama/... \\
     --base_url http://gateway:80 \\
     --request-rates 1,5,10,inf --duration 120 \\
     --input-len 1000 --output-len 200 \\
     --num-prompts 10000 \\
     --seed 42 # Uses seed 42 for all request rate iterations
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
    --seed)           SEED_VALUE="$2";      shift 2;;
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
if [[ -n "$SEED_VALUE" ]]; then
  echo "🌱 Using user-provided fixed SEED=$SEED_VALUE for all request rates."
else
  echo "🌱 Generating a new timestamp SEED for each request rate iteration."
fi
echo "🔖 Results will go into ./$RESULT_FILENAME"

# ────────── Numeric‐rate loop ────────────────────────────────────
for QPS in "${ALL_RATES[@]}"; do
  # skip Inf here
  if [[ "$(echo "$QPS" | awk '{print tolower($0)}')" == "inf" ]]; then
    continue
  fi

  NUM_PROMPTS=$(( QPS * DURATION ))
  JOB_NAME="${JOB_BASE_NAME}-${QPS}qps"

  # Determine the seed for the current job
  current_job_seed=""
  if [[ -n "$SEED_VALUE" ]]; then # User provided a specific seed
    current_job_seed="$SEED_VALUE"
  else # User did not provide a seed, generate a new one for this iteration
    current_job_seed=$(date +%s)
  fi
  echo "  🌱 For QPS=$QPS, using SEED=$current_job_seed"


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
        - name: SEED
          value: "${current_job_seed}"
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
    if (( NUM_PROMPTS == 0 )); then # Handle case where max_rate might be 0 if only 'inf' is provided
        NUM_PROMPTS=900 # Fallback to a default number of prompts for 'inf' if no numeric rates given
        echo "⚠️ No numeric rates provided to calculate NUM_PROMPTS for 'inf' run, defaulting to ${NUM_PROMPTS} prompts."
    fi
  fi

  JOB_NAME="${JOB_BASE_NAME}-inf"

  # Determine the seed for the current job (inf rate)
  current_job_seed=""
  if [[ -n "$SEED_VALUE" ]]; then # User provided a specific seed
    current_job_seed="$SEED_VALUE"
  else # User did not provide a seed, generate a new one for this iteration
    current_job_seed=$(date +%s)
  fi
  echo "  🌱 For QPS=$QPS (infinite), using SEED=$current_job_seed"

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
        - name: SEED
          value: "${current_job_seed}"
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

echo "Cleaning up Job ${JOB_NAME}..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found
fi

echo "✅ All benchmarks complete. Combined results in ./$RESULT_FILENAME"
