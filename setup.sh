#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Claude Code + AWS Bedrock — Interactive Setup Script (macOS / Linux)
# ─────────────────────────────────────────────────────────────────────────────

# ── Color helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m' # No Color

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${NC}\n\n" "$*"; }

# ── Cleanup trap ─────────────────────────────────────────────────────────────
TEMPFILES=()
cleanup() {
    local exit_code=$?
    for f in "${TEMPFILES[@]:-}"; do
        rm -f "$f"
    done
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        warn "Script exited early. Your settings have NOT been changed."
    fi
}
trap cleanup EXIT

# ── Utility functions ────────────────────────────────────────────────────────
prompt_default() {
    local prompt="$1" default="$2" var_name="$3"
    printf "%s [%s]: " "$prompt" "$default"
    read -r input
    eval "$var_name='${input:-$default}'"
}

prompt_required() {
    local prompt="$1" var_name="$2"
    local value=""
    while [[ -z "$value" ]]; do
        printf "%s: " "$prompt"
        read -r value
        if [[ -z "$value" ]]; then
            warn "This field is required."
        fi
    done
    eval "$var_name='$value'"
}

prompt_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        printf "%s [Y/n]: " "$prompt"
    else
        printf "%s [y/N]: " "$prompt"
    fi
    read -r yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy] ]]
}

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

OS="$(detect_os)"

# ─────────────────────────────────────────────────────────────────────────────
# Collected configuration — populated as we go
# ─────────────────────────────────────────────────────────────────────────────
AUTH_METHOD=""        # sso | keys | existing
AWS_PROFILE_NAME=""   # only for SSO
AWS_REGION=""
MODEL_ARN=""
SMALL_FAST_MODEL=""
ENABLE_AUTH_REFRESH=false
HAS_AWS_CLI=false
MODEL_NAMES=()
MODEL_ARNS=()

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        Claude Code + AWS Bedrock — Setup Wizard             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
info "This script will walk you through setting up Claude Code to"
info "use AWS Bedrock as its model provider."
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Step 1: Check Node.js >= 18
# ═════════════════════════════════════════════════════════════════════════════
header "Step 1 / 9 — Node.js"

if command -v node &>/dev/null; then
    NODE_VERSION="$(node --version)"
    NODE_MAJOR="${NODE_VERSION#v}"
    NODE_MAJOR="${NODE_MAJOR%%.*}"
    if [[ "$NODE_MAJOR" -ge 18 ]]; then
        success "Node.js $NODE_VERSION detected (>= 18 required)."
    else
        error "Node.js $NODE_VERSION is too old. Version 18+ is required."
        echo ""
        if [[ "$OS" == "macos" ]]; then
            info "Install via Homebrew:  brew install node"
        else
            info "Install via nvm:       curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
            info "                       nvm install --lts"
        fi
        info "Or visit: https://nodejs.org/"
        exit 1
    fi
else
    error "Node.js is not installed. Version 18+ is required."
    echo ""
    if [[ "$OS" == "macos" ]]; then
        info "Install via Homebrew:  brew install node"
    else
        info "Install via nvm:       curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
        info "                       nvm install --lts"
    fi
    info "Or visit: https://nodejs.org/"
    exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
# Step 2: Check AWS CLI
# ═════════════════════════════════════════════════════════════════════════════
header "Step 2 / 9 — AWS CLI"

if command -v aws &>/dev/null; then
    AWS_CLI_VERSION="$(aws --version 2>&1 | head -1)"
    success "AWS CLI detected: $AWS_CLI_VERSION"
    HAS_AWS_CLI=true
else
    warn "AWS CLI is not installed."
    info "The script can still write your config, but verification will be skipped."
    echo ""
    if [[ "$OS" == "macos" ]]; then
        info "Install via Homebrew:  brew install awscli"
    else
        info "Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
    echo ""
    if ! prompt_yes_no "Continue without AWS CLI?"; then
        info "Please install the AWS CLI and re-run this script."
        exit 0
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Step 3: Check / Install Claude Code
# ═════════════════════════════════════════════════════════════════════════════
header "Step 3 / 9 — Claude Code"

