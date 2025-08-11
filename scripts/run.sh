#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: run.sh <public GitHub repo URL>"
  exit 1
fi
: "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"

OPENAI_ASSISTANT_MODEL="${OPENAI_ASSISTANT_MODEL:-gpt-4.1}" # a tools-capable model
WORKDIR="$(pwd)"
TMPDIR="$(mktemp -d)"
ZIP_PATH="${TMPDIR}/code.zip"
trap 'rm -rf "$TMPDIR"' EXIT

# Parse owner/repo
NORM_URL="${REPO_URL%.git}"
if [[ "${NORM_URL}" =~ github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"
else
  echo "Could not parse owner/repo from: ${REPO_URL}"; exit 1
fi
echo "Owner: ${OWNER}"
echo "Repo : ${REPO}"

# Download repo zip
echo "Downloading zip..."
curl -fsSL -o "${ZIP_PATH}" "https://api.github.com/repos/${OWNER}/${REPO}/zipball"

# Upload zip file
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
  echo "File upload failed:"; echo "${FILE_UPLOAD_JSON}"; exit 1
fi
echo "file_id: ${FILE_ID}"

# Read static prompt
PROMPT_PATH="${WORKDIR}/prompts/static.txt"
[[ -f "${PROMPT_PATH}" ]] || { echo "Static prompt not found at ${PROMPT_PATH}"; exit 1; }
STATIC_PROMPT="$(cat "${PROMPT_PATH}")"

# Create an assistant (ephemeral)
echo "Creating assistant..."
ASSISTANT_JSON="$(
  jq -n --arg model "${OPENAI_ASSISTANT_MODEL}" '
    { "model": $model, "name":"Repo Analyzer CI", "tools":[{"type":"code_interpreter"}] }'
)"
ASSISTANT_RESP="$(
  curl -sS -X POST "https://api.openai.com/v1/assistants" \
    -H "OpenAI-Beta: assistants=v2" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${ASSISTANT_JSON}"
)"
ASSISTANT_ID="$(echo "${ASSISTANT_RESP}" | jq -r '.id // empty')"
[[ -n "${ASSISTANT_ID}" ]] || { echo "Assistant create failed:"; echo "${ASSISTANT_RESP}"; exit 1; }
echo "assistant_id: ${ASSISTANT_ID}"

# Create thread with a user message that attaches the ZIP and enables the tool
echo "Creating thread + message..."
THREAD_JSON="$(
  jq -n --arg prompt "${STATIC_PROMPT}" --arg file_id "${FILE_ID}" '
  {
    "messages": [
      {
        "role": "user",
        "content": [
          {"type":"text","text": $prompt}
        ],
        "attachments":[
          {"file_id": $file_id, "tools":[{"type":"code_interpreter"}]}
        ]
      }
    ]
  }'
)"
THREAD_RESP="$(
  curl -sS -X POST "https://api.openai.com/v1/threads" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "OpenAI-Beta: assistants=v2" \
    -H "Content-Type: application/json" \
    -d "${THREAD_JSON}"
)"
THREAD_ID="$(echo "${THREAD_RESP}" | jq -r '.id // empty')"
[[ -n "${THREAD_ID}" ]] || { echo "Thread create failed:"; echo "${THREAD_RESP}"; exit 1; }
echo "thread_id: ${THREAD_ID}"

# Run the thread
echo "Starting run..."
RUN_RESP="$(
  curl -sS -X POST "https://api.openai.com/v1/threads/${THREAD_ID}/runs" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "OpenAI-Beta: assistants=v2" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "${ASSISTANT_ID}" '{ "assistant_id": $id }')"
)"
RUN_ID="$(echo "${RUN_RESP}" | jq -r '.id // empty')"
[[ -n "${RUN_ID}" ]] || { echo "Run start failed:"; echo "${RUN_RESP}"; exit 1; }
echo "run_id: ${RUN_ID}"

# Poll until completed
echo "Polling run..."
STATUS="$(echo "${RUN_RESP}" | jq -r '.status')"
TRIES=0; MAX_TRIES=120
while [[ "${STATUS}" != "completed" && "${STATUS}" != "failed" && "${TRIES}" -lt "${MAX_TRIES}" ]]; do
  sleep 20
  RUN_RESP="$(
    curl -sS "https://api.openai.com/v1/threads/${THREAD_ID}/runs/${RUN_ID}" \
      -H "OpenAI-Beta: assistants=v2" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}"
  )"
  STATUS="$(echo "${RUN_RESP}" | jq -r '.status')"
  echo "status: ${STATUS}"
  TRIES=$((TRIES+1))
done
[[ "${STATUS}" == "completed" ]] || { echo "Run did not complete:"; echo "${RUN_RESP}"; exit 1; }

# Fetch messages and extract the latest assistant text
echo "Fetching messages..."
MSGS="$(
  curl -sS "https://api.openai.com/v1/threads/${THREAD_ID}/messages?limit=20" \
        -H "OpenAI-Beta: assistants=v2" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}"
)"
TEXT="$(echo "${MSGS}" | jq -r '
  .data
  | map(select(.role=="assistant"))
  | sort_by(.created_at) | last
  | .content
  | map(select(.type=="text"))[0].text.value // "NO_TEXT_RETURNED"
')"

echo "${TEXT}" > "${WORKDIR}/response.txt"
echo "Saved response.txt"
