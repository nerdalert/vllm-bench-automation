#!/bin/bash
set -e
set -o pipefail

# --- Script Description ---
# This script automates the provisioning, benchmarking, and cleanup of LLM deployments
# using Minikube and specified llm-d scripts.
# It iterates through a list of deployment configurations, running benchmarks for each.
# Certain core settings are hardcoded for simplicity, while others remain configurable.
# It includes optional flags to modify deployment YAMLs.

# --- Global Variables for Parsed Arguments ---
ENABLE_4XGPU_MINIKUBE_MODS=false
CLI_MODEL_ID=""
SKIP_MINIKUBE_SETUP=false

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

This script automates the provisioning, benchmarking, and cleanup of LLM deployments.

Options:
  --4xgpu-minikube         Modify Helm override YAMLs for a 4xGPU Minikube setup (adds prefill/decode replicas and nodeSelectors).
  -m, --model MODEL_ID   Replace modelArtifactURI (hf://MODEL_ID) and modelName in override YAMLs.
  --skip-minikube-setup      Skip Minikube delete/start; instead, uninstall existing llm-d components from current Minikube.
  -h, --help               Show this help message and exit.
EOF
}

die() {
  echo "Error: $1" >&2
  print_help
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
        --4xgpu-minikube) ENABLE_4XGPU_MINIKUBE_MODS=true; shift ;;
        -m|--model)       CLI_MODEL_ID="$2"; shift 2 ;;
        --skip-minikube-setup) SKIP_MINIKUBE_SETUP=true; shift ;;
        -h|--help)        print_help; exit 0 ;;
        *)                die "Unknown option: $1" ;;
    esac
done
}

parse_args "$@"

echo "🌟 LLM Deployment and Benchmark Orchestrator 🌟"
echo "-------------------------------------------------"

# --- Fixed Vars ---
MINIKUBE_START_COMMAND_ARGS="--driver docker --container-runtime docker --gpus all --memory no-limit --cpus no-limit"
LLMD_INSTALLER_SCRIPT_PATH="./llmd-installer.sh"
TEST_REQUEST_SCRIPT_PATH="./test-request.sh"
RUN_BENCH_SCRIPT_PATH="./run-bench.sh"
FIXED_TEST_REQUEST_ARGS="--minikube"
FIXED_TEST_REQUEST_RETRY_INTERVAL_SECONDS="30"

# --- Configurable Settings (with defaults, overridable by ENV) ---

# LLMD Installer operational settings
_DEFAULT_LLMD_INSTALL_BASE_ARGS="--minikube" # Common for install/uninstall
_DEFAULT_LLMD_INSTALL_DISABLE_METRICS="true"
LLMD_INSTALL_BASE_ARGS="${ENV_LLMD_INSTALL_BASE_ARGS:-$_DEFAULT_LLMD_INSTALL_BASE_ARGS}"
LLMD_INSTALL_DISABLE_METRICS_FLAG="${ENV_LLMD_INSTALL_DISABLE_METRICS:-$_DEFAULT_LLMD_INSTALL_DISABLE_METRICS}"
LLMD_INSTALL_EXTRA_ARGS_INSTALL=""
if [[ "$LLMD_INSTALL_DISABLE_METRICS_FLAG" == "true" ]]; then
    LLMD_INSTALL_EXTRA_ARGS_INSTALL="--disable-metrics-collection"
fi
LLMD_INSTALLER_EXTRA_ARGS="${ENV_LLMD_INSTALLER_EXTRA_ARGS:-}" # Applied to both install and uninstall commands

# Run Benchmark settings (global parts)
_DEFAULT_METADATA_GPU="1xNVIDIA_L4" # Consistent GPU reported in metadata for all runs in this script execution
_DEFAULT_METADATA_BENCH_GATEWAY="kgateway"
_DEFAULT_BENCH_BASE_URL="http://llm-d-inference-gateway.llm-d.svc.cluster.local:80"
#_DEFAULT_BENCH_BASE_URL="http://llm-d-inference-gateway-istio.llm-d.svc.cluster.local:80"
_DEFAULT_BENCH_DATASET_NAME="random"
_DEFAULT_BENCH_INPUT_LEN="1000"
_DEFAULT_BENCH_OUTPUT_LEN="500"
_DEFAULT_BENCH_REQUEST_RATES="30,40,inf" # Comma-separated string
_DEFAULT_BENCH_RESULT_FILE="results.json" # Single result file, assuming run-bench.sh appends

