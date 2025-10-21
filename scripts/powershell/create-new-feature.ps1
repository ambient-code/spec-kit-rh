#!/usr/bin/env pwsh
# Create a new feature
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ShortName,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FeatureDescription
)
$ErrorActionPreference = 'Stop'

# Show help if requested
if ($Help) {
    Write-Host "Usage: ./create-new-feature.ps1 [-Json] [-ShortName <name>] <feature description>"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Json               Output in JSON format"
    Write-Host "  -ShortName <name>   Provide a custom branch name (descriptive, kebab-case)"
    Write-Host "  -Help               Show this help message"
    Write-Host ""
    Write-Host "Branch naming:"
    Write-Host "  - Any descriptive name works: user-auth, payment-fix, oauth-integration"
    Write-Host "  - Numbers are optional: 001-user-auth or just user-auth"
    Write-Host "  - Branch name becomes the specs/ folder name"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  ./create-new-feature.ps1 'Add user authentication system' -ShortName 'user-auth'"
    Write-Host "  ./create-new-feature.ps1 'Implement OAuth2 integration for API'"
    Write-Host "  ./create-new-feature.ps1 -ShortName '001-payment-fix' 'Fix payment processing bug'"
    exit 0
}

# Check if feature description provided
if (-not $FeatureDescription -or $FeatureDescription.Count -eq 0) {
    Write-Error "Usage: ./create-new-feature.ps1 [-Json] [-ShortName <name>] <feature description>"
    exit 1
}

$featureDesc = ($FeatureDescription -join ' ').Trim()

# Resolve repository root. Prefer git information when available, but fall back
# to searching for repository markers so the workflow still functions in repositories that
# were initialized with --no-git.
function Find-RepositoryRoot {
    param(
        [string]$StartDir,
        [string[]]$Markers = @('.git', '.specify')
    )
    $current = Resolve-Path $StartDir
    while ($true) {
        foreach ($marker in $Markers) {
            if (Test-Path (Join-Path $current $marker)) {
                return $current
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) {
            # Reached filesystem root without finding markers
            return $null
        }
        $current = $parent
    }
}
$fallbackRoot = (Find-RepositoryRoot -StartDir $PSScriptRoot)
if (-not $fallbackRoot) {
    Write-Error "Error: Could not determine repository root. Please run this script from within the repository."
    exit 1
}

try {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) {
        $hasGit = $true
    } else {
        throw "Git not available"
    }
} catch {
    $repoRoot = $fallbackRoot
    $hasGit = $false
}

Set-Location $repoRoot

$specsDir = Join-Path $repoRoot 'specs'
New-Item -ItemType Directory -Path $specsDir -Force | Out-Null

# Feature numbering is now optional
# If user wants numbers, they can include them in the ShortName (e.g., -ShortName "001-user-auth")
$featureNum = ""

# Function to generate branch name with stop word filtering and length filtering
function Get-BranchName {
    param([string]$Description)
    
    # Common stop words to filter out
    $stopWords = @(
        'i', 'a', 'an', 'the', 'to', 'for', 'of', 'in', 'on', 'at', 'by', 'with', 'from',
        'is', 'are', 'was', 'were', 'be', 'been', 'being', 'have', 'has', 'had',
        'do', 'does', 'did', 'will', 'would', 'should', 'could', 'can', 'may', 'might', 'must', 'shall',
        'this', 'that', 'these', 'those', 'my', 'your', 'our', 'their',
        'want', 'need', 'add', 'get', 'set'
    )
    
    # Convert to lowercase and extract words (alphanumeric only)
    $cleanName = $Description.ToLower() -replace '[^a-z0-9\s]', ' '
    $words = $cleanName -split '\s+' | Where-Object { $_ }
    
    # Filter words: remove stop words and words shorter than 3 chars (unless they're uppercase acronyms in original)
    $meaningfulWords = @()
    foreach ($word in $words) {
        # Skip stop words
        if ($stopWords -contains $word) { continue }
        
        # Keep words that are length >= 3 OR appear as uppercase in original (likely acronyms)
        if ($word.Length -ge 3) {
            $meaningfulWords += $word
        } elseif ($Description -match "\b$($word.ToUpper())\b") {
            # Keep short words if they appear as uppercase in original (likely acronyms)
            $meaningfulWords += $word
        }
    }
    
    # If we have meaningful words, use first 3-4 of them
    if ($meaningfulWords.Count -gt 0) {
        $maxWords = if ($meaningfulWords.Count -eq 4) { 4 } else { 3 }
        $result = ($meaningfulWords | Select-Object -First $maxWords) -join '-'
        return $result
    } else {
        # Fallback to original logic if no meaningful words found
        $result = $Description.ToLower() -replace '[^a-z0-9]', '-' -replace '-{2,}', '-' -replace '^-', '' -replace '-$', ''
        $fallbackWords = ($result -split '-') | Where-Object { $_ } | Select-Object -First 3
        return [string]::Join('-', $fallbackWords)
    }
}