if command -v claude &>/dev/null; then
    CLAUDE_VERSION="$(claude --version 2>/dev/null || echo "unknown")"
    success "Claude Code detected: $CLAUDE_VERSION"
else
    warn "Claude Code is not installed."
    echo ""
    if prompt_yes_no "Install Claude Code now via npm?"; then
        info "Running: npm install -g @anthropic-ai/claude-code"
        if npm install -g @anthropic-ai/claude-code; then
            success "Claude Code installed."
        else
            warn "npm install failed. This can happen if your Node.js was installed"
            warn "with a system package manager that requires sudo for global installs."
            echo ""
            info "Options:"
            info "  1. Run:  sudo npm install -g @anthropic-ai/claude-code"
            info "  2. Use nvm (https://github.com/nvm-sh/nvm) to manage Node.js"
            info "     without requiring sudo for global installs."
            echo ""
            warn "Continuing without Claude Code installed. You can install it later."
        fi
    else
        info "You can install it later:  npm install -g @anthropic-ai/claude-code"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Step 4: AWS Authentication Method
# ═════════════════════════════════════════════════════════════════════════════
header "Step 4 / 9 — AWS Authentication"

echo "How are you authenticating with AWS?"
echo ""
echo "  1) AWS SSO / Identity Center  (recommended)"
echo "  2) IAM access keys"
echo "  3) Already configured (env vars, instance role, etc.)"
echo ""
printf "Choose [1/2/3]: "
read -r auth_choice

case "${auth_choice:-1}" in
    1)
        AUTH_METHOD="sso"
        echo ""
        if $HAS_AWS_CLI; then
            PROFILES="$(aws configure list-profiles 2>/dev/null || true)"
            if [[ -n "$PROFILES" ]]; then
                info "Available AWS profiles:"
                echo ""
                i=1
                declare -a PROFILE_LIST=()
                while IFS= read -r p; do
                    PROFILE_LIST+=("$p")
                    printf "  %d) %s\n" "$i" "$p"
                    ((i++))
                done <<< "$PROFILES"
                echo ""
                printf "Pick a profile number, or press Enter to type a name: "
                read -r profile_pick
                if [[ -n "$profile_pick" ]] && [[ "$profile_pick" =~ ^[0-9]+$ ]]; then
                    idx=$((profile_pick - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#PROFILE_LIST[@]} ]]; then
                        AWS_PROFILE_NAME="${PROFILE_LIST[$idx]}"
                    else
                        warn "Invalid selection."
                        prompt_required "Enter AWS profile name" AWS_PROFILE_NAME
                    fi
                elif [[ -n "$profile_pick" ]]; then
                    AWS_PROFILE_NAME="$profile_pick"
                else
                    prompt_required "Enter AWS profile name" AWS_PROFILE_NAME
                fi
            else
                prompt_required "Enter your AWS SSO profile name" AWS_PROFILE_NAME
            fi
        else
            prompt_required "Enter your AWS SSO profile name" AWS_PROFILE_NAME
        fi
        success "Using AWS profile: $AWS_PROFILE_NAME"

        # Attempt SSO login
        if $HAS_AWS_CLI; then
            echo ""
            if prompt_yes_no "Run 'aws sso login --profile $AWS_PROFILE_NAME' now?"; then
                info "Launching SSO login…"
                aws sso login --profile "$AWS_PROFILE_NAME" || warn "SSO login failed. You can retry manually."
            fi
        fi

        # awsAuthRefresh
        echo ""
        info "Claude Code can automatically refresh SSO tokens via 'awsAuthRefresh'."
        if prompt_yes_no "Enable automatic SSO token refresh in settings.json?"; then
            ENABLE_AUTH_REFRESH=true
            success "awsAuthRefresh will be configured."
        fi
        ;;
    2)
        AUTH_METHOD="keys"
        echo ""
        warn "For security, IAM access keys should NOT be stored in settings.json."
        info "You should configure them via 'aws configure' or by setting environment"
        info "variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) in your shell profile."
        echo ""
        if $HAS_AWS_CLI; then
            if prompt_yes_no "Run 'aws configure' now to set up your access keys?"; then
                aws configure
            fi
        else
            info "After installing the AWS CLI, run 'aws configure' to store your keys."
            info "Alternatively, add to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
            echo ""
            echo "  export AWS_ACCESS_KEY_ID=AKIA..."
            echo "  export AWS_SECRET_ACCESS_KEY=..."
            echo ""
        fi
        ;;
    3)
        AUTH_METHOD="existing"
        echo ""
        if $HAS_AWS_CLI; then
            info "Verifying current credentials…"
            if aws sts get-caller-identity &>/dev/null; then
                CALLER="$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null || echo "unknown")"
                success "Authenticated as: $CALLER"
            else
                warn "Could not verify credentials with 'aws sts get-caller-identity'."
                warn "Make sure your credentials are configured before running Claude Code."
            fi
        else
            warn "Cannot verify credentials without AWS CLI. Proceeding on trust."
        fi
        ;;
    *)
        warn "Invalid choice, defaulting to 'Already configured'."
        AUTH_METHOD="existing"
        ;;
