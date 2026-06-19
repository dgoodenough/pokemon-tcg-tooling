# Builds a multi-page PDF ranking every Pokemon by premium delta (Aug 2023 -> May 2026).
# Renders via Chrome headless to %TEMP%, then copies to OneDrive reports/.
. "$PSScriptRoot\common.ps1"

$reportDir = Join-Path $script:DataRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Invoke-DuckCsv {
    param([string]$Sql)
    $tmp = New-TemporaryFile
    try {
        & $script:DuckDb -csv $script:DbPath $Sql | Set-Content $tmp.FullName -Encoding UTF8
        if ((Get-Item $tmp.FullName).Length -eq 0) { return @() }
        return @(Import-Csv $tmp.FullName)
    } finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Host 'Pulling all-Pokemon premium change data...'
$meta = Invoke-DuckCsv "SELECT snapshot_date, role FROM mv_snapshot_meta ORDER BY captured_at;"
$baseline = ($meta | Where-Object { $_.role -eq 'baseline' }).snapshot_date
$current  = ($meta | Where-Object { $_.role -eq 'current' }).snapshot_date

$all = Invoke-DuckCsv @"
SELECT
  pokemon_name,
  generation,
  COALESCE(types, '')       AS types,
  card_count_baseline       AS n_b,
  card_count_current        AS n_c,
  premium_baseline,
  premium_current,
  premium_delta,
  pct_change
FROM mv_pokemon_premium_change
ORDER BY premium_delta DESC NULLS LAST;
"@

# Summary stats for the cover
$summary = Invoke-DuckCsv @"
SELECT
  COUNT(*) AS total_pokemon,
  ROUND(MEDIAN(premium_baseline), 2) AS median_baseline,
  ROUND(MEDIAN(premium_current),  2) AS median_current,
  ROUND(MEDIAN(premium_delta),    2) AS median_delta,
  COUNT(*) FILTER (WHERE premium_delta > 0)  AS gainers,
  COUNT(*) FILTER (WHERE premium_delta < 0)  AS losers,
  COUNT(*) FILTER (WHERE premium_delta = 0)  AS flat
FROM mv_pokemon_premium_change;
"@

$payload = @{
    baselineDate = $baseline
    currentDate  = $current
    generatedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    summary      = $summary
    rows         = $all
}
$jsonPath = Join-Path $reportDir 'premium_change_report_data.json'
Write-Utf8 -Path $jsonPath -Content ($payload | ConvertTo-Json -Depth 6)
Write-Host "  $($all.Count) Pokemon written to $jsonPath"