METADATA_GPU="${ENV_METADATA_GPU:-$_DEFAULT_METADATA_GPU}"
METADATA_BENCH_GATEWAY="${ENV_METADATA_BENCH_GATEWAY:-$_DEFAULT_METADATA_BENCH_GATEWAY}"
BENCH_BASE_URL="${ENV_BENCH_BASE_URL:-$_DEFAULT_BENCH_BASE_URL}"
BENCH_DATASET_NAME="${ENV_BENCH_DATASET_NAME:-$_DEFAULT_BENCH_DATASET_NAME}"
BENCH_INPUT_LEN="${ENV_BENCH_INPUT_LEN:-$_DEFAULT_BENCH_INPUT_LEN}"
BENCH_OUTPUT_LEN="${ENV_BENCH_OUTPUT_LEN:-$_DEFAULT_BENCH_OUTPUT_LEN}"
BENCH_REQUEST_RATES="${ENV_BENCH_REQUEST_RATES:-$_DEFAULT_BENCH_REQUEST_RATES}"
BENCH_RESULT_FILE="${ENV_BENCH_RESULT_FILE:-$_DEFAULT_BENCH_RESULT_FILE}"
RUN_BENCH_EXTRA_ARGS="${ENV_RUN_BENCH_EXTRA_ARGS:-}" # Extra static args for run-bench.sh

_DEFAULT_MINIKUBE_POST_START_SLEEP_SECONDS="10"
MINIKUBE_POST_START_SLEEP_SECONDS="${ENV_MINIKUBE_POST_START_SLEEP_SECONDS:-$_DEFAULT_MINIKUBE_POST_START_SLEEP_SECONDS}"

# Deployment Configurations (User can add/edit these lists in the script)
# These are paths relative to the script or absolute paths.
_DEFAULT_DEPLOYMENT_VALUES_FILES=(
    "examples/no-features/no-features.yaml"
    "examples/base/base.yaml"
    "examples/kvcache/kvcache.yaml"
    # "examples/pd-nixl/pd-nixl.yaml"
    # "examples/all-features/all-features.yaml"
)

# Environment Variable Overrides for Deployment Lists
if [ -n "$ENV_DEPLOYMENT_VALUES_FILES" ]; then
    IFS=' ' read -r -a DEPLOYMENT_VALUES_FILES <<< "$ENV_DEPLOYMENT_VALUES_FILES"
else
    DEPLOYMENT_VALUES_FILES=("${_DEFAULT_DEPLOYMENT_VALUES_FILES[@]}")
fi

