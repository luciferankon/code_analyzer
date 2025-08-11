#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: run.sh <public GitHub repo URL>"
  exit 1
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is required (set as a repo secret)."
  exit 1
fi

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4.1-mini}"
WORKDIR="$(pwd)"
TMPDIR="$(mktemp -d)"
ZIP_PATH="${TMPDIR}/code.zip"

cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

# Parse owner/repo
NORM_URL="${REPO_URL%.git}"
if [[ "${NORM_URL}" =~ github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  echo "Could not parse owner/repo from: ${REPO_URL}"
  exit 1
fi

echo "Owner: ${OWNER}"
echo "Repo : ${REPO}"

# Download default-branch zip
echo "Downloading zip..."
curl -fsSL -o "${ZIP_PATH}" "https://api.github.com/repos/${OWNER}/${REPO}/zipball"

# Upload file
echo "Uploading zip to OpenAI Files API..."
FILE_UPLOAD_JSON="$(
  curl -sS -X POST "https://api.openai.com/v1/files" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F "purpose=assistants" \
    -F "file=@${ZIP_PATH}"
)"
FILE_ID="$(echo "${FILE_UPLOAD_JSON}" | jq -r '.id')"
if [[ -z "${FILE_ID}" || "${FILE_ID}" == "null" ]]; then
  echo "Failed to upload file to OpenAI. Response:"
  echo "${FILE_UPLOAD_JSON}"
  exit 1
fi
echo "Uploaded file_id: ${FILE_ID}"

# Read static prompt
PROMPT_PATH="${WORKDIR}/prompts/static.txt"
if [[ ! -f "${PROMPT_PATH}" ]]; then
  echo "Static prompt not found at ${PROMPT_PATH}"
  exit 1
fi
STATIC_PROMPT="$(cat "${PROMPT_PATH}")"

# Build request JSON (attempt 1: with code_interpreter)
build_req_with_tools() {
  jq -n \
    --arg model "${OPENAI_MODEL}" \
    --arg prompt "${STATIC_PROMPT}" \
    --arg file_id "${FILE_ID}" '
  {
    "model": $model,
    "tools": [ { "type": "code_interpreter" } ],
    "input": [
      {
        "role": "user",
        "content": [
          { "type": "input_text", "text": $prompt },
          { "type": "input_file", "file_id": $file_id }
        ]
      }
    ]
  }'
}

# Fallback (no tools)
build_req_plain() {
  jq -n \
    --arg model "${OPENAI_MODEL}" \
    --arg prompt "${STATIC_PROMPT}" \
    --arg file_id "${FILE_ID}" '
  {
    "model": $model,
    "input": [
      {
        "role": "user",
        "content": [
          { "type": "input_text", "text": $prompt },
          { "type": "input_file", "file_id": $file_id }
        ]
      }
    ]
  }'
}

call_responses() {
  local payload="$1"
  local http_body http_code
  http_body="$(mktemp)"
  http_code="$(
    curl -sS -o "${http_body}" -w "%{http_code}" \
      -X POST "https://api.openai.com/v1/responses" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${payload}"
  )"
  echo "${http_code}|${http_body}"
}

echo "Creating response (with input_file + code_interpreter)..."
CREATE_JSON="$(build_req_with_tools)"
combo="$(call_responses "${CREATE_JSON}")"
HTTP_CODE="${combo%%|*}"
HTTP_RESP_FILE="${combo#*|}"
echo "HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" ]]; then
  echo "First attempt failed. Body:"
  cat "${HTTP_RESP_FILE}"

  # Retry without tools if the model/endpoint rejects tools
  echo "Retrying without tools..."
  CREATE_JSON="$(build_req_plain)"
  combo="$(call_responses "${CREATE_JSON}")"
  HTTP_CODE="${combo%%|*}"
  HTTP_RESP_FILE="${combo#*|}"
  echo "HTTP ${HTTP_CODE}"
fi

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" ]]; then
  echo "Responses API error body:"
  cat "${HTTP_RESP_FILE}"
  exit 1
fi

CREATE_RESP="$(cat "${HTTP_RESP_FILE}")"
RESP_ID="$(echo "${CREATE_RESP}" | jq -r '.id // empty')"
if [[ -z "${RESP_ID}" ]]; then
  echo "No response id. Full payload:"
  echo "${CREATE_RESP}"
  exit 1
fi
echo "Response ID: ${RESP_ID}"

# Poll until completed
echo "Polling for completion..."
STATUS="in_progress"
TRIES=0
MAX_TRIES=60

while [[ "${STATUS}" != "completed" && "${STATUS}" != "failed" && "${TRIES}" -lt "${MAX_TRIES}" ]]; do
  sleep 3
  POLL="$(
    curl -sS -X GET "https://api.openai.com/v1/responses/${RESP_ID}" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}"
  )"
  STATUS="$(echo "${POLL}" | jq -r '.status')"
  echo "Status: ${STATUS}"
  TRIES=$((TRIES+1))
done

if [[ "${STATUS}" != "completed" ]]; then
  echo "Response did not complete. Final payload:"
  echo "${POLL}"
  exit 1
fi

# Save raw JSON for debugging
echo "${POLL}" > response_raw.json

# Extract text
OUTPUT_TEXT="$(echo "${POLL}" | jq -r '.output_text // ( .output[0].content[0].text // .choices[0].message.content // "NO_TEXT_RETURNED")')"
echo "${OUTPUT_TEXT}" > "${WORKDIR}/response.txt"
echo "Saved response.txt"