esac

# ═════════════════════════════════════════════════════════════════════════════
# Step 5: AWS Region
# ═════════════════════════════════════════════════════════════════════════════
header "Step 5 / 9 — AWS Region"

# Try to extract region from SSO profile
DEFAULT_REGION="us-east-1"
if [[ -n "$AWS_PROFILE_NAME" ]] && $HAS_AWS_CLI; then
    PROFILE_REGION="$(aws configure get region --profile "$AWS_PROFILE_NAME" 2>/dev/null || true)"
    if [[ -n "$PROFILE_REGION" ]]; then
        DEFAULT_REGION="$PROFILE_REGION"
        info "Detected region from profile '$AWS_PROFILE_NAME': $PROFILE_REGION"
    fi
fi

echo "Common Bedrock regions:"
echo ""
echo "  1) us-east-1      (N. Virginia)"
echo "  2) us-west-2      (Oregon)"
echo "  3) eu-west-1      (Ireland)"
echo "  4) eu-central-1   (Frankfurt)"
echo "  5) ap-northeast-1 (Tokyo)"
echo "  6) ap-southeast-1 (Singapore)"
echo "  7) Custom"
echo ""
printf "Choose [1-7] or press Enter for %s: " "$DEFAULT_REGION"
read -r region_choice

case "${region_choice:-}" in
    1) AWS_REGION="us-east-1" ;;
    2) AWS_REGION="us-west-2" ;;
    3) AWS_REGION="eu-west-1" ;;
    4) AWS_REGION="eu-central-1" ;;
    5) AWS_REGION="ap-northeast-1" ;;
    6) AWS_REGION="ap-southeast-1" ;;
    7)
        prompt_required "Enter AWS region" AWS_REGION
        ;;
    "")
        AWS_REGION="$DEFAULT_REGION"
        ;;
    *)
        # Treat raw input as a region name
        AWS_REGION="$region_choice"
        ;;
esac

success "Using region: $AWS_REGION"

# ═════════════════════════════════════════════════════════════════════════════
# Step 6: Model Selection
# ═════════════════════════════════════════════════════════════════════════════
header "Step 6 / 9 — Model Selection"

