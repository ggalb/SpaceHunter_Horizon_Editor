<#
  mount-bridge.ps1  -  local bridge between the Horizon Editor web page and any
  ASCOM telescope mount. On launch it opens the ASCOM Chooser to pick the mount
  (GS Server, ZWO AM, iOptron, EQMOD, simulator, ...); pass -ProgId to skip it.

  Why this exists: a browser page cannot talk to a COM ASCOM driver. This
  script (a) serves the HTML page over http://localhost so page + API are
  SAME-ORIGIN (no CORS), and (b) talks COM directly to the mount. Zero install
  on Windows 11 - Windows PowerShell 5.1 (STA) has everything needed.

  Run:
    powershell -STA -ExecutionPolicy Bypass -File .\mount-bridge.ps1
    powershell -STA -ExecutionPolicy Bypass -File .\mount-bridge.ps1 -ProgId ASCOM.Simulator.Telescope -Port 5555

  SAFETY: read-only until you press Slew. Validates SiderealTime + site before
  any slew. Never sets Connected = $false (a hub driver like GS Server shares
  connection state; dropping it could kill N.I.N.A.'s link). AbortSlew is STOP.
#>
param(
  [string]$ProgId  = '',    # empty -> pop the ASCOM Chooser to pick any mount; pass one to skip the dialog
  [int]   $Port    = 5555,
  [string]$HtmlPath = (Join-Path $PSScriptRoot 'horizon_editor_local.html')
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Write-Warning "Not running STA. ASCOM COM wants STA. Relaunch with:  powershell -STA -File .\gss-bridge.ps1"
}

# ---------- pick the mount (ASCOM Chooser) unless a ProgId was given ----------
if (-not $ProgId) {
  try {
    $chooser = New-Object -ComObject ASCOM.Utilities.Chooser
    $chooser.DeviceType = 'Telescope'
    Write-Host "Opening the ASCOM Chooser - pick your mount..."
    $ProgId = $chooser.Choose('ASCOM.GS.Sky.Telescope')   # GS Server pre-selected
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($chooser) } catch {}  # cleanup only; never fail the Chooser over it
  } catch {
    Write-Warning "ASCOM Chooser unavailable ($($_.Exception.Message)). Install the ASCOM Platform, or pass -ProgId."
  }
  if (-not $ProgId) { Write-Host "No mount selected - exiting."; exit }
}

# ---------- connect COM ----------
Write-Host "Creating COM object $ProgId ..."
$scope = New-Object -ComObject $ProgId
try { if (-not $scope.Connected) { Write-Host "Connecting..."; $scope.Connected = $true; Start-Sleep -Milliseconds 800 } }
catch { Write-Warning "Could not set Connected: $($_.Exception.Message)" }
Write-Host ("Driver: {0}  v{1}  Connected={2}" -f $scope.Name, $scope.DriverVersion, $scope.Connected)

# ---------- helpers ----------
function Get-Cap($name){ try { return [bool]$scope.$name } catch { return $false } }

function Get-Status {
  $s = [ordered]@{ ok = $true; progId = $ProgId }
  try { $s.name = $scope.Name } catch { $s.name = $null }
  try { $s.connected = [bool]$scope.Connected } catch { $s.connected = $false }
  if ($s.connected) {
    foreach ($p in 'Slewing','Tracking','AtPark','AtHome') { try { $s[$p.ToLower()] = [bool]$scope.$p } catch { $s[$p.ToLower()] = $null } }
    $s.canFindHome = Get-Cap 'CanFindHome'
    $s.canPark     = Get-Cap 'CanPark'
    try { $s.ra   = [math]::Round($scope.RightAscension,5) } catch { $s.ra = $null }
    try { $s.dec  = [math]::Round($scope.Declination,5) }    catch { $s.dec = $null }
    try { $s.alt  = [math]::Round($scope.Altitude,5) }       catch { $s.alt = $null }
    try { $s.az   = [math]::Round($scope.Azimuth,5) }        catch { $s.az = $null }
    try { $s.lst  = [math]::Round($scope.SiderealTime,5) }   catch { $s.lst = $null }
    try { $s.siteLat = $scope.SiteLatitude }  catch { $s.siteLat = $null }
    try { $s.siteLon = $scope.SiteLongitude } catch { $s.siteLon = $null }
    $s.canSlewAltAzAsync = Get-Cap 'CanSlewAltAzAsync'
    $s.canSlewAsync      = Get-Cap 'CanSlewAsync'
  }
  return $s
}

