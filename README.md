# Shared Market-Research Infra

One set of databases, one LLM server and one copy of the model weights for every market-research
project on this machine. Each project keeps its own analytical engine and UI in its own repo and
joins this stack over the `market-infra` Docker network.

| Service    | Image                       | Container      | In-network        | Host (localhost only) |
|------------|-----------------------------|----------------|-------------------|-----------------------|
| `postgres` | pgvector/pgvector:pg16      | `mri-postgres` | `postgres:5432`   | 127.0.0.1:5432        |
| `mongo`    | mongo:7                     | `mri-mongo`    | `mongo:27017`     | 127.0.0.1:27017       |
| `neo4j`    | neo4j:5-community           | `mri-neo4j`    | `neo4j:7687`      | 127.0.0.1:7474 / 7687 |
| `vllm`     | built from `vllm/` (profile `llm`, GPU) | `mri-vllm` | `vllm:8000` | 127.0.0.1:8001 |

## Everything is a local folder

| Folder                 | Holds                                  |
|------------------------|----------------------------------------|
| `data/postgres`        | Postgres data files                    |
| `data/mongo`           | MongoDB data files                     |
| `data/neo4j/{data,logs}` | Neo4j database and logs              |
| `models/huggingface`   | model weights (Hugging Face cache layout) |
| `secrets/<project>.env`| generated connection settings per project |

No Docker volumes are used, so `down.ps1` never touches data, and a backup is a folder copy
taken while the stack is stopped (`.\down.ps1`, copy `data\`, `.\up.ps1`). Change the location
with `DATA_DIR` / `MODELS_DIR` in `.env`. `data/`, `models/*`, `secrets/` and `.env` are git-ignored.

## Commands

```powershell
.\up.ps1 -Project ath_scanner          # start the databases and provision a project
.\up.ps1 -Project ath_scanner -Llm     # also start vLLM (holds the GPU)
.\down.ps1 -Llm                        # free the GPU, leave the databases running
.\down.ps1                             # stop everything (data and models stay)
.\models.ps1 -List                     # what weights are present
.\models.ps1                           # download whatever models.json lists and is missing
```

`up.ps1` is safe to repeat. The first run generates the admin passwords into `.env`; they are never
rotated afterwards because the databases were initialised with them.

## Joining from a project

Provisioning creates, per project name, a Postgres database and login, a MongoDB database and user
(readWrite on that database only), and `secrets/<name>.env` with `POSTGRES_DSN`, `MONGO_URI`,
`NEO4J_URI` / `NEO4J_USER` / `NEO4J_PASSWORD` / `NEO4J_AUTH` and `VLLM_URL`. In the project's compose file:

```yaml
services:
  api:
    env_file:
      - path: ../Shared-Market-Research-Infra/secrets/my_project.env
        required: false
networks:
  default:
    name: market-infra
    external: true
```

Neo4j Community has a single database and a shared admin login, so projects that share it should
prefix their labels or use distinct property namespaces.

## Models

`models.json` lists the weights the projects need (Qwen3-4B-Instruct-2507 for vLLM, TimesFM 2.5 for
forecasting). The vLLM container and any consumer mount `models/huggingface` and run with
`HF_HUB_OFFLINE=1`, so nothing is downloaded at run time. To add a model, add it to `models.json`
and run `.\models.ps1`. Tuning of the LLM server (context length, GPU share, quantisation) is in
`vllm/Dockerfile`.
