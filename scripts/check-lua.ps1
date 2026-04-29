param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-Location $Root

$lua = @('luac54', 'luac5.4', 'luac53', 'luac5.3', 'luac', 'lua54', 'lua5.4', 'lua') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1

if (-not $lua) {
    Write-Warning 'No Lua compiler/interpreter found on PATH; skipped syntax compilation.'
} else {
    $failed = $false
    Get-ChildItem -Recurse -Filter *.lua -File |
        Where-Object { $_.FullName -notmatch '\\tmp\\' } |
        ForEach-Object {
            $file = $_.FullName
            if ($lua.Name -like 'lua*' -and $lua.Name -notlike 'luac*') {
                & $lua.Source -e "assert(loadfile(arg[1]))" $file
            } else {
                & $lua.Source -p $file
            }
            if ($LASTEXITCODE -ne 0) {
                $failed = $true
                Write-Error "Lua syntax check failed: $file"
            }
        }
    if ($failed) { exit 1 }
}

$badBegin = rg -n "local\s+(visible|shown),\s*(open|_visible)\s*=\s*imgui\.Begin|open,\s*_visible\s*=\s*imgui\.Begin" -g "*.lua" . 2>$null
if ($badBegin) {
    Write-Error "Suspicious ImGui.Begin return ordering:`n$badBegin"
    exit 1
}

$unsafeLoads = rg -n "loadstring\('return '|pcall\(dofile" -g "*.lua" . 2>$null
if ($unsafeLoads) {
    Write-Error "Unsafe persisted-data load pattern found:`n$unsafeLoads"
    exit 1
}

Write-Host 'Lua checks completed.'