function AltAz-ToRaDec($alt,$az,$lat,$lst){
  $altR=[math]::PI/180*$alt; $A=[math]::PI/180*($az-180); $latR=[math]::PI/180*$lat
  $dec=[math]::Asin([math]::Sin($latR)*[math]::Sin($altR)-[math]::Cos($latR)*[math]::Cos($altR)*[math]::Cos($A))
  $H=[math]::Atan2([math]::Sin($A),[math]::Cos($A)*[math]::Sin($latR)+[math]::Tan($altR)*[math]::Cos($latR))
  $raH=$lst-($H*180/[math]::PI)/15.0; $raH=(($raH%24)+24)%24
  return @{ ra=$raH; dec=($dec*180/[math]::PI) }
}

function Do-Slew($alt,$az){
  # ---- validation (your mount-capabilities.md safety finding) ----
  if ($az -eq $null -or $alt -eq $null) { return @{ ok=$false; error='missing alt/az' } }
  if ($az -lt 0 -or $az -gt 360)        { return @{ ok=$false; error="azimuth $az out of range" } }
  if ($alt -lt 0 -or $alt -gt 90)       { return @{ ok=$false; error="altitude $alt out of range (0-90)" } }
  if (-not $scope.Connected)            { return @{ ok=$false; error='not connected' } }
  $lst = $scope.SiderealTime
  if ($lst -lt 0 -or $lst -gt 24)       { return @{ ok=$false; error="invalid SiderealTime $lst" } }
  $lat = $scope.SiteLatitude; $lon = $scope.SiteLongitude
  if ($lat -lt -90 -or $lat -gt 90 -or ($lat -eq 0 -and $lon -eq 0)) { return @{ ok=$false; error="implausible site lat/lon ($lat,$lon)" } }

  try { if ($scope.AtPark -and (Get-Cap 'CanUnpark')) { $scope.Unpark() } } catch {}

  if (Get-Cap 'CanSlewAltAzAsync') {
    # Alt/Az is a ground-fixed direction — tracking must be off (the driver
    # refuses it otherwise), and off is what we want so the scope holds that
    # horizon bearing instead of drifting with the sky.
    $trackWasOn = $false
    try { if ($scope.Tracking -and (Get-Cap 'CanSetTracking')) { $trackWasOn = $true; $scope.Tracking = $false; Start-Sleep -Milliseconds 200 } } catch {}
    Write-Host ("SlewToAltAzAsync az={0} alt={1} (tracking off)" -f $az,$alt)
    $scope.SlewToAltAzAsync($az,$alt)
    return @{ ok=$true; method='AltAz'; trackingDisabled=$trackWasOn; az=$az; alt=$alt }
  } elseif (Get-Cap 'CanSlewAsync') {
    $rd = AltAz-ToRaDec $alt $az $lat $lst
    Write-Host ("SlewToCoordinatesAsync ra={0} dec={1} (from alt/az)" -f $rd.ra,$rd.dec)
    $scope.SlewToCoordinatesAsync($rd.ra,$rd.dec)
    return @{ ok=$true; method='RaDec'; ra=[math]::Round($rd.ra,5); dec=[math]::Round($rd.dec,5) }
  }
  return @{ ok=$false; error='driver supports neither async Alt/Az nor async RA/Dec slew' }
}

# ---------- HTTP ----------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host ""
Write-Host "GSS bridge listening on  http://localhost:$Port/"
Write-Host "Open that URL in Chrome/Edge. Ctrl+C to stop."
Write-Host ""