if [ ${#DEPLOYMENT_VALUES_FILES[@]} -eq 0 ]; then
    echo "ℹ️ No deployments configured in DEPLOYMENT_VALUES_FILES. Exiting."
    exit 0
fi

# --- YAML Modification Functions ---
modify_deployment_yamls_for_4xgpu() {
    if ! command -v yq &> /dev/null; then
        echo "❌ ERROR: yq is not installed. Please install yq to use the --4xgpu-minikube feature." >&2
        echo "ℹ️ See: https://github.com/mikefarah/yq#install" >&2
        exit 1
    fi

    echo "🛠️ Applying --4xgpu-minikube modifications to YAML files..."

    for yaml_file in "${DEPLOYMENT_VALUES_FILES[@]}"; do
        if [ ! -f "$yaml_file" ]; then
            echo "⚠️ WARNING: YAML file not found: $yaml_file. Skipping --4xgpu-minikube modification."
            continue
        fi
        echo "Processing $yaml_file for --4xgpu-minikube potential modification..."

        # Default values
        local prefill_replicas=0
        local decode_replicas=4
        local node_selector_key="kubernetes.io/hostname"
        local node_selector_value="minikube"

        # Check for "nixl" in the file content
        if grep -q 'nixl' "$yaml_file"; then
            echo "  Found 'nixl' in $yaml_file. Applying nixl-specific replica counts."
            prefill_replicas=2
            decode_replicas=2
        else
            echo "  Using default replica counts for $yaml_file."
        fi

        # Use yq to update/add the prefill and decode sections
        # CORRECTED PATHS for nodeSelector
        yq eval -i "
            .sampleApplication.prefill.replicas = ${prefill_replicas} |
            .modelservice.prefill.nodeSelector.\"${node_selector_key}\" = \"${node_selector_value}\" |
            .sampleApplication.decode.replicas = ${decode_replicas} |
            .modelservice.decode.nodeSelector.\"${node_selector_key}\" = \"${node_selector_value}\"
        " "$yaml_file"

        if [ $? -eq 0 ]; then
            echo "  Successfully updated replicas and nodeSelectors in $yaml_file."
        else
            echo "❌ ERROR: Failed to update replicas and nodeSelectors in $yaml_file with yq." >&2
        fi
    done
    echo "🛠️ --4xgpu-minikube modifications complete."
    echo "-------------------------------------"
}

modify_yamls_for_model_override() {
    if [ -z "$CLI_MODEL_ID" ]; then
        echo "ℹ️ No model ID provided via --model flag, skipping model override."
        return
    fi

    if ! command -v yq &> /dev/null; then
        echo "❌ ERROR: yq is not installed. Please install yq to use the --model feature." >&2
        echo "ℹ️ See: https://github.com/mikefarah/yq#install" >&2
        exit 1
    fi

    echo "🛠️ Applying --model '${CLI_MODEL_ID}' modifications to YAML files..."
    local model_artifact_uri="hf://${CLI_MODEL_ID}" # Construct the URI

    for yaml_file in "${DEPLOYMENT_VALUES_FILES[@]}"; do
        if [ ! -f "$yaml_file" ]; then
            echo "⚠️ WARNING: YAML file not found: $yaml_file. Skipping model override for this file."
            continue
        fi

        echo "  Processing $yaml_file for model override..."

        yq eval -i "
            .sampleApplication.model.modelArtifactURI = \"${model_artifact_uri}\" |
            .sampleApplication.model.modelName = \"${CLI_MODEL_ID}\"
        " "$yaml_file"

        if [ $? -eq 0 ]; then
            echo "    Successfully updated model in $yaml_file."
        else
            echo "❌ ERROR: Failed to update model in $yaml_file with yq." >&2
        fi
    done
    echo "🛠️ Model override modifications complete."
    echo "-------------------------------------"
}


echo "--- Configuration Summary ---"
echo "Minikube Start Args (Hardcoded): ${MINIKUBE_START_COMMAND_ARGS}"
echo "LLMD Installer Script (Hardcoded): ${LLMD_INSTALLER_SCRIPT_PATH}"
echo "Test Request Script (Hardcoded): ${TEST_REQUEST_SCRIPT_PATH} (Args: ${FIXED_TEST_REQUEST_ARGS}, Retry: ${FIXED_TEST_REQUEST_RETRY_INTERVAL_SECONDS}s)"
echo "Run Bench Script (Hardcoded): ${RUN_BENCH_SCRIPT_PATH}"
echo ""
echo "Benchmark model for metadata will be derived from the --model flag or dynamically from each values file."
echo "Benchmark Metadata GPU (Configurable, consistent for all runs): ${METADATA_GPU}"
echo "Benchmark Metadata Gateway (Configurable): ${METADATA_BENCH_GATEWAY}"
echo "Result File (Configurable): ${BENCH_RESULT_FILE}"
if [ "$SKIP_MINIKUBE_SETUP" = true ]; then
    echo "Minikube Setup: SKIPPED (llm-d components will be uninstalled from existing Minikube if present)"
fi
if [ "$ENABLE_4XGPU_MINIKUBE_MODS" = true ]; then
    echo "YAML Modifications for --4xgpu-minikube: ENABLED"
fi
if [ -n "$CLI_MODEL_ID" ]; then
    echo "YAML Model Override (from --model flag): ENABLED (Model: ${CLI_MODEL_ID})"
fi
echo "Deployments to process: ${#DEPLOYMENT_VALUES_FILES[@]}"
for i in "${!DEPLOYMENT_VALUES_FILES[@]}"; do
    echo "  - Values: ${DEPLOYMENT_VALUES_FILES[i]}"
done
echo "-----------------------------"

log_and_run() {
    echo "🚀 EXEC: $@"
    local cmd_to_run=("$@")
    "${cmd_to_run[@]}"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "❌ ERROR: Command failed with exit code $exit_code: ${cmd_to_run[*]}" >&2
    fi
    return $exit_code
}

derive_deployment_name_from_path() {
    local values_file_path="$1"
    if [[ "$values_file_path" == *"examples/"* ]]; then
        local path_after_examples="${values_file_path#*examples/}"
        local derived_name
        derived_name=$(echo "$path_after_examples" | cut -d'/' -f1)
        echo "$derived_name"
    else
        local dir_name
        dir_name=$(basename "$(dirname "$values_file_path")")
        echo "$dir_name"
    fi
}


# --- Minikube Functions ---
start_minikube_environment() {
    if [ "$SKIP_MINIKUBE_SETUP" = true ]; then
        echo "--- Skipping Minikube delete and start due to --skip-minikube-setup flag ---"
        echo "--- Attempting to uninstall existing llm-d components from current Minikube to ensure clean state ---"
        # Use LLMD_INSTALL_BASE_ARGS for consistency with other uninstall calls
        # shellcheck disable=SC2086 # We want word splitting for these arg variables
        log_and_run "${LLMD_INSTALLER_SCRIPT_PATH}" ${LLMD_INSTALL_BASE_ARGS} --uninstall ${LLMD_INSTALLER_EXTRA_ARGS}
        if [ $? -eq 0 ]; then
            echo "✅ llm-d uninstall command sent successfully."
        else
            echo "⚠️ llm-d uninstall command failed. Proceeding, but stale components might exist."
        fi
        echo "Minikube setup skipped; llm-d uninstall attempted."
        echo "-------------------------"
    else
    echo "--- Minikube Setup ---"
    echo "Attempting to delete any existing Minikube instance if one exists..."
    ./llmd-installer.sh --uninstall -minikube > /dev/null 2>&1 || true
    minikube delete > /dev/null 2>&1 || echo "No existing Minikube instance to delete, or an error occurred (ignored)."

    echo "Starting Minikube with: ${MINIKUBE_START_COMMAND_ARGS}"
    # shellcheck disable=SC2086 # We want word splitting for MINIKUBE_START_COMMAND_ARGS
    log_and_run minikube start ${MINIKUBE_START_COMMAND_ARGS}

    echo "Minikube started. Waiting for ${MINIKUBE_POST_START_SLEEP_SECONDS} seconds for stabilization..."
    sleep "${MINIKUBE_POST_START_SLEEP_SECONDS}"
    echo "Minikube setup complete."3
    echo "-------------------------"
    fi
}

# --- LLM-D Deployment Functions ---
install_llm_deployment() {
    local values_file="$1"
    local deployment_name_log
    deployment_name_log=$(derive_deployment_name_from_path "$values_file")
    echo "--- Installing LLM Deployment: ${deployment_name_log} (using ${values_file}) ---"
    # shellcheck disable=SC2086
    log_and_run "${LLMD_INSTALLER_SCRIPT_PATH}" ${LLMD_INSTALL_BASE_ARGS} --values-file "$values_file" ${LLMD_INSTALL_EXTRA_ARGS_INSTALL} ${LLMD_INSTALLER_EXTRA_ARGS}
    echo "Installation command for ${deployment_name_log} sent."
    echo "------------------------------------------"
}

wait_for_deployment_ready() {
    local deployment_name_log="$1"
    local MAX_WAIT_ATTEMPTS=60 # 60 attempts * 30 seconds = 30 minutes timeout

    echo "--- Waiting for vLLM instance for deployment '${deployment_name_log}' to initialize ---"
    echo "ℹ️ This step can take some time, as it may involve downloading large model files and then initializing the vLLM engine."
    local attempt=1

    # Loop while the test request script fails. Output of test script is suppressed.
    # shellcheck disable=SC2086 # We want word splitting for FIXED_TEST_REQUEST_ARGS
    while ! ("${TEST_REQUEST_SCRIPT_PATH}" ${FIXED_TEST_REQUEST_ARGS} > /dev/null 2>&1); do
        if [ "${attempt}" -ge "${MAX_WAIT_ATTEMPTS}" ]; then # Use -ge (greater than or equal to) for safety
            echo "❌ ERROR: Timeout reached after ${attempt} attempts (approx. $((attempt * FIXED_TEST_REQUEST_RETRY_INTERVAL_SECONDS / 60)) minutes) waiting for '${deployment_name_log}'." >&2
            echo "ℹ️ Please check the pod logs for '${deployment_name_log}' (or the llm-d controller/operator logs) for issues with initialization." >&2
            exit 1 # Exit script with error code 1
        fi

        echo "Attempt ${attempt}/${MAX_WAIT_ATTEMPTS}: Waiting for '${deployment_name_log}' to be ready. Retrying in ${FIXED_TEST_REQUEST_RETRY_INTERVAL_SECONDS} seconds..."
        sleep "${FIXED_TEST_REQUEST_RETRY_INTERVAL_SECONDS}"
        attempt=$((attempt + 1))
    done
    echo "✅ vLLM instance for deployment '${deployment_name_log}' is ready!"
    echo "-------------------------------------------------"
}

run_benchmark_for_deployment() {
    local deployment_name="$1"
    local current_values_file="$2" # Path to the current values.yaml
    local benchmark_model_to_report=""
    local meta_prefill_replicas="N/A" # Default placeholder if not found/readable
    local meta_decode_replicas="N/A"  # Default placeholder if not found/readable

    # --- Determine Model for Benchmark Metadata ---
    if [ -n "$CLI_MODEL_ID" ]; then
        benchmark_model_to_report="$CLI_MODEL_ID"
    else
        # Try to read model name from the current YAML file if --model flag not used
        if ! command -v yq &> /dev/null; then
            echo "❌ ERROR: yq is not installed. Cannot read model name from YAML for benchmark metadata." >&2
            echo "         Please install yq (see https://github.com/mikefarah/yq#install) or use the --model flag." >&2
            benchmark_model_to_report="<MODEL_READ_ERROR_YQ_MISSING>"
        elif [ -f "$current_values_file" ]; then
            local model_from_yaml
            model_from_yaml=$(yq eval '.sampleApplication.model.modelName' "$current_values_file" 2>/dev/null)
            if [ -n "$model_from_yaml" ] && [ "$model_from_yaml" != "null" ]; then
                benchmark_model_to_report="$model_from_yaml"
            else
                echo "⚠️ WARNING: Could not read '.sampleApplication.model.modelName' from '$current_values_file' or it was empty/null." >&2
                benchmark_model_to_report="<MODEL_NOT_IN_YAML_OR_EMPTY>"
            fi
        else
            echo "⚠️ WARNING: Values file '$current_values_file' not found. Cannot determine model for benchmark." >&2
            benchmark_model_to_report="<MODEL_VALUES_FILE_NOT_FOUND>"
        fi
    fi

    # Ensure benchmark_model_to_report is not empty if run-bench.sh requires it
    if [ -z "$benchmark_model_to_report" ]; then
        benchmark_model_to_report="<UNKNOWN_MODEL_ERROR>" # Should be caught by placeholders above usually
    fi

    # --- Determine Prefill and Decode Replica Counts for Metadata ---
    # These are read from the current_values_file, which reflects any modifications
    # made by --minikube flag earlier in the script.
    if command -v yq &> /dev/null; then
        if [ -f "$current_values_file" ]; then
            local temp_prefill
            temp_prefill=$(yq eval '.sampleApplication.prefill.replicas' "$current_values_file" 2>/dev/null)
            if [ -n "$temp_prefill" ] && [ "$temp_prefill" != "null" ]; then
                meta_prefill_replicas="$temp_prefill"
            else
                echo "⚠️ WARNING: Could not read '.sampleApplication.prefill.replicas' from '$current_values_file'." >&2
            fi

            local temp_decode
            temp_decode=$(yq eval '.sampleApplication.decode.replicas' "$current_values_file" 2>/dev/null)
            if [ -n "$temp_decode" ] && [ "$temp_decode" != "null" ]; then
                meta_decode_replicas="$temp_decode"
            else
                echo "⚠️ WARNING: Could not read '.sampleApplication.decode.replicas' from '$current_values_file'." >&2
            fi
        else
            if [[ "$benchmark_model_to_report" != *"_FILE_NOT_FOUND>"* && "$benchmark_model_to_report" != *"_YQ_MISSING>"* ]]; then
                echo "⚠️ WARNING: Values file '$current_values_file' not found when attempting to read replica counts." >&2
            fi
            meta_prefill_replicas="<FILE_NOT_FOUND>"
            meta_decode_replicas="<FILE_NOT_FOUND>"
        fi
    else
        if [ -n "$CLI_MODEL_ID" ]; then
             echo "❌ ERROR: yq is not installed. Cannot read replica counts from YAML for benchmark metadata." >&2
        fi
        meta_prefill_replicas="<REPLICAS_YQ_MISSING>"
        meta_decode_replicas="<REPLICAS_YQ_MISSING>"
    fi

    # Construct the metadata string
    local metadata_string="deployment=${deployment_name} gpu=${METADATA_GPU} model=${benchmark_model_to_report} gateway=${METADATA_BENCH_GATEWAY} prefill_replicas=${meta_prefill_replicas} decode_replicas=${meta_decode_replicas} input_len=${BENCH_INPUT_LEN} output_len=${BENCH_OUTPUT_LEN}"

    echo "--- Running Benchmark for: ${deployment_name} (Model: ${benchmark_model_to_report}, Prefill: ${meta_prefill_replicas}, Decode: ${meta_decode_replicas}, Input: ${BENCH_INPUT_LEN}, Output: ${BENCH_OUTPUT_LEN}) ---"
    echo "Metadata: ${metadata_string}"
    echo "Result File: ${BENCH_RESULT_FILE}"

    # The following command will run the benchmark.
    # shellcheck disable=SC2086 # Need word splitting for RUN_BENCH_EXTRA_ARGS
    log_and_run "${RUN_BENCH_SCRIPT_PATH}" \
        --model "$benchmark_model_to_report" \
        --base_url "$BENCH_BASE_URL" \
        --dataset-name "$BENCH_DATASET_NAME" \
        --input-len "$BENCH_INPUT_LEN" \
        --output-len "$BENCH_OUTPUT_LEN" \
        --request-rates "$BENCH_REQUEST_RATES" \
        --metadata "$metadata_string" \
        --result-file "$BENCH_RESULT_FILE" \
        ${RUN_BENCH_EXTRA_ARGS}
    echo "Benchmark for ${deployment_name} completed."
    echo "-----------------------------------------"
}

uninstall_llm_deployment() {
    local deployment_name_log="$1"
    echo "--- Uninstalling LLM Deployment: ${deployment_name_log} ---"
    # Use LLMD_INSTALL_BASE_ARGS for consistency with other uninstall calls
    # shellcheck disable=SC2086 # We want word splitting for these arg variables
    log_and_run "${LLMD_INSTALLER_SCRIPT_PATH}" ${LLMD_INSTALL_BASE_ARGS} --uninstall ${LLMD_INSTALLER_EXTRA_ARGS}
    echo "Uninstallation for ${deployment_name_log} completed."
    echo "---------------------------------------------"
}

# --- Main Control Flow ---
main() {
    local script_start_time
    script_start_time=$(date +%s)

    # Apply YAML modifications if flags are set
    if [ "$ENABLE_4XGPU_MINIKUBE_MODS" = true ]; then
        modify_deployment_yamls_for_4xgpu
    fi

    if [ -n "$CLI_MODEL_ID" ]; then
        modify_yamls_for_model_override
    fi

    echo "========= Starting Full Deployment and Benchmark Process ========="

    start_minikube_environment

    for i in "${!DEPLOYMENT_VALUES_FILES[@]}"; do
        current_values_file="${DEPLOYMENT_VALUES_FILES[i]}"
        derived_name_for_run=$(derive_deployment_name_from_path "$current_values_file")

        echo ""
        echo "Processing Deployment $((i + 1))/${#DEPLOYMENT_VALUES_FILES[@]}: ${derived_name_for_run}"
        echo "================================================================="

        install_llm_deployment "$current_values_file"
        wait_for_deployment_ready "$derived_name_for_run"
        run_benchmark_for_deployment "$derived_name_for_run" "$current_values_file" # Corrected call
        uninstall_llm_deployment "$derived_name_for_run"

        echo "Completed cycle for ${derived_name_for_run}."
        echo "================================================================="
        if [ $i -lt $((${#DEPLOYMENT_VALUES_FILES[@]} - 1)) ]; then
            echo "Pausing for a few seconds before next deployment..."
            sleep 5
        fi
    done

    echo ""
    echo "🎉 All configured deployments processed."
    echo "========= Full Deployment and Benchmark Process Finished ========="

    local script_end_time
    local total_seconds_duration
    local minutes_duration
    local seconds_part

    script_end_time=$(date +%s)
    total_seconds_duration=$((script_end_time - script_start_time))

    minutes_duration=$((total_seconds_duration / 60))
    seconds_part=$((total_seconds_duration % 60))

    echo ""
    echo "-----------------------------------------------------------------"
    echo "Total script execution time: ${minutes_duration}m ${seconds_part}s (Total: ${total_seconds_duration} seconds)"
    echo "-----------------------------------------------------------------"
}

# --- Main ---
main

exit 0
