#!/usr/bin/env bash
# Generate Codex config + auth at runtime (needs env vars)
set -euo pipefail

mkdir -p ~/.codex

cat > ~/.codex/config.toml <<EOF
model = "gpt-5.3-codex"
model_provider = "azure_responses"

[model_providers.azure_responses]
name = "Azure Responses API"
base_url = "https://${AZURE_RESOURCE_NAME:-localhost}.openai.azure.com/openai/v1"
env_key = "AZURE_OPENAI_API_KEY"
wire_api = "responses"

[model_providers.azure_responses.query_params]
api-version = "preview"
EOF

# Pre-create auth.json so Codex skips the login prompt
cat > ~/.codex/auth.json <<EOF
{"OPENAI_API_KEY": "${AZURE_OPENAI_API_KEY:-}"}
EOF

exec bash --rcfile /home/demo/.bashrc
