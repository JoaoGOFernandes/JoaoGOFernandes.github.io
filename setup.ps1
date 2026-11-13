# Entrada publica do setup: generica, sem dados pessoais (so ASCII, para o irm | iex do Windows PowerShell).
# Uso: irm https://joaogofernandes.github.io/setup.ps1 | iex
# Abre o cofre (AES-256-CBC + HMAC-SHA256, chave por PBKDF2-SHA256) com a sua senha, baixa o setup
# do repositorio privado indicado no cofre e o executa.
# (nao altera o $ErrorActionPreference da sessao: o iex roda no escopo do usuario)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$rideBase = if ($env:RIDE_SETUP_BASE) { $env:RIDE_SETUP_BASE } else { 'https://joaogofernandes.github.io' }
$rideEstado = Join-Path $HOME '.ride-visita'

function Abrir-RideCofre($cofre, [string]$senha) {
  $salt = [Convert]::FromBase64String($cofre.salt)
  $iv = [Convert]::FromBase64String($cofre.iv)
  $ct = [Convert]::FromBase64String($cofre.ct)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($senha, $salt, [int]$cofre.iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $k = $kdf.GetBytes(64)
  $hmac = New-Object Security.Cryptography.HMACSHA256(, [byte[]]$k[32..63])
  $mac = [Convert]::ToBase64String($hmac.ComputeHash([byte[]]($iv + $ct)))
  if ($mac -ne $cofre.mac) { throw 'Senha errada (ou cofre alterado).' }
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Key = [byte[]]$k[0..31]; $aes.IV = $iv
  $pt = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
  [Text.Encoding]::UTF8.GetString($pt) | ConvertFrom-Json
}

# Lista com setas (cima/baixo + Enter); sem console de verdade, pede o numero. Devolve o indice.
function Escolher-RideOpcao([string]$titulo, [string[]]$opcoes) {
  Write-Host $titulo -ForegroundColor Cyan
  $ok = $false
  try { $ok = -not [Console]::IsInputRedirected; [void][Console]::KeyAvailable } catch { $ok = $false }
  if (-not $ok) {
    for ($i = 0; $i -lt $opcoes.Count; $i++) { Write-Host "  $($i + 1)) $($opcoes[$i])" }
    $n = 0; while ($n -lt 1 -or $n -gt $opcoes.Count) { [int]::TryParse((Read-Host 'Numero'), [ref]$n) | Out-Null }
    return $n - 1
  }
  Write-Host '(setas cima/baixo, Enter escolhe)' -ForegroundColor DarkGray
  $cur = 0; $topo = -1; $larg = [Math]::Max(20, [Console]::WindowWidth - 1)
  $vis = [Console]::CursorVisible; [Console]::CursorVisible = $false
  try {
    while ($true) {
      if ($topo -ge 0) { [Console]::SetCursorPosition(0, $topo) }
      for ($i = 0; $i -lt $opcoes.Count; $i++) {
        $t = "  $($opcoes[$i])"; if ($t.Length -gt $larg) { $t = $t.Substring(0, $larg) }
        if ($i -eq $cur) { Write-Host $t.PadRight($larg) -ForegroundColor Black -BackgroundColor Cyan }
        else { Write-Host $t.PadRight($larg) }
      }
      if ($topo -lt 0) { $topo = [Console]::CursorTop - $opcoes.Count }
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq 'UpArrow') { $cur = ($cur - 1 + $opcoes.Count) % $opcoes.Count }
      elseif ($k.Key -eq 'DownArrow') { $cur = ($cur + 1) % $opcoes.Count }
      elseif ($k.Key -eq 'Enter') { return $cur }
    }
  } finally { [Console]::CursorVisible = $vis }
}

function Ler-RideUtf8([string]$p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }

# Visita aberta neste PC: oferece desfazer sem pedir senha.
if (Test-Path (Join-Path $rideEstado 'estado.json')) {
  $r = Escolher-RideOpcao 'Ha uma visita aberta neste PC.' @(
    'Continuar  (abrir de novo; da para instalar o que ficou de fora)',
    'Desfazer   (remover o que a visita instalou e apagar a pasta dela)')
  if ($r -eq 1) {
    $p = Join-Path $rideEstado 'codigo\setup\setup.ps1'
    & ([scriptblock]::Create((Ler-RideUtf8 $p))) -Desfazer -Codigo (Join-Path $rideEstado 'codigo')
    return
  }
}

if ($env:RIDE_COFRE) { $rideCofre = Get-Content $env:RIDE_COFRE -Raw | ConvertFrom-Json }
else { $rideCofre = Invoke-RestMethod "$rideBase/cofre.json" -UseBasicParsing -ErrorAction Stop }
$s = Read-Host 'Senha do cofre' -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
try { $rideSeg = Abrir-RideCofre $rideCofre ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ride-setup-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$zip = Join-Path $tmp 'ride.zip'
Write-Host "Baixando o setup de $($rideSeg.repo)..."
Invoke-WebRequest "https://api.github.com/repos/$($rideSeg.repo)/zipball/main" -OutFile $zip -UseBasicParsing -ErrorAction Stop `
  -Headers @{ Authorization = "Bearer $($rideSeg.github.token)"; 'User-Agent' = 'ride-setup' }
Expand-Archive $zip -DestinationPath $tmp -ErrorAction Stop
$rideCodigo = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
& ([scriptblock]::Create((Ler-RideUtf8 (Join-Path $rideCodigo 'setup\setup.ps1')))) -Segredos $rideSeg -Codigo $rideCodigo
