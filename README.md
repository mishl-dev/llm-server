# llm-server

Docker-based LLM serving with [llama.cpp](https://github.com/ggml-org/llama.cpp). Auto-downloads models from Hugging Face and serves them via an OpenAI-compatible API.

## Quickstart

1. Add models to `models.toml`:

```toml
[[models]]
name = "my-model"
repo = "org/model-GGUF"
file = "model-q4_k_m.gguf"
```

2. Download models and start the server:

```sh
just sync    # download missing models
just up      # start server
```

The server runs at `http://localhost:8080`.

## Commands

| Command | Description |
|---------|-------------|
| `just up` | Start server |
| `just down` | Stop server |
| `just restart` | Restart server |
| `just sync` | Download missing models from Hugging Face |
| `just logs` | Follow container logs |

## Config

**`models.toml`** — single source of truth. Define global settings and per-model config:

```toml
[global]
n-gpu-layers = -1
flash-attn = true

[[models]]
name = "gemma4-v2"
repo = "org/repo"
file = "model.gguf"
```

Models are auto-downloaded on container start or via `just sync`. The server reads the generated `/config.ini` at startup — no manual config file needed.

## API

The server exposes an OpenAI-compatible API at `http://localhost:8080`:

```sh
curl http://localhost:8080/v1/chat/completions \
  -d '{"model": "gemma4-v2", "messages": [{"role": "user", "content": "hello"}]}'
```

## License

[MIT](LICENSE)