discover_models() {
    local profile_flag=""
    if [[ -n "$AWS_PROFILE_NAME" ]]; then
        profile_flag="--profile $AWS_PROFILE_NAME"
    fi

    info "Discovering available inference profiles in ${AWS_REGION}…"
    echo ""

    local raw
    # Fetch both SYSTEM and APPLICATION type profiles
    raw="$(aws bedrock list-inference-profiles \
        --region "$AWS_REGION" \
        $profile_flag \
        --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic') || contains(inferenceProfileId, 'claude')].[inferenceProfileName,inferenceProfileArn,status]" \
        --output text 2>/dev/null || true)"

    local raw_app
    raw_app="$(aws bedrock list-inference-profiles \
        --region "$AWS_REGION" \
        --type APPLICATION \
        $profile_flag \
        --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic') || contains(inferenceProfileId, 'claude')].[inferenceProfileName,inferenceProfileArn,status]" \
        --output text 2>/dev/null || true)"

    # Combine, deduplicate
    local combined
    combined="$(printf "%s\n%s" "$raw" "$raw_app" | sort -u | grep -v '^$' || true)"

    if [[ -z "$combined" ]]; then
        return 1
    fi

    MODEL_NAMES=()
    MODEL_ARNS=()
    local i=1
    while IFS=$'\t' read -r name arn status; do
        MODEL_NAMES+=("$name")
        MODEL_ARNS+=("$arn")
        local status_indicator=""
        if [[ "$status" == "ACTIVE" ]]; then
            status_indicator="${GREEN}ACTIVE${NC}"
        else
            status_indicator="${YELLOW}${status}${NC}"
        fi
        printf "  %2d) %-45s %b\n" "$i" "$name" "$status_indicator"
        ((i++))
    done <<< "$combined"

    return 0
}

MODEL_SELECTED=false

