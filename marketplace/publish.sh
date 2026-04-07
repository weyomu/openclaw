#!/usr/bin/env bash
# =============================================================================
# publish.sh
# 调用 Azure Partner Center Submission API，将已构建的镜像版本更新到 Marketplace 供应项目
#
# 使用方式：
#   ./publish.sh --version 1.0.0 --offer openclaw-ai-assistant
#
# 所需环境变量（从 GitHub Secrets 注入，或本地 export 设置）：
#   AZURE_CLIENT_ID         - Service Principal App ID
#   AZURE_CLIENT_SECRET     - Service Principal 密码
#   AZURE_TENANT_ID         - Azure AD 租户 ID
#   AZURE_SUBSCRIPTION_ID   - Azure 订阅 ID
#   PARTNER_CENTER_TENANT_ID - Partner Center 专用租户 ID（通常与 AZURE_TENANT_ID 相同）
#
# 参考文档：
#   https://learn.microsoft.com/zh-cn/azure/marketplace/submission-api-overview
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}==>${NC} $*\n"; }

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
IMAGE_VERSION=""
OFFER_ID="openclaw-ai-assistant"
PLAN_ID="openclaw-standard"
PUBLISHER_ID=""
DRY_RUN=false
SKIP_PUBLISH=false

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  --version VERSION       镜像版本号（必填，格式: major.minor.patch）
  --offer OFFER_ID        供应项目 ID（默认: openclaw-ai-assistant）
  --plan PLAN_ID          方案 ID（默认: openclaw-standard）
  --publisher PUBLISHER   发布者 ID（必填，或从环境变量 PUBLISHER_ID 读取）
  --dry-run               仅输出将要执行的 API 调用，不实际执行
  --skip-publish          更新技术配置后不触发发布（仅更新草稿）
  -h, --help              显示此帮助信息

示例：
  ./publish.sh --version 1.0.0 --publisher mycompany

环境变量：
  AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
  PARTNER_CENTER_TENANT_ID  （可选，默认使用 AZURE_TENANT_ID）
  PUBLISHER_ID              （可选，通过 --publisher 参数覆盖）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    IMAGE_VERSION="$2"; shift 2 ;;
    --offer)      OFFER_ID="$2"; shift 2 ;;
    --plan)       PLAN_ID="$2"; shift 2 ;;
    --publisher)  PUBLISHER_ID="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --skip-publish) SKIP_PUBLISH=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 参数验证
# ---------------------------------------------------------------------------
log_step "Validating parameters"

MISSING=()
[[ -z "${IMAGE_VERSION}" ]]           && MISSING+=("--version")
[[ -z "${AZURE_CLIENT_ID:-}" ]]       && MISSING+=("AZURE_CLIENT_ID")
[[ -z "${AZURE_CLIENT_SECRET:-}" ]]   && MISSING+=("AZURE_CLIENT_SECRET")
[[ -z "${AZURE_TENANT_ID:-}" ]]       && MISSING+=("AZURE_TENANT_ID")
[[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]] && MISSING+=("AZURE_SUBSCRIPTION_ID")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log_error "Missing required parameters: ${MISSING[*]}"
  usage
  exit 1
fi

if ! echo "${IMAGE_VERSION}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  log_error "Invalid version format: '${IMAGE_VERSION}'. Expected: major.minor.patch"
  exit 1
fi

# Partner Center 使用的租户 ID（与 Azure 租户相同）
PC_TENANT_ID="${PARTNER_CENTER_TENANT_ID:-${AZURE_TENANT_ID}}"

# 从配置文件读取 Publisher ID（如果命令行未指定）
if [[ -z "${PUBLISHER_ID}" ]]; then
  PUBLISHER_ID="${PUBLISHER_ID:-$(jq -r '.offer.publisherId' "$(dirname "$0")/offer-config.json" 2>/dev/null || echo '')}"
fi