function Send-Json($ctx,$obj,$code=200){
  $json=[Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))
  $ctx.Response.StatusCode=$code
  $ctx.Response.ContentType='application/json'
  $ctx.Response.Headers.Add('Access-Control-Allow-Origin','*')
  $ctx.Response.Headers.Add('Cache-Control','no-store')
  $ctx.Response.OutputStream.Write($json,0,$json.Length)
  $ctx.Response.OutputStream.Close()
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request; $path = $req.Url.AbsolutePath; $method = $req.HttpMethod
  try {
    if ($method -eq 'OPTIONS') {
      $ctx.Response.Headers.Add('Access-Control-Allow-Origin','*')
      $ctx.Response.Headers.Add('Access-Control-Allow-Methods','GET,POST,OPTIONS')
      $ctx.Response.Headers.Add('Access-Control-Allow-Headers','Content-Type')
      $ctx.Response.StatusCode=204; $ctx.Response.OutputStream.Close(); continue
    }

    if ($path -eq '/' -or $path -eq '/index.html') {
      if (Test-Path $HtmlPath) {
        $bytes=[IO.File]::ReadAllBytes($HtmlPath)
        $ctx.Response.ContentType='text/html; charset=utf-8'
        $ctx.Response.Headers.Add('Cache-Control','no-store, must-revalidate')   # always serve the current file
        $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length); $ctx.Response.OutputStream.Close()
      } else { $ctx.Response.StatusCode=404; $ctx.Response.OutputStream.Close() }
      continue
    }

    switch ($path) {
      '/api/status'  { Send-Json $ctx (Get-Status); break }
      '/api/connect' {
        try { if (-not $scope.Connected) { $scope.Connected=$true; Start-Sleep -Milliseconds 800 } } catch {}
        Send-Json $ctx (Get-Status); break
      }
      '/api/slew' {
        $body = (New-Object IO.StreamReader($req.InputStream,$req.ContentEncoding)).ReadToEnd()
        $d = $null; if ($body) { $d = $body | ConvertFrom-Json }
        $r = Do-Slew ([double]$d.alt) ([double]$d.az)
        Send-Json $ctx $r ($(if($r.ok){200}else{400})); break
      }
      '/api/abort' {
        try { $scope.AbortSlew(); Send-Json $ctx @{ ok=$true } }
        catch { Send-Json $ctx @{ ok=$false; error=$_.Exception.Message } 400 }
        break
      }
      '/api/home' {
        try {
          if (-not (Get-Cap 'CanFindHome')) { Send-Json $ctx @{ ok=$false; error='driver does not support Find Home' } 400; break }
          if ($scope.AtPark -and (Get-Cap 'CanUnpark')) { $scope.Unpark() }
          Write-Host "FindHome()"
          $scope.FindHome()
          Send-Json $ctx @{ ok=$true }
        } catch { Send-Json $ctx @{ ok=$false; error=$_.Exception.Message } 400 }
        break
      }
      '/api/park' {
        try {
          if (-not (Get-Cap 'CanPark')) { Send-Json $ctx @{ ok=$false; error='driver does not support Park' } 400; break }
          Write-Host "Park()"
          $scope.Park()
          Send-Json $ctx @{ ok=$true }
        } catch { Send-Json $ctx @{ ok=$false; error=$_.Exception.Message } 400 }
        break
      }
      '/api/tracking' {
        $body = (New-Object IO.StreamReader($req.InputStream,$req.ContentEncoding)).ReadToEnd()
        $d = $null; if ($body) { $d = $body | ConvertFrom-Json }
        try { if (Get-Cap 'CanSetTracking') { $scope.Tracking = [bool]$d.on }; Send-Json $ctx (Get-Status) }
        catch { Send-Json $ctx @{ ok=$false; error=$_.Exception.Message } 400 }
        break
      }
      default { Send-Json $ctx @{ ok=$false; error="unknown path $path" } 404 }
    }
  } catch {
    try { Send-Json $ctx @{ ok=$false; error=$_.Exception.Message } 500 } catch {}
  }
}
