$ErrorActionPreference = "Stop"

$repo = git rev-parse --show-toplevel
if (-not $repo) { throw "not inside a git repository" }

$source = Join-Path $repo "scripts/hooks/pre-commit"
$target = Join-Path $repo ".git/hooks/pre-commit"

Copy-Item $source $target -Force
Write-Host "installed pre-commit hook -> $target"
Write-Host "verify with: git commit (staged secrets will be blocked)"