if [[ -z "${PUBLISHER_ID}" || "${PUBLISHER_ID}" == "YOUR_PUBLISHER_ID" ]]; then
  log_error "Publisher ID is required. Set --publisher or update offer-config.json"
  exit 1
fi

# SIG 镜像版本完整资源 ID
SIG_IMAGE_VERSION_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-shared-images/providers/Microsoft.Compute/galleries/MyGallery/images/OpenClawImage/versions/${IMAGE_VERSION}"

log_info "Configuration:"
log_info "  Offer ID:          ${OFFER_ID}"
log_info "  Plan ID:           ${PLAN_ID}"
log_info "  Publisher ID:      ${PUBLISHER_ID}"
log_info "  Image version:     ${IMAGE_VERSION}"
log_info "  SIG Image ID:      ${SIG_IMAGE_VERSION_ID}"
log_info "  Dry run:           ${DRY_RUN}"
log_info "  Skip publish:      ${SKIP_PUBLISH}"

# ---------------------------------------------------------------------------
# Step 1: 获取 Partner Center 访问令牌
# ---------------------------------------------------------------------------
log_step "Step 1: Obtaining Partner Center access token"

PC_TOKEN_URL="https://login.microsoftonline.com/${PC_TENANT_ID}/oauth2/token"
PC_RESOURCE="https://api.partner.microsoft.com"

if [[ "${DRY_RUN}" == "true" ]]; then
  log_warn "[DRY RUN] Would call: POST ${PC_TOKEN_URL}"
  ACCESS_TOKEN="DRY_RUN_TOKEN"
else
  TOKEN_RESPONSE=$(curl -s -X POST "${PC_TOKEN_URL}" \
    -d "grant_type=client_credentials" \
    -d "client_id=${AZURE_CLIENT_ID}" \
    -d "client_secret=${AZURE_CLIENT_SECRET}" \
    -d "resource=${PC_RESOURCE}")

  ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token')

  if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
    log_error "Failed to obtain access token"
    log_error "Response: ${TOKEN_RESPONSE}"
    exit 1
  fi

  log_info "Access token obtained successfully"
fi

# ---------------------------------------------------------------------------
# 公共函数：调用 Partner Center API
# ---------------------------------------------------------------------------
PC_API_BASE="https://api.partner.microsoft.com/v1.0/ingestion"

call_pc_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local url="${PC_API_BASE}${endpoint}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "[DRY RUN] Would call: ${method} ${url}"
    if [[ -n "${body}" ]]; then
      log_warn "[DRY RUN] Body: ${body}"
    fi
    echo '{"id":"dry-run-id","status":"DryRun"}'
    return 0
  fi

  local curl_args=(
    -s
    -X "${method}"
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
  )

  if [[ -n "${body}" ]]; then
    curl_args+=(-d "${body}")
  fi

  local response
  response=$(curl "${curl_args[@]}" "${url}")

  # 检查是否有错误
  local error
  error=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null || true)
  if [[ -n "${error}" ]]; then
    log_error "API call failed: ${error}"
    log_error "Full response: ${response}"
    return 1
  fi

  echo "${response}"
}

# ---------------------------------------------------------------------------
# Step 2: 获取当前供应项目草稿
# ---------------------------------------------------------------------------
log_step "Step 2: Fetching current offer draft"

OFFER_RESPONSE=$(call_pc_api "GET" "/publishers/${PUBLISHER_ID}/offers/${OFFER_ID}/submissions/draft")
log_info "Current offer fetched"

ETAG=$(echo "${OFFER_RESPONSE}" | jq -r '."@odata.etag" // ""')
log_info "ETag: ${ETAG}"

# ---------------------------------------------------------------------------
# Step 3: 更新方案的技术配置（关联新镜像版本）
# ---------------------------------------------------------------------------
log_step "Step 3: Updating plan technical configuration with new image version"

