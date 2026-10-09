$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'tmp\helpertest'
$js  = Join-Path $root 'helper\hd2bc_helper.js'
$url   = [Environment]::GetEnvironmentVariable('HD2CT_API_URL', 'User')
$token = [Environment]::GetEnvironmentVariable('HD2CT_API_KEY', 'User')
$model = [Environment]::GetEnvironmentVariable('HD2CT_MODEL', 'User')
if (-not $url -or -not $token) { "MISSING CFG url=$([bool]$url) key=$([bool]$token)"; exit 1 }
"cfg url=$url model=$model keylen=$($token.Length)"
$utf8 = New-Object System.Text.UTF8Encoding($false)

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir -Force | Out-Null
[IO.File]::WriteAllText("$dir\helper.cfg", "url=$url`ntoken=$token`nidle=60000`nwarm=1`n", $utf8)

$proc = Start-Process -FilePath 'node' -ArgumentList "`"$js`" `"$dir`"" -RedirectStandardError "$dir\err.txt" -WindowStyle Hidden -PassThru
"helper pid=$($proc.Id)"
for ($i = 0; $i -lt 80 -and -not (Test-Path "$dir\helper.ready"); $i++) { Start-Sleep -Milliseconds 50 }
"ready=$(Test-Path "$dir\helper.ready") pid=$(Get-Content "$dir\helper.ready" -ErrorAction SilentlyContinue)"

$sys = 'You translate video game chat. Answer with the translation only, no quotes and no explanation.'
$usr = "Translate this Helldivers 2 chat line into Simplified Chinese:`nhello"
$obj = [ordered]@{ model = $model; messages = @(@{role = 'system'; content = $sys }, @{role = 'user'; content = $usr }); temperature = 0.2; max_tokens = 200; stream = $false }
$body = ($obj | ConvertTo-Json -Depth 8 -Compress)
[IO.File]::WriteAllText("$dir\body.json", $body, $utf8)

function Wait-Out([string]$id, [int]$limit) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $limit) {
    if (Test-Path "$dir\out.txt") {
      $o = Get-Content "$dir\out.txt" -Raw
      if ($o -match "id=$([regex]::Escape($id))(\r?\n)") { $sw.Stop(); return $sw.ElapsedMilliseconds }
      if ($o -match "id=$([regex]::Escape($id))(\r?)$") { $sw.Stop(); return $sw.ElapsedMilliseconds }
    }
    Start-Sleep -Milliseconds 10
  }
  $sw.Stop(); return -1
}

"---- helper: 4 jobs through one process ----"
for ($n = 1; $n -le 4; $n++) {
  $job = '{"id":"test-' + $n + '","body":' + (ConvertTo-Json $body -Compress) + '}'
  [IO.File]::WriteAllText("$dir\job.tmp", $job, $utf8)
  Rename-Item "$dir\job.tmp" "$dir\job.json"
  $wall = Wait-Out "test-$n" 30000
  $meta = (Get-Content "$dir\out.txt" -Raw) -replace "`r?`n", ' '
  $raw = ''
  if (Test-Path "$dir\raw.txt") { $raw = (Get-Content "$dir\raw.txt" -Raw) }
  $hit = [regex]::Match($raw, '"content"\s*:\s*"([^"]*)"')
  "job$n wall=${wall}ms | $meta | content=$($hit.Groups[1].Value)"
  Start-Sleep -Milliseconds 200
}

"---- curl baseline: same body, same staged files ----"
[IO.File]::WriteAllText("$dir\curl.cfg", "url = `"$url/chat/completions`"`nheader = `"Content-Type: application/json`"`nheader = `"Authorization: Bearer $token`"`nsilent`nshow-error`n", $utf8)
for ($n = 1; $n -le 3; $n++) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$env:SystemRoot\System32\curl.exe" --config "$dir\curl.cfg" --data-binary "@$dir\body.json" -o "$dir\resp.json"
  $sw.Stop()
  $raw = Get-Content "$dir\resp.json" -Raw
  $hit = [regex]::Match($raw, '"content"\s*:\s*"([^"]*)"')
  "curl$n wall=$($sw.ElapsedMilliseconds)ms content=$($hit.Groups[1].Value)"
}

"---- helper.log ----"
Get-Content "$dir\helper.log" | Select-Object -Last 14
"---- err ----"
Get-Content "$dir\err.txt" -ErrorAction SilentlyContinue
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
