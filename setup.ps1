#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code + AWS Bedrock — Interactive Setup Script (Windows / PowerShell)

.DESCRIPTION
    Guides you through installing prerequisites, choosing an authentication
    method, selecting a Bedrock model, and writing ~/.claude/settings.json.

.NOTES
    If you see "cannot be loaded because running scripts is disabled", run:
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
    Then re-run this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Color helpers ────────────────────────────────────────────────────────────
function Write-Info    { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Header  { param([string]$Msg) Write-Host "`n── $Msg ──`n" -ForegroundColor Magenta }

function Prompt-Default {
    param([string]$Prompt, [string]$Default)
    $input = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input
}

function Prompt-Required {
    param([string]$Prompt)
    do {
        $val = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($val)) { Write-Warn "This field is required." }
    } while ([string]::IsNullOrWhiteSpace($val))
    return $val
}

function Prompt-YesNo {
    param([string]$Prompt, [string]$Default = 'y')
    if ($Default -eq 'y') { $suffix = '[Y/n]' } else { $suffix = '[y/N]' }
    $yn = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($yn)) { $yn = $Default }
    return $yn -match '^[Yy]'
}

# ── State ────────────────────────────────────────────────────────────────────
$AuthMethod       = ''
$AwsProfileName   = ''
$AwsRegion        = ''
$ModelArn         = ''
$SmallFastModel   = ''
$EnableAuthRefresh = $false
$HasAwsCli        = $false

# ═════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '╔═══════════════════════════════════════════════════════════════╗'
Write-Host '║        Claude Code + AWS Bedrock — Setup Wizard             ║'
Write-Host '╚═══════════════════════════════════════════════════════════════╝'
Write-Host ''
Write-Info 'This script will walk you through setting up Claude Code to'
Write-Info 'use AWS Bedrock as its model provider.'
Write-Host ''