# Generate branch name
if ($ShortName) {
    # Use provided short name, just clean it up
    $branchName = $ShortName.ToLower() -replace '[^a-z0-9]', '-' -replace '-{2,}', '-' -replace '^-', '' -replace '-$', ''
} else {
    # Generate from description with smart filtering
    $branchName = Get-BranchName -Description $featureDesc
}

# GitHub enforces a 244-byte limit on branch names
# Validate and truncate if necessary
$maxBranchLength = 244
if ($branchName.Length -gt $maxBranchLength) {
    # Truncate at word boundary if possible
    $truncatedName = $branchName.Substring(0, $maxBranchLength)
    # Remove trailing hyphen if truncation created one
    $truncatedName = $truncatedName -replace '-$', ''
    
    $originalBranchName = $branchName
    $branchName = $truncatedName
    
    Write-Warning "[specify] Branch name exceeded GitHub's 244-byte limit"
    Write-Warning "[specify] Original: $originalBranchName ($($originalBranchName.Length) bytes)"
    Write-Warning "[specify] Truncated to: $branchName ($($branchName.Length) bytes)"
}

# Check if we're already on a feature branch with existing folder
$currentBranch = ""
if ($hasGit) {
    try {
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $currentBranch = "" }
    } catch {
        $currentBranch = ""
    }
}

# Check if a folder already exists for the current branch
$currentBranchDir = Join-Path $specsDir $currentBranch
if ($currentBranch -and (Test-Path -Path $currentBranchDir -PathType Container)) {
    # Use existing branch and folder
    $branchName = $currentBranch
    $featureDir = $currentBranchDir
    Write-Warning "[specify] Using existing branch: $currentBranch"
    Write-Warning "[specify] Using existing feature directory: $featureDir"
} elseif ($currentBranch -and 
          $currentBranch -ne "main" -and 
          $currentBranch -ne "master" -and 
          $currentBranch -ne "develop") {
    # Already on a feature branch, just create the folder
    $branchName = $currentBranch
    $featureDir = Join-Path $specsDir $currentBranch
    New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
    Write-Warning "[specify] Using existing branch: $currentBranch"
    Write-Warning "[specify] Created feature directory: $featureDir"
} else {
    # Create new branch and folder
    if ($hasGit) {
        try {
            git checkout -b $branchName | Out-Null
            Write-Warning "[specify] Created new branch: $branchName"
        } catch {
            Write-Warning "Failed to create git branch: $branchName"
        }
    } else {
        Write-Warning "[specify] Warning: Git repository not detected; skipped branch creation for $branchName"
    }
    $featureDir = Join-Path $specsDir $branchName
    New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
    Write-Warning "[specify] Created feature directory: $featureDir"
}

$template = Join-Path $repoRoot '.specify/templates/spec-template.md'
$specFile = Join-Path $featureDir 'spec.md'
if (-not (Test-Path $specFile)) {
    if (Test-Path $template) { 
        Copy-Item $template $specFile -Force 
    } else { 
        New-Item -ItemType File -Path $specFile | Out-Null 
    }
    Write-Warning "[specify] Created spec file: $specFile"
} else {
    Write-Warning "[specify] Using existing spec file: $specFile"
}

# Set the SPECIFY_FEATURE environment variable for the current session
$env:SPECIFY_FEATURE = $branchName

if ($Json) {
    $obj = [PSCustomObject]@{ 
        BRANCH_NAME = $branchName
        SPEC_FILE = $specFile
    }
    $obj | ConvertTo-Json -Compress
} else {
    Write-Output "BRANCH_NAME: $branchName"
    Write-Output "SPEC_FILE: $specFile"
    Write-Output "SPECIFY_FEATURE environment variable set to: $branchName"
}

