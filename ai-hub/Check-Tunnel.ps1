# Gate checks for the AI Hub launcher.
# Everything here is read-only except history.json / gate-log.txt.
# Add or remove allowed exits below. Nothing else needs editing.

$script:AllowedExits = [ordered]@{
  '203.0.113.10' = 'Replace with your server'
  '203.0.113.11' = 'Optional second server'
}

$script:Here        = Split-Path -Parent $MyInvocation.MyCommand.Definition
# Approved exits live in exits.json next to this file, so the hub can add or
# remove them without anyone editing PowerShell. The values below are the
# fallback when the file is missing or unreadable.
$script:ExitsFile = Join-Path $script:Here 'exits.json'
try {
  if (Test-Path $script:ExitsFile) {
    $data = Get-Content -LiteralPath $script:ExitsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $loaded = [ordered]@{}
    foreach ($e in @($data.exits)) {
      if ($e -and $e.ip) { $loaded[[string]$e.ip] = [string]$e.label }
    }
    if ($loaded.Count -gt 0) { $script:AllowedExits = $loaded }
  }
} catch { }
$script:GateLog     = Join-Path $script:Here 'gate-log.txt'
$script:HistoryFile = Join-Path $script:Here 'history.json'

function Write-GateLog {
  param([string]$Message)
  try {
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $script:GateLog -Value $line -Encoding UTF8
  } catch { }
}