# ═════════════════════════════════════════════════════════════════════════════
# Step 1: Node.js >= 18
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 1 / 9 — Node.js'

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVersion = & node --version
    $major = [int]($nodeVersion -replace '^v(\d+).*', '$1')
    if ($major -ge 18) {
        Write-Ok "Node.js $nodeVersion detected (>= 18 required)."
    } else {
        Write-Err "Node.js $nodeVersion is too old. Version 18+ is required."
        Write-Info 'Install via winget:  winget install OpenJS.NodeJS.LTS'
        Write-Info 'Or visit: https://nodejs.org/'
        exit 1
    }
} else {
    Write-Err 'Node.js is not installed. Version 18+ is required.'
    Write-Info 'Install via winget:  winget install OpenJS.NodeJS.LTS'
    Write-Info 'Or visit: https://nodejs.org/'
    exit 1
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 2: AWS CLI
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 2 / 9 — AWS CLI'

$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if ($awsCmd) {
    $awsVer = & aws --version 2>&1 | Select-Object -First 1
    Write-Ok "AWS CLI detected: $awsVer"
    $HasAwsCli = $true
} else {
    Write-Warn 'AWS CLI is not installed.'
    Write-Info 'The script can still write your config, but verification will be skipped.'
    Write-Info 'Install via winget:  winget install Amazon.AWSCLI'
    Write-Info 'Or visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'
    Write-Host ''
    if (-not (Prompt-YesNo 'Continue without AWS CLI?')) {
        Write-Info 'Please install the AWS CLI and re-run this script.'
        exit 0
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 3: Claude Code
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 3 / 9 — Claude Code'

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $claudeVer = & claude --version 2>$null
    if (-not $claudeVer) { $claudeVer = 'unknown' }
    Write-Ok "Claude Code detected: $claudeVer"
} else {
    Write-Warn 'Claude Code is not installed.'
    Write-Host ''
    if (Prompt-YesNo 'Install Claude Code now via npm?') {
        Write-Info 'Running: npm install -g @anthropic-ai/claude-code'
        try {
            & npm install -g @anthropic-ai/claude-code
            Write-Ok 'Claude Code installed.'
        } catch {
            Write-Warn 'npm install failed. You may need to run this terminal as Administrator.'
            Write-Warn 'Continuing without Claude Code installed.'
        }
    } else {
        Write-Info 'You can install it later:  npm install -g @anthropic-ai/claude-code'
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 4: AWS Authentication
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 4 / 9 — AWS Authentication'

Write-Host 'How are you authenticating with AWS?'
Write-Host ''
Write-Host '  1) AWS SSO / Identity Center  (recommended)'
Write-Host '  2) IAM access keys'
Write-Host '  3) Already configured (env vars, instance role, etc.)'
Write-Host ''
$authChoice = Read-Host 'Choose [1/2/3]'
if ([string]::IsNullOrWhiteSpace($authChoice)) { $authChoice = '1' }

switch ($authChoice) {
    '1' {
        $AuthMethod = 'sso'
        Write-Host ''
        if ($HasAwsCli) {
            $profiles = @()
            try { $profiles = @(& aws configure list-profiles 2>$null) } catch {}
            if ($profiles.Count -gt 0) {
                Write-Info 'Available AWS profiles:'
                Write-Host ''
                for ($i = 0; $i -lt $profiles.Count; $i++) {
                    Write-Host "  $($i+1)) $($profiles[$i])"
                }
                Write-Host ''
                $pick = Read-Host 'Pick a profile number, or press Enter to type a name'
                if ($pick -match '^\d+$') {
                    $idx = [int]$pick - 1
                    if ($idx -ge 0 -and $idx -lt $profiles.Count) {
                        $AwsProfileName = $profiles[$idx]
                    } else {
                        Write-Warn 'Invalid selection.'
                        $AwsProfileName = Prompt-Required 'Enter AWS profile name'
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($pick)) {
                    $AwsProfileName = $pick
                } else {
                    $AwsProfileName = Prompt-Required 'Enter AWS profile name'
                }
            } else {
                $AwsProfileName = Prompt-Required 'Enter your AWS SSO profile name'
            }
        } else {
            $AwsProfileName = Prompt-Required 'Enter your AWS SSO profile name'
        }
        Write-Ok "Using AWS profile: $AwsProfileName"

        if ($HasAwsCli) {
            Write-Host ''
            if (Prompt-YesNo "Run 'aws sso login --profile $AwsProfileName' now?") {
                Write-Info 'Launching SSO login...'
                try { & aws sso login --profile $AwsProfileName } catch { Write-Warn 'SSO login failed. You can retry manually.' }
            }
        }

        Write-Host ''
        Write-Info "Claude Code can automatically refresh SSO tokens via 'awsAuthRefresh'."
        if (Prompt-YesNo 'Enable automatic SSO token refresh in settings.json?') {
            $EnableAuthRefresh = $true
            Write-Ok 'awsAuthRefresh will be configured.'
        }
    }
    '2' {
        $AuthMethod = 'keys'
        Write-Host ''
        Write-Warn 'For security, IAM access keys should NOT be stored in settings.json.'
        Write-Info "You should configure them via 'aws configure' or by setting environment"
        Write-Info 'variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY).'
        Write-Host ''
        if ($HasAwsCli) {
            if (Prompt-YesNo "Run 'aws configure' now to set up your access keys?") {
                & aws configure
            }
        } else {
            Write-Info "After installing the AWS CLI, run 'aws configure' to store your keys."
            Write-Info 'Alternatively, set these environment variables:'
            Write-Host ''
            Write-Host '  $env:AWS_ACCESS_KEY_ID = "AKIA..."'
            Write-Host '  $env:AWS_SECRET_ACCESS_KEY = "..."'
            Write-Host ''
        }
    }
    '3' {
        $AuthMethod = 'existing'
        Write-Host ''
        if ($HasAwsCli) {
            Write-Info 'Verifying current credentials...'
            try {
                $caller = & aws sts get-caller-identity --output text --query 'Arn' 2>$null
                Write-Ok "Authenticated as: $caller"
            } catch {
                Write-Warn "Could not verify credentials with 'aws sts get-caller-identity'."
                Write-Warn 'Make sure your credentials are configured before running Claude Code.'
            }
        } else {
            Write-Warn 'Cannot verify credentials without AWS CLI. Proceeding on trust.'
        }
    }
    default {
        Write-Warn "Invalid choice, defaulting to 'Already configured'."
        $AuthMethod = 'existing'
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 5: AWS Region
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 5 / 9 — AWS Region'

$DefaultRegion = 'us-east-1'
if ($AwsProfileName -and $HasAwsCli) {
    try {
        $profileRegion = & aws configure get region --profile $AwsProfileName 2>$null
        if ($profileRegion) {
            $DefaultRegion = $profileRegion.Trim()
            Write-Info "Detected region from profile '$AwsProfileName': $DefaultRegion"
        }
    } catch {}
}

Write-Host 'Common Bedrock regions:'
Write-Host ''
Write-Host '  1) us-east-1      (N. Virginia)'
Write-Host '  2) us-west-2      (Oregon)'
Write-Host '  3) eu-west-1      (Ireland)'
Write-Host '  4) eu-central-1   (Frankfurt)'
Write-Host '  5) ap-northeast-1 (Tokyo)'
Write-Host '  6) ap-southeast-1 (Singapore)'
Write-Host '  7) Custom'
Write-Host ''
$regionChoice = Read-Host "Choose [1-7] or press Enter for $DefaultRegion"

switch ($regionChoice) {
    '1' { $AwsRegion = 'us-east-1' }
    '2' { $AwsRegion = 'us-west-2' }
    '3' { $AwsRegion = 'eu-west-1' }
    '4' { $AwsRegion = 'eu-central-1' }
    '5' { $AwsRegion = 'ap-northeast-1' }
    '6' { $AwsRegion = 'ap-southeast-1' }
    '7' { $AwsRegion = Prompt-Required 'Enter AWS region' }
    ''  { $AwsRegion = $DefaultRegion }
    default { $AwsRegion = $regionChoice }
}

Write-Ok "Using region: $AwsRegion"

# ═════════════════════════════════════════════════════════════════════════════
# Step 6: Model Selection
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 6 / 9 — Model Selection'

$ModelNames = @()
$ModelArns  = @()
$ModelSelected = $false

function Discover-Models {
    $profileFlag = @()
    if ($AwsProfileName) { $profileFlag = @('--profile', $AwsProfileName) }

    Write-Info "Discovering available inference profiles in $AwsRegion..."
    Write-Host ''

    $raw = @()
    try {
        $jsonRaw = & aws bedrock list-inference-profiles `
            --region $AwsRegion @profileFlag `
            --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic') || contains(inferenceProfileId, 'claude')].[inferenceProfileName,inferenceProfileArn,status]" `
            --output json 2>$null
        if ($jsonRaw) { $raw += ($jsonRaw | ConvertFrom-Json) }
    } catch {}

    try {
        $jsonApp = & aws bedrock list-inference-profiles `
            --region $AwsRegion --type APPLICATION @profileFlag `
            --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic') || contains(inferenceProfileId, 'claude')].[inferenceProfileName,inferenceProfileArn,status]" `
            --output json 2>$null
        if ($jsonApp) { $raw += ($jsonApp | ConvertFrom-Json) }
    } catch {}

    # Deduplicate by ARN
    $seen = @{}
    $unique = @()
    foreach ($entry in $raw) {
        $arn = $entry[1]
        if (-not $seen.ContainsKey($arn)) {
            $seen[$arn] = $true
            $unique += ,@($entry)
        }
    }

    if ($unique.Count -eq 0) { return $false }

    $script:ModelNames = @()
    $script:ModelArns  = @()

    for ($i = 0; $i -lt $unique.Count; $i++) {
        $name   = $unique[$i][0]
        $arn    = $unique[$i][1]
        $status = $unique[$i][2]
        $script:ModelNames += $name
        $script:ModelArns  += $arn
        $statusColor = if ($status -eq 'ACTIVE') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,2}) {1,-45} " -f ($i+1), $name) -NoNewline
        Write-Host $status -ForegroundColor $statusColor
    }

    return $true
}

if ($HasAwsCli) {
    Write-Host '  1) Auto-discover available models'
    Write-Host '  2) Enter model ARN manually'
    Write-Host ''
    $modelMethod = Read-Host 'Choose [1/2]'
    if ([string]::IsNullOrWhiteSpace($modelMethod)) { $modelMethod = '1' }

    if ($modelMethod -eq '1') {
        if (Discover-Models) {
            Write-Host ''
            $modelPick = Read-Host 'Select a model number, or enter an ARN'
            if ($modelPick -match '^\d+$') {
                $idx = [int]$modelPick - 1
                if ($idx -ge 0 -and $idx -lt $ModelArns.Count) {
                    $ModelArn = $ModelArns[$idx]
                    Write-Ok "Selected: $($ModelNames[$idx])"
                    $ModelSelected = $true
                } else {
                    Write-Warn 'Invalid selection.'
                }
            } elseif ($modelPick -match '^arn:') {
                $ModelArn = $modelPick
                $ModelSelected = $true
            }
        } else {
            Write-Warn "Could not discover models. You may not have Bedrock access in $AwsRegion,"
            Write-Warn 'or your credentials may not be active yet.'
        }
    }
}

if (-not $ModelSelected) {
    Write-Host ''
    Write-Info 'Enter the full ARN for your inference profile.'
    Write-Info 'Example: arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0'
    Write-Host ''
    $ModelArn = Prompt-Required 'Model ARN'
}

if ($ModelArn -notmatch '^arn:') {
    Write-Warn "The value you entered doesn't look like an ARN (expected 'arn:...')."
    Write-Warn 'Proceeding anyway — double-check settings.json if Claude Code fails to connect.'
}

Write-Ok "Primary model: $ModelArn"

# Small/fast model
Write-Host ''
Write-Info 'Claude Code can use a smaller, faster model for lightweight tasks (e.g. Haiku).'
if (Prompt-YesNo 'Configure a small/fast model (ANTHROPIC_SMALL_FAST_MODEL)?' 'n') {
    if ($HasAwsCli -and $ModelArns.Count -gt 0) {
        Write-Host ''
        Write-Info 'Pick from discovered models, or enter an ARN:'
        for ($i = 0; $i -lt $ModelNames.Count; $i++) {
            Write-Host "  $($i+1)) $($ModelNames[$i])"
        }
        Write-Host ''
        $smallPick = Read-Host 'Selection or ARN'
        if ($smallPick -match '^\d+$') {
            $idx = [int]$smallPick - 1
            if ($idx -ge 0 -and $idx -lt $ModelArns.Count) {
                $SmallFastModel = $ModelArns[$idx]
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($smallPick)) {
            $SmallFastModel = $smallPick
        }
    } else {
        $SmallFastModel = Prompt-Required 'Small/fast model ARN'
    }
    if ($SmallFastModel) {
        Write-Ok "Small/fast model: $SmallFastModel"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 7: Write settings.json
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 7 / 9 — Write Settings'

$settingsDir  = Join-Path $env:USERPROFILE '.claude'
$settingsFile = Join-Path $settingsDir 'settings.json'

if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

# Back up existing file
if (Test-Path $settingsFile) {
    $backup = "$settingsFile.bak"
    Copy-Item $settingsFile $backup -Force
    Write-Ok "Backed up existing settings to $backup"
}

# Load or create settings object
$settings = [ordered]@{}
if (Test-Path $settingsFile) {
    try {
        $raw = Get-Content $settingsFile -Raw
        $parsed = $raw | ConvertFrom-Json
        # Convert PSObject to ordered hashtable
        foreach ($prop in $parsed.PSObject.Properties) {
            $settings[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Warn 'Could not parse existing settings.json, starting fresh.'
    }
}

# Ensure env block exists
if (-not $settings.Contains('env')) {
    $settings['env'] = [ordered]@{}
}

# If env is a PSObject, convert to hashtable
if ($settings['env'] -is [PSCustomObject]) {
    $envHash = [ordered]@{}
    foreach ($prop in $settings['env'].PSObject.Properties) {
        $envHash[$prop.Name] = $prop.Value
    }
    $settings['env'] = $envHash
}

# Set env values
$settings['env']['CLAUDE_CODE_USE_BEDROCK'] = '1'
$settings['env']['AWS_REGION']              = $AwsRegion
$settings['env']['ANTHROPIC_MODEL']         = $ModelArn

if ($AwsProfileName) {
    $settings['env']['AWS_PROFILE'] = $AwsProfileName
}

if ($SmallFastModel) {
    $settings['env']['ANTHROPIC_SMALL_FAST_MODEL'] = $SmallFastModel
}

# awsAuthRefresh
if ($EnableAuthRefresh -and $AwsProfileName) {
    $settings['awsAuthRefresh'] = "aws sso login --profile $AwsProfileName"
}

# Write JSON
$json = $settings | ConvertTo-Json -Depth 10
$json | Set-Content $settingsFile -Encoding UTF8

Write-Ok "Settings written to $settingsFile"

# ═════════════════════════════════════════════════════════════════════════════
# Step 8: Verify
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 8 / 9 — Verify'

if ($HasAwsCli) {
    Write-Info 'Running a lightweight Bedrock API check...'
    $verifyArgs = @('bedrock', 'list-inference-profiles', '--region', $AwsRegion, '--max-results', '1')
    if ($AwsProfileName) { $verifyArgs += @('--profile', $AwsProfileName) }
    try {
        & aws @verifyArgs 2>$null | Out-Null
        Write-Ok "AWS Bedrock API responded successfully in $AwsRegion."
    } catch {
        Write-Warn "Could not reach Bedrock in $AwsRegion."
        Write-Host ''
        Write-Info 'Common causes:'
        Write-Info "  - Your SSO session may have expired — run: aws sso login --profile $AwsProfileName"
        Write-Info '  - Your IAM role/user may not have bedrock:ListInferenceProfiles permission.'
        Write-Info '  - The region may not have Bedrock enabled for your account.'
    }
} else {
    Write-Warn 'Skipping verification (AWS CLI not installed).'
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 9: Summary
# ═════════════════════════════════════════════════════════════════════════════
Write-Header 'Step 9 / 9 — Summary'

Write-Host "Configuration written to $settingsFile`:"
Write-Host ''
Get-Content $settingsFile
Write-Host ''
Write-Host '────────────────────────────────────────────────────────────────'
Write-Host ''
Write-Ok 'Setup complete!'
Write-Host ''
Write-Info 'Next steps:'
Write-Info '  1. Run "claude" to start Claude Code.'
Write-Info '  2. If you see authentication errors, verify your AWS credentials.'
Write-Host ''
Write-Info 'Troubleshooting:'
Write-Info '  - SSO expired?       aws sso login --profile <PROFILE>'
Write-Info "  - Wrong region?      Edit AWS_REGION in $settingsFile"
Write-Info "  - Wrong model?       Edit ANTHROPIC_MODEL in $settingsFile"
Write-Info "  - Reset everything:  Restore from $settingsFile.bak"
Write-Host ''
