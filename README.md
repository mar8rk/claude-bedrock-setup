# Claude Code + AWS Bedrock Setup

Guided setup scripts for using [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with AWS Bedrock as the model provider.

## Prerequisites

| Requirement | Minimum Version | Check |
|---|---|---|
| Node.js | 18+ | `node --version` |
| AWS CLI | v2 (recommended) | `aws --version` |
| Bedrock access | Enabled in your AWS account for the target region | AWS Console → Bedrock → Model access |

You also need an AWS account with Bedrock inference profile(s) provisioned or access to cross-region system profiles for Anthropic Claude models.

## Quick Start

**macOS / Linux:**

```bash
bash setup.sh
```

**Windows (PowerShell):**

```powershell
# If you get a script execution error, run this first:
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

.\setup.ps1
```

## What the Script Does

1. **Checks Node.js** — verifies version 18+ is installed.
2. **Checks AWS CLI** — non-fatal; verification is skipped if missing.
3. **Checks Claude Code** — offers to install via `npm install -g @anthropic-ai/claude-code`.
4. **Configures AWS authentication** — SSO login, IAM access keys, or existing credentials.
5. **Selects AWS region** — defaults to `us-east-1`, offers common Bedrock regions.
6. **Selects model** — auto-discovers available inference profiles via AWS CLI, or accepts a manual ARN.
7. **Writes `~/.claude/settings.json`** — merges Bedrock configuration into your existing settings (never overwrites).
8. **Verifies connectivity** — runs a lightweight Bedrock API call.
9. **Prints summary** — shows final config and next steps.

## Manual Setup

If you prefer to configure everything by hand:

### 1. Install dependencies

```bash
# Node.js 18+
brew install node          # macOS
# or: winget install OpenJS.NodeJS.LTS  (Windows)

# AWS CLI v2
brew install awscli        # macOS
# or: winget install Amazon.AWSCLI      (Windows)

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### 2. Configure AWS credentials

**Option A — SSO / Identity Center (recommended):**

```bash
aws configure sso
# Follow the prompts, then:
aws sso login --profile YOUR_PROFILE
```

**Option B — IAM access keys:**

```bash
aws configure
# Enter your Access Key ID and Secret Access Key
```

### 3. Write `~/.claude/settings.json`

Create or edit `~/.claude/settings.json` (or `%USERPROFILE%\.claude\settings.json` on Windows):

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1",
    "AWS_PROFILE": "your-sso-profile",
    "ANTHROPIC_MODEL": "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0",
    "ANTHROPIC_SMALL_FAST_MODEL": "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-haiku-3-20250616-v1:0"
  },
  "awsAuthRefresh": "aws sso login --profile your-sso-profile"
}
```

Adjust the values:

| Field | Description |
|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | Must be `"1"` to enable Bedrock provider. |
| `AWS_REGION` | The region where your inference profiles live. |
| `AWS_PROFILE` | Your AWS CLI named profile (SSO users). Omit if using env vars or instance roles. |
| `ANTHROPIC_MODEL` | Full ARN of the inference profile for the primary model. |
| `ANTHROPIC_SMALL_FAST_MODEL` | (Optional) ARN for a smaller/faster model used for lightweight tasks. |
| `awsAuthRefresh` | (Optional, top-level) Command Claude Code runs to refresh expired SSO tokens. |

### 4. Verify

```bash
aws bedrock list-inference-profiles --region us-east-1 --max-results 1
```

### 5. Launch

```bash
claude
```

## Environment Variables Reference

All variables are set inside the `env` block of `~/.claude/settings.json`. Claude Code reads them automatically.

| Variable | Required | Description |
|---|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | Yes | Set to `"1"` to use Bedrock as the model provider. |
| `AWS_REGION` | Yes | AWS region for Bedrock API calls (e.g. `us-east-1`). |
| `ANTHROPIC_MODEL` | Yes | Full ARN of the Bedrock inference profile for the primary model. |
| `AWS_PROFILE` | No | AWS CLI named profile. Required for SSO users. |
| `ANTHROPIC_SMALL_FAST_MODEL` | No | ARN for a smaller model used for fast/lightweight tasks (e.g. Haiku). |

### Top-level settings

| Key | Required | Description |
|---|---|---|
| `awsAuthRefresh` | No | Shell command to refresh AWS credentials. Runs when Bedrock returns an auth error. Useful for SSO: `"aws sso login --profile my-profile"`. |

## IAM Policy for Administrators

Grant this policy to users or roles that need to use Claude Code with Bedrock. Adjust the `Resource` ARNs to match your account and region.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvokeModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*",
        "arn:aws:bedrock:*::foundation-model/*"
      ]
    },
    {
      "Sid": "BedrockListProfiles",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }
  ]
}
```

**Notes:**
- The wildcard `*` in resources is intentional — inference profile ARNs vary by region and account. Narrow these to specific ARNs if your security policy requires it.
- `bedrock:ListInferenceProfiles` is used by the setup script for auto-discovery. It can be omitted if users always enter ARNs manually.
- `bedrock:GetInferenceProfile` is optional but useful for validation.

## Troubleshooting

### "Could not connect to Bedrock" / model not found

- Confirm `ANTHROPIC_MODEL` in `settings.json` is a valid, full ARN (starts with `arn:aws:bedrock:`).
- Confirm the inference profile exists in the region specified by `AWS_REGION`.
- Run `aws bedrock list-inference-profiles --region <REGION>` to see available profiles.

### "ExpiredTokenException" / SSO session expired

- Run `aws sso login --profile <PROFILE>` to refresh your session.
- If you configured `awsAuthRefresh` in `settings.json`, Claude Code should do this automatically on auth failure.

### "AccessDeniedException"

- Your IAM user/role is missing Bedrock permissions. Ask your administrator to attach the policy from the [IAM Policy](#iam-policy-for-administrators) section.
- Check that the inference profile ARN in your policy matches the one in `settings.json`.

### Claude Code not found after install

- Make sure the npm global bin directory is in your `PATH`.
- Run `npm bin -g` to find the directory, then add it to your shell profile.
- If using nvm, ensure the correct Node.js version is active: `nvm use --lts`.

### Wrong region

- Edit `AWS_REGION` in `~/.claude/settings.json`.
- Bedrock model availability varies by region. Not all models are available everywhere.

### settings.json syntax error

- Restore from backup: `cp ~/.claude/settings.json.bak ~/.claude/settings.json`
- Validate JSON: `cat ~/.claude/settings.json | python3 -m json.tool`

### Script fails with "permission denied"

- **macOS/Linux:** Run `chmod +x setup.sh` then `bash setup.sh`.
- **Windows:** Run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` first.

## Uninstall / Reset

**Revert settings.json to pre-setup state:**

```bash
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

**Remove Bedrock config only (keep other settings):**

Edit `~/.claude/settings.json` and remove the Bedrock-related keys from the `env` block (`CLAUDE_CODE_USE_BEDROCK`, `AWS_REGION`, `ANTHROPIC_MODEL`, `AWS_PROFILE`, `ANTHROPIC_SMALL_FAST_MODEL`) and the top-level `awsAuthRefresh` key.

**Uninstall Claude Code:**

```bash
npm uninstall -g @anthropic-ai/claude-code
```

**Remove all Claude Code data:**

```bash
rm -rf ~/.claude
```