function Get-ExitInfo {
  # Ask two independent services, twice each: a single dropped request through a
  # tunnel must not read as "no internet" and block every launch.
  $out = [pscustomobject]@{ Ip = $null; Country = $null; City = $null; Org = $null }

  try {
    $raw = (& curl.exe -s --connect-timeout 3 --max-time 5 --noproxy '*' https://ipinfo.io/json 2>$null) -join ''
    if ($raw) {
      $j = $raw | ConvertFrom-Json
      if ($j -and $j.ip) { $out.Ip = $j.ip; $out.Country = $j.country; $out.City = $j.city; $out.Org = $j.org }
    }
  } catch { }

  if (-not $out.Ip) {
    try {
      $raw = (& curl.exe -s --connect-timeout 3 --max-time 5 --noproxy '*' https://ifconfig.co/json 2>$null) -join ''
      if ($raw) {
        $j = $raw | ConvertFrom-Json
        if ($j -and $j.ip) { $out.Ip = $j.ip; $out.Country = $j.country_iso; $out.City = $j.city; $out.Org = $j.asn_org }
      }
    } catch { }
  }
  $out
}

function Update-IpHistory {
  param([string]$Ip, [string]$Via)
  $now = (Get-Date).ToUniversalTime()
  $rows = @()

  if (Test-Path $script:HistoryFile) {
    $parsed = $null
    try { $parsed = Get-Content -LiteralPath $script:HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($parsed) {
      foreach ($r in $parsed) {
        if (-not $r -or -not $r.ip) { continue }
        $tt = $null
        try {
          $tt = [datetime]::Parse([string]$r.t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { }
        if ($tt -and $tt -gt $now.AddDays(-7)) {
          $v = 'unknown'
          if ($r.PSObject.Properties['via'] -and $r.via) { $v = [string]$r.via }
          if ($v -eq 'unknown') {
            # entries from before this field existed: an address the gate approves
            # came through the tunnel, anything else left the machine directly
            if ($script:AllowedExits -and $script:AllowedExits.Contains([string]$r.ip)) { $v = 'tunnel' } else { $v = 'direct' }
          }
          $rows += [pscustomobject]@{ When = $tt; Ip = [string]$r.ip; Via = $v }
        }
      }
    }
  }

  # via records whether the measurement travelled through the tunnel or straight out
  # of the machine: an off-tunnel sample is a leak, not the exit moving.
  if ($Ip) { $rows += [pscustomobject]@{ When = $now; Ip = $Ip; Via = $Via } }

  # Written by hand: ConvertTo-Json wraps a one-element array differently between PS versions.
  $lines = @()
  foreach ($r in $rows) { $lines += ('{{"t":"{0}","ip":"{1}","via":"{2}"}}' -f $r.When.ToString('o'), $r.Ip, $r.Via) }
  try { ('[' + ($lines -join ',') + ']') | Set-Content -LiteralPath $script:HistoryFile -Encoding UTF8 } catch { }

  # Two different questions: which addresses the tunnel used (stability), and how
  # often traffic left without it (a leak, reported separately, never as instability).
  $tunnel = @()
  $direct = 0
  foreach ($r in $rows) {
    if ($r.When -le $now.AddHours(-48)) { continue }
    if ($r.Via -eq 'tunnel') {
      if ($tunnel -notcontains $r.Ip) { $tunnel += $r.Ip }
    } else {
      $direct++
    }
  }
  [pscustomobject]@{ Tunnel = $tunnel; DirectCount = $direct }
}

function Get-StunAddress {
  # Send one real STUN binding request (RFC 5389) over UDP and read back the
  # address the far side sees. This is the same lookup a browser makes for WebRTC.
  param([string]$Server = 'stun.l.google.com:19302', [int]$TimeoutMs = 4000)
  $udp = $null
  try {
    $bits = $Server.Split(':')
    $hostName = $bits[0]
    $port = [int]$bits[1]

    $req = New-Object byte[] 20
    $req[0] = 0; $req[1] = 1
    $magic = [byte[]](0x21, 0x12, 0xA4, 0x42)
    [Array]::Copy($magic, 0, $req, 4, 4)
    $tid = New-Object byte[] 12
    (New-Object System.Random).NextBytes($tid)
    [Array]::Copy($tid, 0, $req, 8, 12)

    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = $TimeoutMs
    $ip = [System.Net.Dns]::GetHostAddresses($hostName) |
          Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
          Select-Object -First 1
    if (-not $ip) { return $null }
    $udp.Connect($ip.ToString(), $port)
    [void]$udp.Send($req, 20)

    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $udp.Receive([ref]$ep)
    if (-not $resp -or $resp.Length -lt 20) { return $null }

    $len = ([int]$resp[2] -shl 8) + [int]$resp[3]
    $i = 20
    while ($i -lt (20 + $len)) {
      $type = ([int]$resp[$i] -shl 8) + [int]$resp[$i + 1]
      $alen = ([int]$resp[$i + 2] -shl 8) + [int]$resp[$i + 3]
      if ($type -eq 0x0020 -or $type -eq 0x0001) {
        $xor = ($type -eq 0x0020)
        $octets = @()
        for ($k = 0; $k -lt 4; $k++) {
          $v = [int]$resp[$i + 8 + $k]
          if ($xor) { $v = $v -bxor [int]$magic[$k] }
          $octets += $v
        }
        return ($octets -join '.')
      }
      $i += 4 + $alen
    }
    return $null
  } catch {
    return $null
  } finally {
    if ($udp) { $udp.Dispose() }
  }
}

function Test-HubGate {
  <#
    Every check returns: Name, Ok, Detail, Fatal.
    Fatal = a failure that must stop a launch.
    Non-fatal failures are warnings only.
  #>
  $checks = New-Object System.Collections.Generic.List[object]
  $add = {
    param($n, $ok, $detail, $fatal)
    $checks.Add([pscustomobject]@{ Name = $n; Ok = [bool]$ok; Detail = $detail; Fatal = [bool]$fatal })
  }

  # 1. the fake network card that every packet must travel through
  $ad = $null
  try { $ad = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue } catch { }
  $adUp = ($ad -and $ad.Status -eq 'Up')
  & $add 'TUN adapter' $adUp $(if ($adUp) { 'Meta Tunnel up' } elseif ($ad) { "present but $($ad.Status)" } else { 'not installed / core not running' }) $true

  # 2. it must own the default route, or traffic is not actually intercepted
  $defaultViaTun = $false
  if ($ad) {
    try {
      $dr = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq $ad.ifIndex -and $_.NextHop -eq '198.18.0.2' }
      $defaultViaTun = [bool]$dr
    } catch { }
  }
  & $add 'Default route' $defaultViaTun $(if ($defaultViaTun) { 'every packet intercepted' } else { 'no route through the card' }) $true

  # 3. the process that runs the rules
  $core = Get-Process -Name 'verge-mihomo', 'mihomo' -ErrorAction SilentlyContinue | Select-Object -First 1
  & $add 'Core process' ([bool]$core) $(if ($core) { "pid $($core.Id)" } else { 'not running' }) $true

  # 4. the actual exit, measured
  $exit = Get-ExitInfo
  $known = $false; $where = $null
  if ($exit.Ip -and $script:AllowedExits.Contains($exit.Ip)) { $known = $true; $where = $script:AllowedExits[$exit.Ip] }
  $usOk = ($exit.Country -eq 'US')

  $exitDetail =
    if (-not $exit.Ip) { 'no answer from the internet' }
    elseif ($known) { "$($exit.Ip) - $where" }
    elseif ($usOk) { "$($exit.Ip) - US, but not an exit you approved" }
    else { "$($exit.Ip) - $($exit.Country) $($exit.City) - NOT AMERICAN" }
  & $add 'Exit IP' $known $exitDetail $true

  $countryDetail =
    if (-not $exit.Country) { 'unknown' }
    elseif ($usOk) { 'US' }
    else { "$($exit.Country) $($exit.City)" }
  & $add 'Country' $usOk $countryDetail $false

  # 5. fingerprint: clock and language must not say China
  $tz = (Get-TimeZone).Id
  $loc = (Get-Culture).Name
  $fpOk = ($loc -eq 'en-US')
  & $add 'Locale' $fpOk $loc $false
  $tzOk = ($tz -eq 'Pacific Standard Time')
  & $add 'Timezone' $tzOk $tz $false

  # 6. churn: a second exit appearing without you choosing it
  $todayVia = 'direct'
  if ($adUp -and $defaultViaTun) { $todayVia = 'tunnel' }
  $churn = Update-IpHistory -Ip $exit.Ip -Via $todayVia
  $tunnelIps = @($churn.Tunnel)
  $directCount = [int]$churn.DirectCount
  $churnOk = (@($tunnelIps).Count -le 2)
  $churnDetail =
    if (-not $churnOk) { "$(@($tunnelIps).Count) exits in 48h: $($tunnelIps -join ', ')" }
    elseif (@($tunnelIps).Count -eq 0) { 'no tunnel sample yet' }
    else { "$(@($tunnelIps).Count) exit in 48h through the tunnel" }
  if ($directCount -gt 0) { $churnDetail += "  |  $directCount direct sample(s): the tunnel was off, not the exit moving" }
  & $add 'Exit stability' $churnOk $churnDetail $false

  # 7. WebRTC: what a UDP lookup learns, which is what a browser would leak
  $stunIp = Get-StunAddress
  if ($stunIp) {
    if (-not $exit.Ip) {
      & $add 'WebRTC / STUN' $false "$stunIp - no exit to compare against" $false
    } else {
      $sameIp = ($stunIp -eq $exit.Ip)
      & $add 'WebRTC / STUN' $sameIp $(if ($sameIp) { 'same address as the exit' } else { "$stunIp - DIFFERENT from the exit" }) $true
    }
  } else {
    # A UDP block is not proof of safety, so this is amber, never green.
    & $add 'WebRTC / STUN' $false 'could not measure - no UDP answer' $false
  }

  # 8. IPv6: a v6 address on the physical card would bypass a v4-only tunnel
  $v6 = @()
  $v6Route = @()
  try {
    $v6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object {
              $_.AddressState -eq 'Preferred' -and
              $_.InterfaceAlias -notmatch 'Mihomo|Loopback' -and
              $_.IPAddress -notmatch '^(fe80|::1)'
            })
    $v6Route = @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
                 Where-Object { $_.InterfaceAlias -match 'Mihomo' })
  } catch { }
  if ($v6.Count -eq 0) {
    & $add 'IPv6' $true 'none on this machine' $false
  } elseif ($v6Route.Count -gt 0) {
    & $add 'IPv6' $true 'tunnelled' $false
  } else {
    & $add 'IPv6' $false ($v6[0].IPAddress + ' is NOT tunnelled') $true
  }

  # 9. DNS: names should be answered by the core (fake-ip), not by the ISP
  $dnsIp = $null
  try {
    $dnsIp = (Resolve-DnsName 'www.google.com' -Type A -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
  } catch { }
  $dnsOk = ($dnsIp -like '198.18.*')
  & $add 'DNS' $dnsOk $(if ($dnsOk) { 'answered inside the tunnel' } elseif ($dnsIp) { "$dnsIp - real address, DNS may bypass" } else { 'no answer' }) $false

  # 10. IP reputation - the cleanip.io question: does the internet think this
  #     exit is a datacenter, a VPN or a proxy? That is what Claude weighs.
  if (-not $exit.Ip) {
    & $add 'IP reputation' $false 'no exit to look up' $false
  } else {
    # ip-api answers instantly usually, but drops a request now and then through a
    # tunnel ("empty reply"). One attempt makes a flaky lookup look like a bad exit,
    # so try three times before saying it could not be measured.
    $rep = $null
    $repTries = 0
    while (-not $rep -and $repTries -lt 2) {
      $repTries++
      try {
        $u = 'http://ip-api.com/json/' + $exit.Ip + '?fields=status,countryCode,proxy,hosting,mobile,isp'
        $raw = (& curl.exe -s --connect-timeout 3 --max-time 5 --noproxy '*' $u 2>$null) -join ''
        if ($raw) {
          $cand = $raw | ConvertFrom-Json
          if ($cand -and $cand.status -eq 'success') { $rep = $cand }
        }
      } catch { }
      if (-not $rep -and $repTries -lt 2) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $rep) {
      & $add 'IP reputation' $false "lookup failed $repTries times - could not verify" $false
    } else {
      $flags = @()
      if ($rep.proxy)   { $flags += 'proxy/VPN' }
      if ($rep.hosting) { $flags += 'datacenter' }
      if ($rep.mobile)  { $flags += 'mobile' }
      $repOk = ($flags.Count -eq 0 -and $rep.countryCode -eq 'US')
      $repDetail =
        if ($flags.Count -gt 0) { 'FLAGGED as ' + ($flags -join ', ') }
        elseif ($rep.countryCode -ne 'US') { "$($rep.countryCode) - not US" }
        else { 'not flagged - US exit' }
      if ($repTries -gt 1) { $repDetail += " (on attempt $repTries)" }
      & $add 'IP reputation' $repOk $repDetail $true
    }
  }

  # 11. one exit for every Anthropic host - cleanip's consistency test.
  #     claude.ai, the API and the console must all see the same address.
  if (-not $exit.Ip) {
    & $add 'Anthropic exits' $false 'no exit to compare' $false
  } else {
    $hosts = @('claude.ai', 'api.anthropic.com', 'console.anthropic.com')
    $seen = @{}
    $unreachable = $false
    foreach ($h in $hosts) {
      if ($unreachable) { $seen[$h] = $null; continue }
      $ip = $null
      # one dropped request is not a verdict, two in a row is close enough
      for ($k = 0; $k -lt 2 -and -not $ip; $k++) {
        try {
          $trace = (& curl.exe -s --connect-timeout 3 --max-time 5 --noproxy '*' ("https://$h/cdn-cgi/trace") 2>$null) -join "`n"
          $m = [regex]::Match($trace, '(?m)^ip=(.+)$')
          if ($m.Success) { $ip = $m.Groups[1].Value.Trim() }
        } catch { }
        if (-not $ip -and $k -lt 1) { Start-Sleep -Milliseconds 400 }
      }
      if (-not $ip) { $unreachable = $true }
      $seen[$h] = $ip
    }
    $missing = @($hosts | Where-Object { -not $seen[$_] })
    $wrong   = @($hosts | Where-Object { $seen[$_] -and $seen[$_] -ne $exit.Ip })
    if ($missing.Count -gt 0) {
      & $add 'Anthropic exits' $false ('no answer from ' + ($missing -join ', ')) $false
    } elseif ($wrong.Count -gt 0) {
      & $add 'Anthropic exits' $false (($wrong -join ', ') + " differ from $($exit.Ip)") $true
    } else {
      & $add 'Anthropic exits' $true "all 3 = $($exit.Ip)" $true
    }
  }

  # 12. browser fingerprint - the fuck-claude.app question, measured locally.
  #     Chinese font families installed and a DNT/GPC flag are the signals that
  #     survive a perfect tunnel. Warning only: removing fonts is a system change.
  $cjk = @()
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $cjkPattern = 'SimSun|SimHei|YaHei|JhengHei|KaiTi|FangSong|NSimSun|MingLiU|DengXian|STXihei|STKaiti|STSong|STHeiti|Noto Sans CJK|Noto Serif CJK|Source Han|DFKai|LiSu|YouYuan'
    $cjk = @((New-Object System.Drawing.Text.InstalledFontCollection).Families |
             Where-Object { $_.Name -match $cjkPattern } |
             ForEach-Object { $_.Name })
  } catch { }
  $dnt = $null
  try {
    $dnt = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  } catch { }
  $dntOn = ($dnt -and ($dnt.DoNotTrack -or $dnt.GlobalPrivacyControl))
  $fpClean = ($cjk.Count -eq 0 -and -not $dntOn)
  $fpDetail =
    if ($cjk.Count -eq 0 -and -not $dntOn) { 'no Chinese fonts, no DNT/GPC' }
    elseif ($cjk.Count -gt 0 -and $dntOn) { "$($cjk.Count) Chinese font families, DNT/GPC set" }
    elseif ($cjk.Count -gt 0) { "$($cjk.Count) Chinese font families installed" }
    else { 'DNT/GPC flag set' }
  & $add 'Fingerprint' $fpClean $fpDetail $false

  $pass = -not ($checks | Where-Object { $_.Fatal -and -not $_.Ok })
  [pscustomobject]@{
    Pass   = [bool]$pass
    Checks = $checks.ToArray()
    Ip     = $exit.Ip
    Country = $exit.Country
    Where  = $where
  }
}