# 构造更新请求体
UPDATE_BODY=$(cat << EOF
{
  "resourceType": "AzureVirtualMachinePackage",
  "planId": "${PLAN_ID}",
  "vmImageVersions": [
    {
      "versionNumber": "${IMAGE_VERSION}",
      "vmImages": [
        {
          "imageType": "OSDisk",
          "source": {
            "sourceType": "SharedImageGallery",
            "imageVersionResourceId": "${SIG_IMAGE_VERSION_ID}"
          }
        }
      ]
    }
  ]
}
EOF
)

PLAN_UPDATE_RESPONSE=$(call_pc_api \
  "PUT" \
  "/publishers/${PUBLISHER_ID}/offers/${OFFER_ID}/plans/${PLAN_ID}/technicalConfiguration" \
  "${UPDATE_BODY}")

log_info "Plan technical configuration updated"
log_info "Response: $(echo "${PLAN_UPDATE_RESPONSE}" | jq -r '.id // "ok"')"

# ---------------------------------------------------------------------------
# Step 4: 提交供应项目进行发布（可选）
# ---------------------------------------------------------------------------
if [[ "${SKIP_PUBLISH}" == "true" ]]; then
  log_warn "Skipping publish step (--skip-publish flag set)"
  log_info "Offer draft updated. Review in Partner Center before publishing."
else
  log_step "Step 4: Submitting offer for review and publication"

  SUBMIT_BODY=$(cat << EOF
{
  "resourceType": "OfferSetup",
  "targetEnvironment": "Production"
}
EOF
  )

  SUBMIT_RESPONSE=$(call_pc_api \
    "POST" \
    "/publishers/${PUBLISHER_ID}/offers/${OFFER_ID}/submissions" \
    "${SUBMIT_BODY}")

  SUBMISSION_ID=$(echo "${SUBMIT_RESPONSE}" | jq -r '.id // "unknown"')
  log_info "Submission created: ${SUBMISSION_ID}"

  # ---------------------------------------------------------------------------
  # Step 5: 等待提交进入审核状态
  # ---------------------------------------------------------------------------
  log_step "Step 5: Waiting for submission to enter review"

  if [[ "${DRY_RUN}" != "true" ]]; then
    MAX_WAIT=300  # 最多等待 5 分钟
    ELAPSED=0
    INTERVAL=15

    while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
      sleep "${INTERVAL}"
      ELAPSED=$((ELAPSED + INTERVAL))

      STATUS_RESPONSE=$(call_pc_api "GET" "/publishers/${PUBLISHER_ID}/offers/${OFFER_ID}/submissions/${SUBMISSION_ID}")
      STATUS=$(echo "${STATUS_RESPONSE}" | jq -r '.status // "Unknown"')

      log_info "[${ELAPSED}s] Submission status: ${STATUS}"

      case "${STATUS}" in
        "InReview"|"Published"|"Live")
          log_info "Submission successfully entered review/live state"
          break
          ;;
        "Failed"|"Stopped")
          log_error "Submission failed with status: ${STATUS}"
          log_error "Details: $(echo "${STATUS_RESPONSE}" | jq -r '.statusDetails // empty')"
          exit 1
          ;;
      esac
    done

    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
      log_warn "Timed out waiting for submission status. Check Partner Center manually."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
log_step "Publish script completed"

cat << EOF

${GREEN}Summary:${NC}
  Offer:         ${OFFER_ID}
  Plan:          ${PLAN_ID}
  Image Version: ${IMAGE_VERSION}
  Status:        $([ "${DRY_RUN}" == "true" ] && echo "DRY RUN" || echo "SUBMITTED")

${YELLOW}Next Steps:${NC}
  1. Go to Partner Center: https://partner.microsoft.com/dashboard
  2. Find offer: ${OFFER_ID}
  3. Monitor the review progress
  4. Microsoft review typically takes 3-5 business days for VM offers

${BLUE}Partner Center URL:${NC}
  https://partner.microsoft.com/dashboard/marketplace-offers/${PUBLISHER_ID}.${OFFER_ID}
EOF
