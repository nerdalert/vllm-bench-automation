# vllm-bench-automation

- This benchmark using [benchmark_serving](https://github.com/vllm-project/vllm/blob/main/benchmarks/benchmark_serving.py) via vLLM. That is containerized in this [Containerfile](./containerfiles/).

- For minikube see this [readme](README-minikube.md). It wraps up `[e2e-bench-control.sh](https://github.com/nerdalert/vllm-bench-automation/blob/main/e2e-bench-control.sh)` and will run multiple deployments in one shot (no-features, base, kvcache, etc) and then run `./run-bench.sh` on the current deployment. Will be updating to decouple from minikube.

- Copy these files into the quickstart directory. Modify the deployments in `quickstart/examples` to fit your env, (e.g. vllm args and decode replica counts).

## Deploy

After deploying, wait for the decode pods to finish loading. You can test readiness with the `test-request.sh` script in the quickstart directory.

```bash
git clone https://github.com/llm-d/llm-d-deployer.git
cd quickstart
# no features
./llmd-installer.sh --values-file examples/no-features/slim/no-features-slim.yaml
# Run benchmark ./run-bench.sh then uninstall
./llmd-installer.sh --uninstall
# base (prefix scoring)
./llmd-installer.sh --values-file examples/base/base.yaml
# Run benchmark ./run-bench.sh then uninstall
./llmd-installer.sh --uninstall
# kvcache (kvcache aware scoring)
./llmd-installer.sh --values-file examples/kvcache/kvcache.yaml
# Run benchmark ./run-bench.sh then uninstall
```

The script [e2e-control.sh](https://github.com/nerdalert/vllm-bench-automation/blob/main/e2e-bench-control.sh) automates all of those steps but is currently minikube only until updated.

## Run Bench

This spins up a job with the packaged vllm `[benchmark_serve.py](https://github.com/nerdalert/vllm-bench-automation/tree/main/containerfiles)` [ghcr.io/nerdalert/vllm-bench:latest](https://github.com/users/nerdalert/packages/container/package/vllm-bench) with the arguments passed via the run script. Swap out the metadata to match the scenario you are running for graphing results in [vllm-benchmark-graphs](./vllm-benchmark-graphs/).

Example run:

```bash
./run-bench.sh --model meta-llama/Llama-3.2-3B-Instruct \
  --base_url http://llm-d-inference-gateway.llm-d.svc.cluster.local:80 \
  --dataset-name random \
  --input-len 1000 \
  --output-len 500 \
  --request-rates 10,30,inf \
  --metadata "deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500" \
  --result-file results.json
```

### Example Output

```
$ ./run-bench.sh --model meta-llama/Llama-3.2-3B-Instruct \
  --base_url http://llm-d-inference-gateway.llm-d.svc.cluster.local:80 \
  --dataset-name random \
  --input-len 1000 \
  --output-len 500 \
  --request-rates 10,30,inf \
  --metadata "deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500" \
  --result-file results.json
secret/hf-token-secret created
▶️  Benchmarking MODEL=meta-llama/Llama-3.2-3B-Instruct at rates: 10 30 inf QPS for 30 seconds each
🔖 Results will go into ./results.json
🚀 Launching vllm-bench-job-10qps (QPS=10, prompts=300)…
job.batch/vllm-bench-job-10qps created
job.batch/vllm-bench-job-10qps condition met
📖 Logs from vllm-bench-job-10qps:
Using HF_TOKEN as HUGGINGFACE_HUB_TOKEN
Starting benchmark at Fri May 30 20:37:06 UTC 2025
----- ENV VARS -----
  BASE_URL=http://llm-d-inference-gateway.llm-d.svc.cluster.local:80
  MODEL=meta-llama/Llama-3.2-3B-Instruct
  DATASET_NAME=random
  RANDOM_INPUT_LEN=1000
  RANDOM_OUTPUT_LEN=500
  REQUEST_RATE=10
  NUM_PROMPTS=300
  IGNORE_EOS=true
  RESULT_FILENAME=results.json
  METADATA=deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
--------------------
Running: python /opt/benchmark/vllm/benchmarks/benchmark_serving.py --base_url http://llm-d-inference-gateway.llm-d.svc.cluster.local:80 --model meta-llama/Llama-3.2-3B-Instruct --dataset-name random --random-input-len 1000 --random-output-len 500 --request-rate 10 --num-prompts 300 --save-result --result-filename results.json --metadata deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin tpu function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin cuda function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin rocm function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin hpu function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin xpu function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin cpu function's return value is None
WARNING 05-30 20:37:15 [__init__.py:221] Platform plugin neuron function's return value is None
INFO 05-30 20:37:15 [__init__.py:250] No platform detected, vLLM is running on UnspecifiedPlatform
WARNING 05-30 20:37:17 [_custom_ops.py:21] Failed to import from vllm._C with ImportError('libcuda.so.1: cannot open shared object file: No such file or directory')
Namespace(backend='vllm', base_url='http://llm-d-inference-gateway.llm-d.svc.cluster.local:80', host='127.0.0.1', port=8000, endpoint='/v1/completions', dataset_name='random', dataset_path=None, max_concurrency=None, model='meta-llama/Llama-3.2-3B-Instruct', tokenizer=None, use_beam_search=False, num_prompts=300, logprobs=None, request_rate=10.0, burstiness=1.0, seed=0, trust_remote_code=False, disable_tqdm=False, profile=False, save_result=True, save_detailed=False, append_result=False, metadata=['deployment=base', 'gpu=4xNVIDIA_L40S', 'model=meta-llama/Llama-3.2-3B-Instruct', 'gateway=kgateway', 'prefill_replicas=0', 'decode_replicas=4', 'input_len=1000', 'output_len=500'], result_dir=None, result_filename='results.json', ignore_eos=False, percentile_metrics='ttft,tpot,itl', metric_percentiles='99', goodput=None, sonnet_input_len=550, sonnet_output_len=150, sonnet_prefix_len=200, sharegpt_output_len=None, random_input_len=1000, random_output_len=500, random_range_ratio=0.0, random_prefix_len=0, hf_subset=None, hf_split=None, hf_output_len=None, top_p=None, top_k=None, min_p=None, temperature=None, tokenizer_mode='auto', served_model_name=None, lora_modules=None)
Starting initial single prompt test run...
Initial test run completed. Starting main benchmark run...
Traffic request rate: 10.0
Burstiness factor: 1.0 (Poisson process)
Maximum request concurrency: None
100%|██████████| 300/300 [00:36<00:00,  8.33it/s]
============ Serving Benchmark Result ============
Successful requests:                     300
Benchmark duration (s):                  36.03
Total input tokens:                      299700
Total generated tokens:                  81050
Request throughput (req/s):              8.33
Output token throughput (tok/s):         2249.25
Total Token throughput (tok/s):          10566.33
---------------Time to First Token----------------
Mean TTFT (ms):                          54.58
Median TTFT (ms):                        53.00
P99 TTFT (ms):                           89.77
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          13.58
Median TPOT (ms):                        13.51
P99 TPOT (ms):                           17.65
---------------Inter-token Latency----------------
Mean ITL (ms):                           13.51
Median ITL (ms):                         12.84
P99 ITL (ms):                            34.21
==================================================
<<<RESULT_START>>>
{"date": "20250530-203806", "backend": "vllm", "model_id": "meta-llama/Llama-3.2-3B-Instruct", "tokenizer_id": "meta-llama/Llama-3.2-3B-Instruct", "num_prompts": 300, "deployment": "base", "gpu": "4xNVIDIA_L40S", "model": "meta-llama/Llama-3.2-3B-Instruct", "gateway": "kgateway", "prefill_replicas": "0", "decode_replicas": "4", "input_len": "1000", "output_len": "500", "request_rate": 10.0, "burstiness": 1.0, "max_concurrency": null, "duration": 36.034275877000255, "completed": 300, "total_input_tokens": 299700, "total_output_tokens": 81050, "request_throughput": 8.325406649602808, "request_goodput:": null, "output_throughput": 2249.247363167692, "total_token_throughput": 10566.328606120898, "mean_ttft_ms": 54.577085783294024, "median_ttft_ms": 52.999333499883505, "std_ttft_ms": 9.27197373989555, "p99_ttft_ms": 89.76647855975897, "mean_tpot_ms": 13.577995860227945, "median_tpot_ms": 13.512526767533997, "std_tpot_ms": 0.9199628548912276, "p99_tpot_ms": 17.652194109258673, "mean_itl_ms": 13.505887271504633, "median_itl_ms": 12.841573499827064, "std_itl_ms": 3.839438281316489, "p99_itl_ms": 34.210415409961556}
<<<RESULT_END>>>
Appended results block for 10 QPS
Cleaning up Job vllm-bench-job-10qps...
job.batch "vllm-bench-job-10qps" deleted
🚀 Launching vllm-bench-job-30qps (QPS=30, prompts=900)…
job.batch/vllm-bench-job-30qps created
job.batch/vllm-bench-job-30qps condition met
📖 Logs from vllm-bench-job-30qps:
Using HF_TOKEN as HUGGINGFACE_HUB_TOKEN
Starting benchmark at Fri May 30 20:38:10 UTC 2025
----- ENV VARS -----
  BASE_URL=http://llm-d-inference-gateway.llm-d.svc.cluster.local:80
  MODEL=meta-llama/Llama-3.2-3B-Instruct
  DATASET_NAME=random
  RANDOM_INPUT_LEN=1000
  RANDOM_OUTPUT_LEN=500
  REQUEST_RATE=30
  NUM_PROMPTS=900
  IGNORE_EOS=true
  RESULT_FILENAME=results.json
  METADATA=deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
--------------------
Running: python /opt/benchmark/vllm/benchmarks/benchmark_serving.py --base_url http://llm-d-inference-gateway.llm-d.svc.cluster.local:80 --model meta-llama/Llama-3.2-3B-Instruct --dataset-name random --random-input-len 1000 --random-output-len 500 --request-rate 30 --num-prompts 900 --save-result --result-filename results.json --metadata deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin tpu function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin cuda function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin rocm function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin hpu function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin xpu function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin cpu function's return value is None
WARNING 05-30 20:38:19 [__init__.py:221] Platform plugin neuron function's return value is None
INFO 05-30 20:38:19 [__init__.py:250] No platform detected, vLLM is running on UnspecifiedPlatform
WARNING 05-30 20:38:20 [_custom_ops.py:21] Failed to import from vllm._C with ImportError('libcuda.so.1: cannot open shared object file: No such file or directory')
Namespace(backend='vllm', base_url='http://llm-d-inference-gateway.llm-d.svc.cluster.local:80', host='127.0.0.1', port=8000, endpoint='/v1/completions', dataset_name='random', dataset_path=None, max_concurrency=None, model='meta-llama/Llama-3.2-3B-Instruct', tokenizer=None, use_beam_search=False, num_prompts=900, logprobs=None, request_rate=30.0, burstiness=1.0, seed=0, trust_remote_code=False, disable_tqdm=False, profile=False, save_result=True, save_detailed=False, append_result=False, metadata=['deployment=base', 'gpu=4xNVIDIA_L40S', 'model=meta-llama/Llama-3.2-3B-Instruct', 'gateway=kgateway', 'prefill_replicas=0', 'decode_replicas=4', 'input_len=1000', 'output_len=500'], result_dir=None, result_filename='results.json', ignore_eos=False, percentile_metrics='ttft,tpot,itl', metric_percentiles='99', goodput=None, sonnet_input_len=550, sonnet_output_len=150, sonnet_prefix_len=200, sharegpt_output_len=None, random_input_len=1000, random_output_len=500, random_range_ratio=0.0, random_prefix_len=0, hf_subset=None, hf_split=None, hf_output_len=None, top_p=None, top_k=None, min_p=None, temperature=None, tokenizer_mode='auto', served_model_name=None, lora_modules=None)
Starting initial single prompt test run...
Initial test run completed. Starting main benchmark run...
Traffic request rate: 30.0
Burstiness factor: 1.0 (Poisson process)
Maximum request concurrency: None
100%|██████████| 900/900 [00:40<00:00, 22.18it/s]
============ Serving Benchmark Result ============
Successful requests:                     900
Benchmark duration (s):                  40.57
Total input tokens:                      899100
Total generated tokens:                  239959
Request throughput (req/s):              22.18
Output token throughput (tok/s):         5914.31
Total Token throughput (tok/s):          28074.59
---------------Time to First Token----------------
Mean TTFT (ms):                          73.23
Median TTFT (ms):                        74.51
P99 TTFT (ms):                           169.39
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          23.59
Median TPOT (ms):                        24.65
P99 TPOT (ms):                           32.72
---------------Inter-token Latency----------------
Mean ITL (ms):                           23.47
Median ITL (ms):                         20.99
P99 ITL (ms):                            75.82
==================================================
<<<RESULT_START>>>
{"date": "20250530-203916", "backend": "vllm", "model_id": "meta-llama/Llama-3.2-3B-Instruct", "tokenizer_id": "meta-llama/Llama-3.2-3B-Instruct", "num_prompts": 900, "deployment": "base", "gpu": "4xNVIDIA_L40S", "model": "meta-llama/Llama-3.2-3B-Instruct", "gateway": "kgateway", "prefill_replicas": "0", "decode_replicas": "4", "input_len": "1000", "output_len": "500", "request_rate": 30.0, "burstiness": 1.0, "max_concurrency": null, "duration": 40.57259980900017, "completed": 900, "total_input_tokens": 899100, "total_output_tokens": 239959, "request_throughput": 22.182458216551215, "request_goodput:": null, "output_throughput": 5914.311656872681, "total_token_throughput": 28074.587415207345, "mean_ttft_ms": 73.22729984779572, "median_ttft_ms": 74.51430299988715, "std_ttft_ms": 33.92979932231269, "p99_ttft_ms": 169.39216242027214, "mean_tpot_ms": 23.586269942687313, "median_tpot_ms": 24.64663913131863, "std_tpot_ms": 5.4388490325372665, "p99_tpot_ms": 32.724085161084425, "mean_itl_ms": 23.466772128068868, "median_itl_ms": 20.98881700021593, "std_itl_ms": 11.048866594118087, "p99_itl_ms": 75.82270559991227}
<<<RESULT_END>>>
Appended results block for 30 QPS
Cleaning up Job vllm-bench-job-30qps...
job.batch "vllm-bench-job-30qps" deleted
🚀 Launching vllm-bench-job-inf (infinite QPS, prompts=900)…
job.batch/vllm-bench-job-inf created
job.batch/vllm-bench-job-inf condition met
📖 Logs from vllm-bench-job-inf:
Using HF_TOKEN as HUGGINGFACE_HUB_TOKEN
Starting benchmark at Fri May 30 20:39:20 UTC 2025
----- ENV VARS -----
  BASE_URL=http://llm-d-inference-gateway.llm-d.svc.cluster.local:80
  MODEL=meta-llama/Llama-3.2-3B-Instruct
  DATASET_NAME=random
  RANDOM_INPUT_LEN=1000
  RANDOM_OUTPUT_LEN=500
  REQUEST_RATE=inf
  NUM_PROMPTS=900
  IGNORE_EOS=true
  RESULT_FILENAME=results.json
  METADATA=deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
--------------------
Running: python /opt/benchmark/vllm/benchmarks/benchmark_serving.py --base_url http://llm-d-inference-gateway.llm-d.svc.cluster.local:80 --model meta-llama/Llama-3.2-3B-Instruct --dataset-name random --random-input-len 1000 --random-output-len 500 --request-rate inf --num-prompts 900 --save-result --result-filename results.json --metadata deployment=base gpu=4xNVIDIA_L40S model=meta-llama/Llama-3.2-3B-Instruct gateway=kgateway prefill_replicas=0 decode_replicas=4 input_len=1000 output_len=500
WARNING 05-30 20:39:29 [__init__.py:221] Platform plugin tpu function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin cuda function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin rocm function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin hpu function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin xpu function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin cpu function's return value is None
WARNING 05-30 20:39:30 [__init__.py:221] Platform plugin neuron function's return value is None
INFO 05-30 20:39:30 [__init__.py:250] No platform detected, vLLM is running on UnspecifiedPlatform
WARNING 05-30 20:39:31 [_custom_ops.py:21] Failed to import from vllm._C with ImportError('libcuda.so.1: cannot open shared object file: No such file or directory')
Namespace(backend='vllm', base_url='http://llm-d-inference-gateway.llm-d.svc.cluster.local:80', host='127.0.0.1', port=8000, endpoint='/v1/completions', dataset_name='random', dataset_path=None, max_concurrency=None, model='meta-llama/Llama-3.2-3B-Instruct', tokenizer=None, use_beam_search=False, num_prompts=900, logprobs=None, request_rate=inf, burstiness=1.0, seed=0, trust_remote_code=False, disable_tqdm=False, profile=False, save_result=True, save_detailed=False, append_result=False, metadata=['deployment=base', 'gpu=4xNVIDIA_L40S', 'model=meta-llama/Llama-3.2-3B-Instruct', 'gateway=kgateway', 'prefill_replicas=0', 'decode_replicas=4', 'input_len=1000', 'output_len=500'], result_dir=None, result_filename='results.json', ignore_eos=False, percentile_metrics='ttft,tpot,itl', metric_percentiles='99', goodput=None, sonnet_input_len=550, sonnet_output_len=150, sonnet_prefix_len=200, sharegpt_output_len=None, random_input_len=1000, random_output_len=500, random_range_ratio=0.0, random_prefix_len=0, hf_subset=None, hf_split=None, hf_output_len=None, top_p=None, top_k=None, min_p=None, temperature=None, tokenizer_mode='auto', served_model_name=None, lora_modules=None)
Starting initial single prompt test run...
Initial test run completed. Starting main benchmark run...
Traffic request rate: inf
Burstiness factor: 1.0 (Poisson process)
Maximum request concurrency: None
100%|██████████| 900/900 [00:20<00:00, 43.02it/s]
============ Serving Benchmark Result ============
Successful requests:                     900
Benchmark duration (s):                  20.92
Total input tokens:                      899100
Total generated tokens:                  240163
Request throughput (req/s):              43.02
Output token throughput (tok/s):         11481.02
Total Token throughput (tok/s):          54462.58
---------------Time to First Token----------------
Mean TTFT (ms):                          902.25
Median TTFT (ms):                        877.08
P99 TTFT (ms):                           1353.17
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          44.36
Median TPOT (ms):                        43.74
P99 TPOT (ms):                           67.41
---------------Inter-token Latency----------------
Mean ITL (ms):                           40.13
Median ITL (ms):                         36.94
P99 ITL (ms):                            66.37
==================================================
<<<RESULT_START>>>
{"date": "20250530-204006", "backend": "vllm", "model_id": "meta-llama/Llama-3.2-3B-Instruct", "tokenizer_id": "meta-llama/Llama-3.2-3B-Instruct", "num_prompts": 900, "deployment": "base", "gpu": "4xNVIDIA_L40S", "model": "meta-llama/Llama-3.2-3B-Instruct", "gateway": "kgateway", "prefill_replicas": "0", "decode_replicas": "4", "input_len": "1000", "output_len": "500", "request_rate": "inf", "burstiness": 1.0, "max_concurrency": null, "duration": 20.918269691000205, "completed": 900, "total_input_tokens": 899100, "total_output_tokens": 240163, "request_throughput": 43.024591101204344, "request_goodput:": null, "output_throughput": 11481.016525153933, "total_token_throughput": 54462.58303525708, "mean_ttft_ms": 902.2531994799939, "median_ttft_ms": 877.0819514993491, "std_ttft_ms": 194.26376120632074, "p99_ttft_ms": 1353.1694669699937, "mean_tpot_ms": 44.35695594492121, "median_tpot_ms": 43.742781012684844, "std_tpot_ms": 7.88600060931539, "p99_tpot_ms": 67.41057380823649, "mean_itl_ms": 40.126101133447385, "median_itl_ms": 36.940078000043286, "std_itl_ms": 8.77480669076588, "p99_itl_ms": 66.37176537940839}
<<<RESULT_END>>>
Appended results block for infinite QPS
Cleaning up Job vllm-bench-job-inf...
job.batch "vllm-bench-job-inf" deleted
✅ All benchmarks complete. Combined results in ./results.json
```