if $HAS_AWS_CLI; then
    echo "  1) Auto-discover available models"
    echo "  2) Enter model ARN manually"
    echo ""
    printf "Choose [1/2]: "
    read -r model_method

    if [[ "${model_method:-1}" == "1" ]]; then
        if discover_models; then
            echo ""
            printf "Select a model number, or enter an ARN: "
            read -r model_pick
            if [[ "$model_pick" =~ ^[0-9]+$ ]]; then
                idx=$((model_pick - 1))
                if [[ $idx -ge 0 && $idx -lt ${#MODEL_ARNS[@]} ]]; then
                    MODEL_ARN="${MODEL_ARNS[$idx]}"
                    success "Selected: ${MODEL_NAMES[$idx]}"
                    MODEL_SELECTED=true
                else
                    warn "Invalid selection."
                fi
            elif [[ "$model_pick" =~ ^arn: ]]; then
                MODEL_ARN="$model_pick"
                MODEL_SELECTED=true
            fi
        else
            warn "Could not discover models. You may not have Bedrock access in $AWS_REGION,"
            warn "or your credentials may not be active yet."
        fi
    fi
fi

if ! $MODEL_SELECTED; then
    echo ""
    info "Enter the full ARN for your inference profile."
    info "Example: arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0"
    echo ""
    prompt_required "Model ARN" MODEL_ARN
fi

# Validate ARN format loosely
if [[ ! "$MODEL_ARN" =~ ^arn: ]]; then
    warn "The value you entered doesn't look like an ARN (expected 'arn:...')."
    warn "Proceeding anyway — double-check settings.json if Claude Code fails to connect."
fi

success "Primary model: $MODEL_ARN"

# Small/fast model
echo ""
info "Claude Code can use a smaller, faster model for lightweight tasks (e.g. Haiku)."
if prompt_yes_no "Configure a small/fast model (ANTHROPIC_SMALL_FAST_MODEL)?" "n"; then
    if $HAS_AWS_CLI && [[ ${#MODEL_ARNS[@]} -gt 0 ]]; then
        echo ""
        info "Pick from discovered models, or enter an ARN:"
        for i in "${!MODEL_NAMES[@]}"; do
            printf "  %2d) %s\n" "$((i + 1))" "${MODEL_NAMES[$i]}"
        done
        echo ""
        printf "Selection or ARN: "
        read -r small_pick
        if [[ "$small_pick" =~ ^[0-9]+$ ]]; then
            idx=$((small_pick - 1))
            if [[ $idx -ge 0 && $idx -lt ${#MODEL_ARNS[@]} ]]; then
                SMALL_FAST_MODEL="${MODEL_ARNS[$idx]}"
            fi
        elif [[ -n "$small_pick" ]]; then
            SMALL_FAST_MODEL="$small_pick"
        fi
    else
        prompt_required "Small/fast model ARN" SMALL_FAST_MODEL
    fi
    if [[ -n "$SMALL_FAST_MODEL" ]]; then
        success "Small/fast model: $SMALL_FAST_MODEL"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Step 7: Write ~/.claude/settings.json
# ═════════════════════════════════════════════════════════════════════════════
header "Step 7 / 9 — Write Settings"

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

mkdir -p "$SETTINGS_DIR"

# Back up existing file
if [[ -f "$SETTINGS_FILE" ]]; then
    BACKUP="$SETTINGS_FILE.bak"
    cp "$SETTINGS_FILE" "$BACKUP"
    success "Backed up existing settings to $BACKUP"
fi

# Determine JSON tool
JSON_TOOL=""
if command -v jq &>/dev/null; then
    JSON_TOOL="jq"
elif command -v python3 &>/dev/null; then
    JSON_TOOL="python3"
else
    JSON_TOOL="none"
fi

merge_with_jq() {
    local existing="{}"
    if [[ -f "$SETTINGS_FILE" ]]; then
        existing="$(cat "$SETTINGS_FILE")"
    fi

    # Build env additions as a JSON object
    local env_json
    env_json="$(jq -n \
        --arg bedrock "1" \
        --arg region "$AWS_REGION" \
        --arg model "$MODEL_ARN" \
        '{ "CLAUDE_CODE_USE_BEDROCK": $bedrock, "AWS_REGION": $region, "ANTHROPIC_MODEL": $model }')"

    if [[ -n "$AWS_PROFILE_NAME" ]]; then
        env_json="$(echo "$env_json" | jq --arg v "$AWS_PROFILE_NAME" '. + { "AWS_PROFILE": $v }')"
    fi
    if [[ -n "$SMALL_FAST_MODEL" ]]; then
        env_json="$(echo "$env_json" | jq --arg v "$SMALL_FAST_MODEL" '. + { "ANTHROPIC_SMALL_FAST_MODEL": $v }')"
    fi

    # Merge env into existing .env (preserving other env vars)
    local result
    result="$(echo "$existing" | jq --argjson newenv "$env_json" '.env = ((.env // {}) + $newenv)')"

    # Add awsAuthRefresh if requested
    if $ENABLE_AUTH_REFRESH && [[ -n "$AWS_PROFILE_NAME" ]]; then
        result="$(echo "$result" | jq --arg profile "$AWS_PROFILE_NAME" \
            '.awsAuthRefresh = "aws sso login --profile " + $profile')"
    fi

    echo "$result" | jq '.' > "$SETTINGS_FILE"
}

merge_with_python() {
    local existing="{}"
    if [[ -f "$SETTINGS_FILE" ]]; then
        existing="$(cat "$SETTINGS_FILE")"
    fi

    python3 -c "
import json, sys

existing = json.loads(sys.argv[1])
enable_auth = sys.argv[2] == 'true'
profile = sys.argv[3]
region = sys.argv[4]
model = sys.argv[5]
aws_profile = sys.argv[6]
small_model = sys.argv[7]

new_env = {
    'CLAUDE_CODE_USE_BEDROCK': '1',
    'AWS_REGION': region,
    'ANTHROPIC_MODEL': model,
}
if aws_profile:
    new_env['AWS_PROFILE'] = aws_profile
if small_model:
    new_env['ANTHROPIC_SMALL_FAST_MODEL'] = small_model

existing.setdefault('env', {})
existing['env'].update(new_env)

if enable_auth and profile:
    existing['awsAuthRefresh'] = 'aws sso login --profile ' + profile

print(json.dumps(existing, indent=2))
" "$existing" "$ENABLE_AUTH_REFRESH" "$AWS_PROFILE_NAME" "$AWS_REGION" "$MODEL_ARN" "$AWS_PROFILE_NAME" "$SMALL_FAST_MODEL" > "$SETTINGS_FILE"
}

merge_fallback() {
    warn "Neither jq nor python3 found. Writing settings.json from scratch."
    warn "Any existing custom settings (statusLine, plugins, etc.) will be lost."
    if [[ -f "$SETTINGS_FILE" ]]; then
        if ! prompt_yes_no "Overwrite $SETTINGS_FILE?"; then
            error "Cannot merge settings without jq or python3. Please install one and re-run."
            exit 1
        fi
    fi

    local auth_line=""
    if $ENABLE_AUTH_REFRESH && [[ -n "$AWS_PROFILE_NAME" ]]; then
        auth_line="  \"awsAuthRefresh\": \"aws sso login --profile $AWS_PROFILE_NAME\","
    fi

    local profile_line=""
    if [[ -n "$AWS_PROFILE_NAME" ]]; then
        profile_line="    \"AWS_PROFILE\": \"$AWS_PROFILE_NAME\","
    fi

    local small_line=""
    if [[ -n "$SMALL_FAST_MODEL" ]]; then
        small_line="    \"ANTHROPIC_SMALL_FAST_MODEL\": \"$SMALL_FAST_MODEL\","
    fi

    cat > "$SETTINGS_FILE" <<JSONEOF
{
$auth_line
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "$AWS_REGION",
    "ANTHROPIC_MODEL": "$MODEL_ARN",
$profile_line
$small_line
    "_placeholder": ""
  }
}
JSONEOF

    # Clean up trailing commas and placeholder — best effort
    if command -v sed &>/dev/null; then
        sed -i.tmp '/"_placeholder"/d' "$SETTINGS_FILE"
        # Remove possible trailing comma before closing brace
        sed -i.tmp -E 'N;s/,\n(\s*\})/\n\1/;P;D' "$SETTINGS_FILE"
        rm -f "$SETTINGS_FILE.tmp"
    fi
}

info "Updating $SETTINGS_FILE …"
echo ""

case "$JSON_TOOL" in
    jq)
        info "Using jq for JSON merge."
        merge_with_jq
        ;;
    python3)
        info "Using python3 for JSON merge."
        merge_with_python
        ;;
    none)
        merge_fallback
        ;;
esac

success "Settings written to $SETTINGS_FILE"

# ═════════════════════════════════════════════════════════════════════════════
# Step 8: Verify
# ═════════════════════════════════════════════════════════════════════════════
header "Step 8 / 9 — Verify"

if $HAS_AWS_CLI; then
    info "Running a lightweight Bedrock API check…"
    VERIFY_FLAGS="--region $AWS_REGION --max-results 1"
    if [[ -n "$AWS_PROFILE_NAME" ]]; then
        VERIFY_FLAGS="$VERIFY_FLAGS --profile $AWS_PROFILE_NAME"
    fi
    if aws bedrock list-inference-profiles $VERIFY_FLAGS &>/dev/null; then
        success "AWS Bedrock API responded successfully in $AWS_REGION."
    else
        warn "Could not reach Bedrock in $AWS_REGION."
        echo ""
        info "Common causes:"
        info "  • Your SSO session may have expired — run: aws sso login --profile $AWS_PROFILE_NAME"
        info "  • Your IAM role/user may not have bedrock:ListInferenceProfiles permission."
        info "  • The region may not have Bedrock enabled for your account."
    fi
else
    warn "Skipping verification (AWS CLI not installed)."
fi

# ═════════════════════════════════════════════════════════════════════════════
# Step 9: Summary
# ═════════════════════════════════════════════════════════════════════════════
header "Step 9 / 9 — Summary"

printf "Configuration written to %s%s%s:\n" "$BOLD" "$SETTINGS_FILE" "$NC"
echo ""

if command -v cat &>/dev/null; then
    cat "$SETTINGS_FILE"
fi

echo ""
echo "────────────────────────────────────────────────────────────────"
echo ""
success "Setup complete!"
echo ""
info "Next steps:"
info "  1. Run ${BOLD}claude${NC} to start Claude Code."
info "  2. If you see authentication errors, verify your AWS credentials."
echo ""
info "Troubleshooting:"
info "  • SSO expired?       aws sso login --profile <PROFILE>"
info "  • Wrong region?      Edit AWS_REGION in $SETTINGS_FILE"
info "  • Wrong model?       Edit ANTHROPIC_MODEL in $SETTINGS_FILE"
info "  • Reset everything:  Restore from $SETTINGS_FILE.bak"
echo ""
