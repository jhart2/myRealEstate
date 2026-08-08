param(
  [string]$Model = "realesr-animevideov3",
  [int]$Scale = 2,
  [int]$Tile = 64,
  [int]$Gpu = 0,
  [int]$TimeoutMs = 300000,
  [string]$In = "",
  [string]$Out = ""
)
$root = Join-Path $env:USERPROFILE "tools\realesrgan-ncnn-vulkan"
$exe = Join-Path $root "realesrgan-ncnn-vulkan.exe"
$models = Join-Path $root "models"
if ($In -and $In.Trim().Length -gt 0) {
  $in = [Environment]::ExpandEnvironmentVariables($In)
} else {
  $in = Join-Path $env:TEMP "tt_enhance_in.jpg"
}
if ($Out -and $Out.Trim().Length -gt 0) {
  $out = [Environment]::ExpandEnvironmentVariables($Out)
} else {
  $out = Join-Path $env:TEMP "tt_enhance_out.png"
}
if (-not (Test-Path $exe)) { Write-Output "MISSING_EXE"; exit 1 }
if (-not (Test-Path $in)) { Write-Output "MISSING_IN"; exit 1 }
if (Test-Path $out) { Remove-Item -Force $out }
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-i `"$in`" -o `"$out`" -n $Model -s $Scale -t $Tile -m `"$models`" -g $Gpu -v"
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
if (-not $p.WaitForExit($TimeoutMs)) {
  if (Test-Path $out) {
    try { $p.Kill() } catch {}
    Write-Output "RESULT=OK_AFTER_TIMEOUT"
  } else {
    try { $p.Kill() } catch {}
    Write-Output "RESULT=HANG"
    exit 2
  }
} else {
  Write-Output ("RESULT=EXIT_" + $p.ExitCode)
}
$p.StandardOutput.ReadToEnd() | Write-Output
$p.StandardError.ReadToEnd() | Write-Output
if (-not (Test-Path $out)) { exit 3 }
exit 0
