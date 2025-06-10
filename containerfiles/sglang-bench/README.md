
## Build

```shell
docker build -f Containerfile -t ghcr.io/nerdalert/sgl-bench:latest .
```

## Run

```shell
podman || docker run --rm \
  -e HOST=<HOST_IP> \
  -e PORT=8000 \
  -e DATASET_NAME=generated-shared-prefix \
  -e GSP_PROMPTS_PER_GROUP=16 \
  -e GSP_SYSTEM_PROMPT_LEN=2048 \
  -e GSP_QUESTION_LEN=128 \
  -e GSP_OUTPUT_LEN=256 \
  -e BACKEND=vllm \
  -v $(pwd)/out:/results \
  ghcr.io/nerdalert/sgl-bench:latest
```
