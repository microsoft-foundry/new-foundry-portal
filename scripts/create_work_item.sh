#!/usr/bin/env bash
set -euo pipefail

# This script expects env vars:
# AZDO_ORG, AZDO_PROJECT, AZDO_PAT, ADO_WORKITEM_TYPE, ISSUE_NUMBER, ISSUE_TITLE, ISSUE_BODY, ISSUE_URL,
# GITHUB_REPOSITORY, ISSUE_ASSIGNEE, GITHUB_TOKEN, AZDO_USER_MAP (optional)
# Requires: jq (ubuntu-latest runner includes jq)

if [ -z "${AZDO_PAT:-}" ]; then
  echo "AZDO_PAT is not set. Create a secret AZDO_PAT with your Azure DevOps PAT."
  exit 1
fi
if [ -z "${AZDO_ORG:-}" ] || [ -z "${AZDO_PROJECT:-}" ]; then
  echo "AZDO_ORG and AZDO_PROJECT environment variables must be set."
  exit 1
fi

REPO="${GITHUB_REPOSITORY}"
ISSUE_NUM="${ISSUE_NUMBER}"
GITHUB_API="https://api.github.com/repos/${REPO}/issues/${ISSUE_NUM}/comments"

# Idempotency: skip if we've already posted an ADO link comment
echo "Checking for an existing ADO link comment on the GitHub issue..."
existing_comment=$(curl -sSf -H "Authorization: token ${GITHUB_TOKEN}" "${GITHUB_API}" | \
  jq -r --arg marker "Azure DevOps Work Item:" '.[] | select(.body | contains($marker)) | .body' || true)

if [ -n "$existing_comment" ]; then
  echo "Found existing ADO link comment, skipping work item creation."
  echo "$existing_comment"
  exit 0
fi

# Build title and description
TITLE="GH Issue #${ISSUE_NUM}: ${ISSUE_TITLE}"
DESCRIPTION="Original GitHub issue: ${ISSUE_URL}\n\n${ISSUE_BODY:-}"

# Resolve assignee mapping (GitHub login -> Azure DevOps identity)
ASSIGNEE_LOGIN="${ISSUE_ASSIGNEE:-}"
ASSIGNED_TO_VALUE=""

# Check repo mapping file first (preferred)
MAP_FILE=".github/ado-user-map.json"
if [ -n "${ASSIGNEE_LOGIN}" ] && [ -f "${MAP_FILE}" ]; then
  echo "Looking up mapping for '${ASSIGNEE_LOGIN}' in repository ${MAP_FILE}..."
  mapped=$(jq -r --arg k "$ASSIGNEE_LOGIN" '.[$k] // empty' "${MAP_FILE}" || true)
  if [ -n "$mapped" ] && [ "$mapped" != "null" ]; then
    ASSIGNED_TO_VALUE="$mapped"
    echo "Found mapping in repo file: ${ASSIGNED_TO_VALUE}"
  fi
fi

# If not found, try variable/secret-provided AZDO_USER_MAP (fallback)
if [ -z "${ASSIGNED_TO_VALUE}" ] && [ -n "${AZDO_USER_MAP:-}" ]; then
  echo "Checking AZDO_USER_MAP for mapping..."
  mapped=$(jq -r --arg k "$ASSIGNEE_LOGIN" '.[$k] // empty' <<<"${AZDO_USER_MAP}" || true)
  if [ -n "$mapped" ] && [ "$mapped" != "null" ]; then
    ASSIGNED_TO_VALUE="$mapped"
    echo "Found mapping in AZDO_USER_MAP: ${ASSIGNED_TO_VALUE}"
  fi
fi

if [ -n "${ASSIGNEE_LOGIN}" ] && [ -z "${ASSIGNED_TO_VALUE}" ]; then
  echo "No mapping found for GitHub user '${ASSIGNEE_LOGIN}'. Work item will be created unassigned."
fi

# Build JSON patch using jq
ops=$(jq -n --arg title "$TITLE" --arg desc "$DESCRIPTION" \
  '[ { op: "add", path: "/fields/System.Title", value: $title }, { op: "add", path: "/fields/System.Description", value: $desc } ]')

if [ -n "$ASSIGNED_TO_VALUE" ]; then
  ops=$(jq --arg at "$ASSIGNED_TO_VALUE" '. + [{ op: "add", path: "/fields/System.AssignedTo", value: $at }]' <<<"$ops")
fi

patch_file=$(mktemp)
echo "$ops" > "$patch_file"

# Azure DevOps REST endpoint (work item create)
ADO_URL="https://dev.azure.com/${AZDO_ORG}/${AZDO_PROJECT}/_apis/wit/workitems/\$${ADO_WORKITEM_TYPE}?api-version=7.0"

# Basic auth header (PAT)
auth_header="Authorization: Basic $(printf ":%s" "${AZDO_PAT}" | base64 -w 0)"

echo "Creating work item in Azure DevOps: ${ADO_WORKITEM_TYPE} in ${AZDO_ORG}/${AZDO_PROJECT}..."
resp=$(curl -sS -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json-patch+json" \
  --data-binary @"${patch_file}" \
  "${ADO_URL}" || true)

work_item_id=$(jq -r '.id // empty' <<<"$resp")
if [ -z "$work_item_id" ]; then
  echo "Failed to create work item. Response:"
  echo "$resp"
  rm -f "${patch_file}"
  exit 1
fi

web_ui_url="https://dev.azure.com/${AZDO_ORG}/${AZDO_PROJECT}/_workitems/edit/${work_item_id}"
echo "Created ADO work item #${work_item_id}: ${web_ui_url}"

# Compose comment back to GitHub issue
if [ -n "$ASSIGNED_TO_VALUE" ]; then
  comment_body="Azure DevOps Work Item: [${ADO_WORKITEM_TYPE} #${work_item_id}](${web_ui_url}) created from this GitHub issue. Assigned to: ${ASSIGNED_TO_VALUE}"
else
  comment_body="Azure DevOps Work Item: [${ADO_WORKITEM_TYPE} #${work_item_id}](${web_ui_url}) created from this GitHub issue. No Azure DevOps assignee mapping was found for the GitHub assignee '${ASSIGNEE_LOGIN}'. To enable automatic assignment, add a mapping in ${MAP_FILE} in this repo or set the ADO_USER_MAP repository variable. Example mapping: { \"${ASSIGNEE_LOGIN}\": \"Alice Smith <alice.smith@contoso.com>\" }"
fi

curl -sS -X POST \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API}" \
  -d "$(jq -nc --arg body "$comment_body" '{body:$body}')" || true

echo "Posted comment to GitHub issue with ADO link."

rm -f "${patch_file}"
exit 0
