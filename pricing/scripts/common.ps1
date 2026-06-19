# Shared paths and helpers for pokemon_data pipeline scripts.
# Source: . .\common.ps1

$script:DataRoot = "C:\Users\justd\OneDrive\Documents\Ultiworld\pokemon\pricing"
$script:RawDir   = Join-Path $script:DataRoot 'raw'
$script:DbPath   = Join-Path $script:DataRoot 'pipeline.duckdb'
$script:DuckDb   = "C:\Users\justd\AppData\Local\Microsoft\WinGet\Packages\DuckDB.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\duckdb.exe"

function Invoke-Duck {
    param([string]$Sql, [string]$ReadFile)
    if ($ReadFile) {
        & $script:DuckDb $script:DbPath ".read '$($ReadFile -replace '\\','/')'"
    } else {
        # Write the SQL to a temp file and read it back — passing multi-line SQL
        # directly as a command-line argument breaks because PowerShell mangles
        # newlines and DuckDB tries to parse pieces of the SQL as CLI flags.
        $tmp = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($tmp.FullName, $Sql, [System.Text.UTF8Encoding]::new($false))
            & $script:DuckDb $script:DbPath ".read '$($tmp.FullName -replace '\\','/')'"
        } finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Read-Utf8Json {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-CsvField {
    # Escape a value for CSV. Wraps in quotes if needed; doubles internal quotes.
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[",\r\n]') {
        return '"' + ($s -replace '"','""') + '"'
    }
    return $s
}
