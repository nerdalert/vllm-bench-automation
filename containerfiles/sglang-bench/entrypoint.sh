#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

export HF_HOME="/tmp/huggingface_cache"
mkdir -p "${HF_HOME}"

cd /opt/benchmark/sglang
source venv/bin/activate

echo "Starting SGLang benchmark at $(date)"
echo "----- ENV VARS -----"
for v in BACKEND HOST PORT BASE_URL DATASET_NAME DATASET_PATH MODEL TOKENIZER \
         NUM_PROMPTS SHAREGPT_OUTPUT_LEN SHAREGPT_CONTEXT_LEN \
         RANDOM_INPUT_LEN RANDOM_OUTPUT_LEN RANDOM_RANGE_RATIO REQUEST_RATE \
         MAX_CONCURRENCY OUTPUT_DETAILS DISABLE_TQDM DISABLE_STREAM \
         RETURN_LOGPROB SEED DISABLE_IGNORE_EOS EXTRA_REQUEST_BODY \
         APPLY_CHAT_TEMPLATE LORA_NAME PROMPT_SUFFIX PD_SEPARATED \
         FLUSH_CACHE WARMUP_REQUESTS GSP_NUM_GROUPS \
         GSP_PROMPTS_PER_GROUP GSP_SYSTEM_PROMPT_LEN \
         GSP_QUESTION_LEN GSP_OUTPUT_LEN OUTPUT_FILE; do
  printf "  %s=%s\n" "$v" "${!v:-<unset>}"
done
echo "--------------------"

# result path
OUT="${OUTPUT_FILE:-results.jsonl}"

# Build benchmark command
CMD=(python3 -m sglang.bench_serving
     --backend "${BACKEND:-sglang}"
)

[[ -n "${HOST:-}" ]]     && CMD+=(--host "$HOST")
[[ -n "${PORT:-}" ]]     && CMD+=(--port "$PORT")
[[ -n "${BASE_URL:-}" ]] && CMD+=(--base-url "$BASE_URL")

[[ -n "${DATASET_NAME:-}" ]] && CMD+=(--dataset-name "$DATASET_NAME")
[[ -n "${DATASET_PATH:-}" ]] && CMD+=(--dataset-path "$DATASET_PATH")
[[ -n "${MODEL:-}" ]]        && CMD+=(--model "$MODEL")
[[ -n "${TOKENIZER:-}" ]]    && CMD+=(--tokenizer "$TOKENIZER")

[[ -n "${NUM_PROMPTS:-}" ]]          && CMD+=(--num-prompts "$NUM_PROMPTS")
[[ -n "${SHAREGPT_OUTPUT_LEN:-}" ]]  && CMD+=(--sharegpt-output-len "$SHAREGPT_OUTPUT_LEN")
[[ -n "${SHAREGPT_CONTEXT_LEN:-}" ]] && CMD+=(--sharegpt-context-len "$SHAREGPT_CONTEXT_LEN")
[[ -n "${RANDOM_INPUT_LEN:-}" ]]     && CMD+=(--random-input-len "$RANDOM_INPUT_LEN")
[[ -n "${RANDOM_OUTPUT_LEN:-}" ]]    && CMD+=(--random-output-len "$RANDOM_OUTPUT_LEN")
[[ -n "${RANDOM_RANGE_RATIO:-}" ]]   && CMD+=(--random-range-ratio "$RANDOM_RANGE_RATIO")
[[ -n "${REQUEST_RATE:-}" ]]         && CMD+=(--request-rate "$REQUEST_RATE")
[[ -n "${MAX_CONCURRENCY:-}" ]]      && CMD+=(--max-concurrency "$MAX_CONCURRENCY")
[[ "${OUTPUT_DETAILS:-false}" == "true" ]]   && CMD+=(--output-details)
[[ "${DISABLE_TQDM:-false}" == "true" ]]     && CMD+=(--disable-tqdm)
[[ "${DISABLE_STREAM:-false}" == "true" ]]   && CMD+=(--disable-stream)
[[ "${RETURN_LOGPROB:-false}" == "true" ]]   && CMD+=(--return-logprob)
[[ -n "${SEED:-}" ]]                       && CMD+=(--seed "$SEED")
[[ "${DISABLE_IGNORE_EOS:-false}" == "true" ]] && CMD+=(--disable-ignore-eos)
[[ -n "${EXTRA_REQUEST_BODY:-}" ]]         && CMD+=(--extra-request-body "$EXTRA_REQUEST_BODY")
[[ "${APPLY_CHAT_TEMPLATE:-false}" == "true" ]] && CMD+=(--apply-chat-template)
[[ -n "${LORA_NAME:-}" ]]                  && CMD+=(--lora-name $LORA_NAME)
[[ -n "${PROMPT_SUFFIX:-}" ]]              && CMD+=(--prompt-suffix "$PROMPT_SUFFIX")
[[ "${PD_SEPARATED:-false}" == "true" ]]   && CMD+=(--pd-separated)
[[ "${FLUSH_CACHE:-false}" == "true" ]]    && CMD+=(--flush-cache)
[[ -n "${WARMUP_REQUESTS:-}" ]]            && CMD+=(--warmup-requests "$WARMUP_REQUESTS")

# generated-shared-prefix specifics
[[ -n "${GSP_NUM_GROUPS:-}" ]]        && CMD+=(--gsp-num-groups "$GSP_NUM_GROUPS")
[[ -n "${GSP_PROMPTS_PER_GROUP:-}" ]] && CMD+=(--gsp-prompts-per-group "$GSP_PROMPTS_PER_GROUP")
[[ -n "${GSP_SYSTEM_PROMPT_LEN:-}" ]] && CMD+=(--gsp-system-prompt-len "$GSP_SYSTEM_PROMPT_LEN")
[[ -n "${GSP_QUESTION_LEN:-}" ]]      && CMD+=(--gsp-question-len "$GSP_QUESTION_LEN")
[[ -n "${GSP_OUTPUT_LEN:-}" ]]        && CMD+=(--gsp-output-len "$GSP_OUTPUT_LEN")

CMD+=(--output-file "$OUT")

echo "Running: ${CMD[*]}"
"${CMD[@]}"

# Wrap result with delimiters
echo "<<<RESULT_START>>>"
cat "$OUT"
echo
echo "<<<RESULT_END>>>"
