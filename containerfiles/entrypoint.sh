#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${HF_TOKEN:-}" ]]; then
  export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
  echo "Using HF_TOKEN as HUGGINGFACE_HUB_TOKEN"
else
  echo "HF_TOKEN not set; downloads may fail" >&2
fi

cd /opt/benchmark
source venv-vllm-src/bin/activate

echo "Starting benchmark at $(date)"
echo "----- ENV VARS -----"
for v in BASE_URL MODEL DATASET_NAME RANDOM_INPUT_LEN RANDOM_OUTPUT_LEN REQUEST_RATE NUM_PROMPTS IGNORE_EOS RESULT_FILENAME METADATA MAX_CONCURRENCY; do
  printf "  %s=%s\n" "$v" "${!v:-<unset>}"
done
echo "--------------------"

CMD=(python /opt/benchmark/vllm/benchmarks/benchmark_serving.py
     --base_url "$BASE_URL"
     --model "$MODEL"
     --dataset-name "${DATASET_NAME:-random}"
     --random-input-len "${RANDOM_INPUT_LEN:-5000}"
     --random-output-len "${RANDOM_OUTPUT_LEN:-2000}"
     --request-rate "${REQUEST_RATE:-8}"
     --num-prompts "${NUM_PROMPTS:-200}"
)

# optional
$([[ "${IGNORE_EOS:-false}" == "true" ]] && CMD+=(--ignore-eos))

# optional max-concurrency
if [[ -n "${MAX_CONCURRENCY:-}" ]]; then
  CMD+=(--max-concurrency "${MAX_CONCURRENCY}")
fi

# ── Save−result to CWD/results.json ───────────────────────────────────
CMD+=(--save-result)
CMD+=(--result-filename "${RESULT_FILENAME:-results.json}")

# ── Always include metadata flag ─────────────────────────────────────────────
CMD+=(--metadata)
for kv in ${METADATA:-}; do
  CMD+=("$kv")
done

echo "Running: ${CMD[*]}"
"${CMD[@]}"

# Cat the JSON back out with markers for results log copies
OUT="${RESULT_FILENAME:-results.json}"
echo "<<<RESULT_START>>>"
cat "$OUT"
echo
echo "<<<RESULT_END>>>"
