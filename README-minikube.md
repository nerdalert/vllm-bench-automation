
## Minikube Deploy

The script `e2e-bench-control.sh` is very minikube focused since the original intent was e2e smoke-testing.

- Setup your cluster

```bash
minikube start \
  --driver docker  \
  --container-runtime docker \
  --gpus all \
  --memory no-limit
```

Deploy with:

```bash
git clone https://github.com/llm-d/llm-d-deployer.git
cd quickstart
# no features
./llmd-installer.sh --minikube --values-file examples/no-features/slim/no-features-slim.yaml
# base (prefix scoring)
./llmd-installer.sh --minikube --values-file examples/base/base.yaml
# kvcache (kvcache aware scoring)
./llmd-installer.sh --minikube --values-file examples/kvcache/kvcache.yaml
```

### Run a deployment batch

Automate running multiple deployments in a batch with `e2e-bench-control.sh`. Example ENVs below will run two deployments with the input/output/request rates overriding the scripts defaults:

```yaml
ENV_DEPLOYMENT_VALUES_FILES="examples/no-features/slim/no-features-slim.yaml examples/base/slim/base-slim.yaml" \
ENV_BENCH_INPUT_LEN="512" \
ENV_BENCH_OUTPUT_LEN="1024" \
ENV_BENCH_REQUEST_RATES="5,10,inf" \
./e2e-bench-control.sh --model meta-llama/Llama-3.1-8B-Instruct	
```

Example output [here](https://gist.github.com/nerdalert/d985a6ea3a6c416771900a78e98b64f8)
