# Start-AIHub.ps1
# The front door: check the tunnel, then let you pick what to open.
# Run through the "AI Hub" shortcut. Never run this as admin.

param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# First line of the log, before anything can fail: written directly rather than
# through Write-GateLog, because that function lives in Check-Tunnel.ps1, which
# has not been loaded yet and may be the thing that fails.
try {
  Add-Content -LiteralPath (Join-Path $here 'gate-log.txt') -Value ('{0}  START process  pid {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $PID) -Encoding UTF8
} catch { }

. (Join-Path $here 'Check-Tunnel.ps1')

# Workers that have been asked to stop but have not finished yet, and a flag the
# closing handler sets so nothing tries to raise a window that is going away.
$script:Zombies = New-Object System.Collections.ArrayList
$script:Closing = $false

# Belt and braces: if this script ever gets started by something that still
# owns a console (an old shortcut, a stray powershell.exe), hide that console
# before any window is drawn. AIHub.exe normally prevents one existing at all.
if (-not ('HubConsole' -as [type])) {
  Add-Type -Namespace Hub -Name Console -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
'@
}
try {
  $script:consoleHwnd = [Hub.Console]::GetConsoleWindow()
  if ($script:consoleHwnd -ne [IntPtr]::Zero) { [void][Hub.Console]::ShowWindow($script:consoleHwnd, 0) }
} catch { }

# Own taskbar identity: without this the button carries powershell.exe's name and
# icon, which looks like "a PowerShell window opened" instead of "AI Hub opened".
if (-not ('HubApp' -as [type])) {
  Add-Type -Namespace Hub -Name App -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
}
try { [void][Hub.App]::SetCurrentProcessExplicitAppUserModelID('AIHub.Desktop') } catch { }

# Win32 helpers used both for "raise the open hub" and inside the window.
if (-not ('Hub.Win' -as [type])) {
  Add-Type -Namespace Hub -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool altTab);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
}

# The raise event is opened before the mutex, in both processes, so it always
# exists before any click can arrive; a signal cannot be lost in the gap between
# one process creating it and another setting it.
$script:ShowEvent = $null
try {
  $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\AIHub-Show')
} catch { }

# One hub at a time: a second click brings the open window forward and exits,
# instead of starting a duplicate hub (and a second stray process).
$script:HubMutex = New-Object System.Threading.Mutex($false, 'Local\AIHub-Instance')
$script:HubIsFirst = $true
try { $script:HubIsFirst = $script:HubMutex.WaitOne(0) } catch { }
if (-not $script:HubIsFirst) {
  # Signal only. The running hub raises itself; poking another process's window
  # from here can block on a busy owner and Windows may refuse it anyway.
  try {
    if ($script:ShowEvent) { [void]$script:ShowEvent.Set() }
    Write-GateLog 'RAISE forwarded'
  } catch { }
  exit
}

$configPath = Join-Path $here 'apps.json'

if ($SelfTest) {
  $r = Test-HubGate
  $r | ConvertTo-Json -Depth 6
  exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------------------------------------------------------------- palette
function Get-Color([string]$hex) {
  $h = $hex.TrimStart('#')
  if ($h.Length -eq 8) { $h = $h.Substring(2) }
  [System.Windows.Media.Color]::FromRgb(
    [Convert]::ToByte($h.Substring(0, 2), 16),
    [Convert]::ToByte($h.Substring(2, 2), 16),
    [Convert]::ToByte($h.Substring(4, 2), 16))
}
function New-Brush([string]$hex) {
  $b = New-Object System.Windows.Media.SolidColorBrush (Get-Color $hex)
  $b.Freeze()
  $b
}

$cInk    = New-Brush '#101216'
$cCard   = New-Brush '#181C22'
$cCardHi = New-Brush '#20262F'
$cPanel  = New-Brush '#15181D'
$cLine   = New-Brush '#323943'
$cLineHi = New-Brush '#7C8999'
$cText   = New-Brush '#F2F4F7'
$cMuted  = New-Brush '#B5BFCC'
$cDim    = New-Brush '#9DA9B8'
$cDisabledInk = New-Brush '#A8B3C0'
$cDisabledNote = New-Brush '#929EAD'
$cEdgeDisabled = New-Brush '#343C47'
$cGreen  = New-Brush '#59D39A'
$cGreenWash = New-Brush '#14251E'
$cGreenEdge = New-Brush '#4A775F'
$cAmber  = New-Brush '#F6C56C'
$cAmberWash = New-Brush '#2A2117'
$cAmberEdge = New-Brush '#987248'
$cRed    = New-Brush '#FF8F90'
$cRedWash = New-Brush '#301C21'
$cRedEdge = New-Brush '#A86469'
$cBlue   = New-Brush '#A6C4FF'
$cBlueWash = New-Brush '#1B2433'
$cSelected = New-Brush '#C3CDDB'
$cControl = New-Brush '#252D37'
$cControlHi = New-Brush '#303B49'
$cField  = New-Brush '#111419'
$cPrimary = New-Brush '#E8EEF7'
$cOnPrimary = New-Brush '#11151B'

$fontDisplay = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Display, Segoe UI'
$fontText    = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'

$script:Override = $false
$script:LastGate = $null

# Brand marks. The OpenAI path is the official 24x24 mark (simple-icons),
# drawn as a vector so it stays sharp at any size.
$script:Marks = @{
  'openai' = @{
    Path = 'M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z'
    Fill = '#E6EAF0'
  }
}

# ---------------------------------------------------------------- data
function Load-Items {
  $script:Items = @()
  $script:GroupOrder = @()
  if (Test-Path $configPath) {
    try {
      $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $script:Items = @($cfg.items | Where-Object { $_.enabled -ne $false })
    } catch { $script:Items = @() }
  }
  foreach ($i in $script:Items) {
    if ($script:GroupOrder -notcontains $i.group) { $script:GroupOrder += $i.group }
  }
}
Load-Items

# ---------------------------------------------------------------- launch
function Invoke-HubItem($item) {
  if (-not $item) { return }
  # Refuse to launch on a missing or failed verdict: a check in flight clears
  # LastGate, so this also blocks the gap between RE-CHECK and its result.
  if (-not $script:LastGate) {
    Write-GateLog ("LAUNCH-BLOCKED  " + $item.name + " :: no completed check")
    $fText.Text = 'Checks are still running. Nothing can be launched yet.'
    return
  }
  if (-not $script:LastGate.Pass -and -not $script:Override) {
    Write-GateLog ("LAUNCH-BLOCKED  " + $item.name + " :: gate failed")
    return
  }
  Write-GateLog ("LAUNCH  {0,-22} {1} {2}" -f $item.name, $item.kind, $item.target)
  try {
    switch ($item.kind) {
      'appid' { Start-Process 'explorer.exe' -ArgumentList ("shell:AppsFolder\" + $item.target) }
      'exe'   { Start-Process -FilePath $item.target }
      'url'   { Start-Process $item.target }
      'cli'   {
        $dir = $item.cwd
        if (-not $dir) { $dir = $env:USERPROFILE }
        $wt = Get-Command 'wt.exe' -ErrorAction SilentlyContinue
        if ($wt) {
          Start-Process -FilePath $wt.Source -ArgumentList @('-d', ('"' + $dir + '"'), 'powershell.exe', '-NoExit', '-Command', $item.target)
        } else {
          Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-Command', ('Set-Location -LiteralPath ''' + $dir + '''; ' + $item.target))
        }
      }
      default { Start-Process $item.target }
    }
  } catch {
    Write-GateLog ("LAUNCH-FAIL  " + $item.name + " :: " + $_.Exception.Message)
  }
  # The hub stays open after a launch, so two apps can be
  # opened in a row without coming back to the desktop. Close it with X or Esc.
}

# ---------------------------------------------------------------- widgets
function New-Pill($check) {
  $stateWord = 'Pass'; $stateInk = $cGreen; $fill = $cGreenWash; $edge = $cGreenEdge
  if (-not $check.Ok -and -not $check.Fatal) { $stateWord = 'Warning'; $stateInk = $cAmber; $fill = $cAmberWash; $edge = $cAmberEdge }
  elseif (-not $check.Ok -and $check.Fatal) { $stateWord = 'Failed'; $stateInk = $cRed; $fill = $cRedWash; $edge = $cRedEdge }

  $b = New-Object System.Windows.Controls.Border
  $b.Width = 112
  $b.Height = 44
  $b.CornerRadius = 10
  $b.Padding = '8,0,8,0'
  $b.Background = $fill
  $b.BorderBrush = $edge
  $b.BorderThickness = 1
  $b.Margin = '0,0,6,0'
  $b.Cursor = 'Hand'
  $b.Focusable = $true
  [void][System.Windows.Input.KeyboardNavigation]::SetIsTabStop($b, $true)
  $b.Tag = [pscustomobject]@{ Check = $check; Edge = $edge }

  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.VerticalAlignment = 'Center'

  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $check.Name
  $t.FontFamily = $fontText
  $t.FontSize = 12
  $t.FontWeight = 'SemiBold'
  $t.Foreground = $cText
  $t.TextTrimming = 'CharacterEllipsis'
  [void]$stack.Children.Add($t)

  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.Margin = '0,2,0,0'

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 6
  $dot.Height = 6
  $dot.Fill = $stateInk
  $dot.VerticalAlignment = 'Center'
  $dot.Margin = '0,0,5,0'
  [void]$row.Children.Add($dot)

  $s = New-Object System.Windows.Controls.TextBlock
  $s.Text = $stateWord
  $s.FontFamily = $fontText
  $s.FontSize = 11
  $s.FontWeight = 'SemiBold'
  $s.Foreground = $stateInk
  $s.VerticalAlignment = 'Center'
  [void]$row.Children.Add($s)

  [void]$stack.Children.Add($row)
  $b.Child = $stack

  $b.Add_MouseLeftButtonUp({ Select-Check $this })
  $b.Add_GotFocus({ Select-Check $this })
  $b.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Enter' -or $e.Key -eq 'Space') { Select-Check $this; $e.Handled = $true }
  })
  $b
}

function Get-MarkFile($item) {
  $key = $null
  switch -Regex ($item.target) {
    'OpenAI\.Codex_.*!App'    { $key = 'chatgpt-app' }
    'Claude_pzs8sxrjxfjjc'    { $key = 'claude' }
    '^claude$'                { $key = 'claude-code' }
    '^codex$'                 { $key = 'codex' }
    'Orca\.exe'               { $key = 'orca' }
    '^https://claude\.ai'     { $key = 'claude-ai' }
    'console\.anthropic\.com' { $key = 'claude-console' }
    '^https://chatgpt\.com'   { $key = 'chatgpt' }
    'platform\.openai\.com'   { $key = 'openai-platform' }
  }
  if ($key) {
    $p = Join-Path $here ("assets\brand\{0}-22.png" -f $key)
    if (Test-Path $p) { return $p }
  }
  $null
}

# ---------------------------------------------------------------- icon maker
# Built-in brands use their own mark. Anything else gets an icon derived from the
# thing it launches: the program's own icon, the site's favicon, or a lettered
# plate. Cached in assets\cache so it is built once.
$script:IconCache = Join-Path $here 'assets\cache'
if (-not (Test-Path $script:IconCache)) { New-Item -ItemType Directory -Path $script:IconCache -Force | Out-Null }

function Get-IconCachePath($item) {
  $key = [string]$item.target
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes($key.ToLower())
  $hash = ([BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', '').Substring(0, 12).ToLower()
  Join-Path $script:IconCache ($hash + '.png')
}

function New-LetterIcon($name, $outPath) {
  $bmp = New-Object System.Drawing.Bitmap 88, 88, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([System.Drawing.Color]::Transparent)

  # colour from the name, so the same app always gets the same plate
  $sum = 0
  foreach ($ch in ([string]$name).ToCharArray()) { $sum += [int]$ch }
  $palette = @(
    @(0x2F, 0x6F, 0x8F), @(0x3B, 0x7A, 0x5A), @(0x8A, 0x5A, 0x2F), @(0x5A, 0x4A, 0x8F),
    @(0x8F, 0x3B, 0x5A), @(0x2F, 0x5A, 0x8F), @(0x5A, 0x6F, 0x2F), @(0x6F, 0x2F, 0x6F)
  )
  $c = $palette[$sum % $palette.Count]
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = 20
  $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
  $path.AddArc(88 - $r * 2, 0, $r * 2, $r * 2, 270, 90)
  $path.AddArc(88 - $r * 2, 88 - $r * 2, $r * 2, $r * 2, 0, 90)
  $path.AddArc(0, 88 - $r * 2, $r * 2, $r * 2, 90, 90)
  $path.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, $c[0], $c[1], $c[2]))), $path)

  $letter = ([string]$name).Trim()
  if ($letter.Length -gt 0) { $letter = $letter.Substring(0, 1).ToUpper() } else { $letter = '?' }
  $font = New-Object System.Drawing.Font 'Segoe UI', 44, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = 'Center'
  $fmt.LineAlignment = 'Center'
  $g.DrawString($letter, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 2, 88, 88), $fmt)
  $g.Dispose(); $path.Dispose(); $font.Dispose()
  $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $outPath
}

function Get-ExeIconPng($exePath, $outPath) {
  Add-Type -AssemblyName System.Drawing
  if (-not ('Hub.Icon' -as [type])) {
    $def = '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int PrivateExtractIcons(string file, int index, int cx, int cy, System.IntPtr[] icons, int[] ids, int n, int flags);'
    $def += ' [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);'
    Add-Type -Namespace Hub -Name Icon -MemberDefinition $def
  }
  $icons = New-Object IntPtr[] 1
  $ids = New-Object int[] 1
  $n = [Hub.Icon]::PrivateExtractIcons($exePath, 0, 256, 256, $icons, $ids, 1, 0)
  $bmp = $null
  if ($n -gt 0 -and $icons[0] -ne [IntPtr]::Zero) {
    try {
      $ico = [System.Drawing.Icon]::FromHandle($icons[0])
      $bmp = $ico.ToBitmap()
      $ico.Dispose()
      [void][Hub.Icon]::DestroyIcon($icons[0])
    } catch { }
  }
  if (-not $bmp) {
    try { $bmp = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath).ToBitmap() } catch { }
  }
  if (-not $bmp) { return $false }
  $out = New-Object System.Drawing.Bitmap 88, 88, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.PixelOffsetMode = 'HighQuality'
  $scale = [Math]::Min(88.0 / $bmp.Width, 88.0 / $bmp.Height)
  $w = [int][Math]::Round($bmp.Width * $scale); $h = [int][Math]::Round($bmp.Height * $scale)
  $g.DrawImage($bmp, [int]((88 - $w) / 2), [int]((88 - $h) / 2), $w, $h)
  $g.Dispose(); $bmp.Dispose()
  $out.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $out.Dispose()
  $true
}

function Get-UrlIconPng($address, $outPath) {
  $uri = $null
  if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri)) { return $false }
  foreach ($candidate in @(($uri.Scheme + '://' + $uri.Host + '/favicon.ico'), ($uri.Scheme + '://' + $uri.Host + '/favicon.png'), ($uri.Scheme + '://' + $uri.Host + '/apple-touch-icon.png'))) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
      & curl.exe -s -L --connect-timeout 3 --max-time 6 -o $tmp $candidate 2>$null
      if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 200)) {
        Add-Type -AssemblyName System.Drawing
        try {
          $img = [System.Drawing.Image]::FromFile($tmp)
        } catch { $img = $null }
        if ($img) {
          $out = New-Object System.Drawing.Bitmap 88, 88, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $g = [System.Drawing.Graphics]::FromImage($out)
          $g.InterpolationMode = 'HighQualityBicubic'
          $scale = [Math]::Min(88.0 / $img.Width, 88.0 / $img.Height)
          $w = [int][Math]::Round($img.Width * $scale); $h = [int][Math]::Round($img.Height * $scale)
          $g.DrawImage($img, [int]((88 - $w) / 2), [int]((88 - $h) / 2), $w, $h)
          $g.Dispose(); $img.Dispose()
          $out.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $out.Dispose()
          return $true
        }
      }
    } catch { } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
  $false
}

function Resolve-IconFile($item) {
  # built-in brands first
  try {
    $mark = Get-MarkFile $item
    if ($mark) { return $mark }

    $cache = Get-IconCachePath $item
    if (Test-Path $cache) { return $cache }

    $made = $false
    switch ($item.kind) {
      'exe' {
        $target = [string]$item.target
        if (Test-Path $target) { $made = Get-ExeIconPng $target $cache }
      }
      'url' {
        $made = Get-UrlIconPng ([string]$item.target) $cache
      }
    }
    if (-not $made) { [void](New-LetterIcon $item.name $cache) }
    $cache
  } catch {
    Write-GateLog ('ICON    ' + $item.name + ' :: ' + $_.Exception.Message)
    $null
  }
}


function New-IconBox($item) {
  $slot = New-Object System.Windows.Controls.Grid
  $slot.Width = 32
  $slot.Height = 32
  $slot.VerticalAlignment = 'Center'

  $file = Resolve-IconFile $item
  if ($file) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object System.Uri $file
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $bmp
    $img.Stretch = 'Uniform'
    $img.Width = 22
    $img.Height = 22
    $img.HorizontalAlignment = 'Center'
    $img.VerticalAlignment = 'Center'
    [void]$slot.Children.Add($img)
    return $slot
  }

  $slot.Visibility = 'Collapsed'
  $slot
}

function New-Tile($item, $disabled) {
  $b = New-Object System.Windows.Controls.Border
  $b.Width = 200
  $b.Height = 72
  $b.Margin = '0,0,16,0'
  $b.CornerRadius = 12
  $b.Padding = '12,0,12,0'
  if ($disabled) {
    $b.Background = New-Brush '#14171B'
    $b.BorderBrush = $cEdgeDisabled
    $b.Cursor = 'Arrow'
  } else {
    $b.Background = New-Object System.Windows.Media.SolidColorBrush (Get-Color '#181C22')
    $b.BorderBrush = $cLine
    $b.Cursor = 'Hand'
  }
  $b.BorderThickness = 1
  $b.IsEnabled = -not $disabled
  $b.Tag = $item
  $b.ToolTip = $item.note

  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.VerticalAlignment = 'Center'
  [void]$row.Children.Add((New-IconBox $item))

  $text = New-Object System.Windows.Controls.StackPanel
  $text.VerticalAlignment = 'Center'
  $text.Margin = '10,0,0,0'
  $text.Width = 128

  $n = New-Object System.Windows.Controls.TextBlock
  $n.Text = $item.name
  $n.FontFamily = $fontText
  $n.FontSize = 15
  $n.FontWeight = 'SemiBold'
  if ($disabled) { $n.Foreground = $cDisabledInk } else { $n.Foreground = $cText }
  $n.TextTrimming = 'CharacterEllipsis'
  [void]$text.Children.Add($n)

  $note = New-Object System.Windows.Controls.TextBlock
  $note.Text = $item.note
  $note.FontFamily = $fontText
  $note.FontSize = 12
  if ($disabled) { $note.Foreground = $cDisabledNote } else { $note.Foreground = $cMuted }
  $note.Margin = '0,2,0,0'
  $note.TextTrimming = 'CharacterEllipsis'
  [void]$text.Children.Add($note)

  [void]$row.Children.Add($text)
  $b.Child = $row

  if ($disabled) {
    $b.Opacity = 0.9
    return $b
  }
  $b.Focusable = $true
  [void][System.Windows.Input.KeyboardNavigation]::SetIsTabStop($b, $true)
  $b.Add_MouseEnter({
    $br = $this.Background
    $anim = New-Object System.Windows.Media.Animation.ColorAnimation ([System.Windows.Media.Color]::FromRgb(0x20, 0x26, 0x2F)), ([TimeSpan]::FromMilliseconds(100))
    $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
    $this.BorderBrush = $cLineHi
  })
  $b.Add_MouseLeave({
    $br = $this.Background
    $anim = New-Object System.Windows.Media.Animation.ColorAnimation ([System.Windows.Media.Color]::FromRgb(0x18, 0x1C, 0x22)), ([TimeSpan]::FromMilliseconds(120))
    $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
    if (-not $this.IsKeyboardFocused) { $this.BorderBrush = $cLine }
  })
  $b.Add_GotFocus({
    $this.BorderThickness = 2
    $this.BorderBrush = New-Brush '#8DB9FF'
  })
  $b.Add_LostFocus({
    $this.BorderThickness = 1
    $this.BorderBrush = $cLine
  })
  $b.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Enter' -or $e.Key -eq 'Space') { Invoke-HubItem $this.Tag; $e.Handled = $true }
  })
  $b.Add_MouseLeftButtonUp({ Invoke-HubItem $this.Tag })
  $b
}

function New-Link($text, $brush) {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontSize = 11.5
  $t.Foreground = $brush
  $t.Cursor = 'Hand'
  $t.Margin = '0,0,18,0'
  $t.Tag = $text
  $t
}

function New-HeaderButton($text, $w, $h, $strong) {
  $b = New-Object System.Windows.Controls.Border
  $b.Width = $w
  $b.Height = $h
  $b.CornerRadius = 8
  $b.Cursor = 'Hand'
  $b.VerticalAlignment = 'Center'
  $b.Margin = '8,0,0,0'
  if ($strong) { $b.Background = $cControl } else { $b.Background = [System.Windows.Media.Brushes]::Transparent }
  $b.BorderBrush = $cLine
  $b.BorderThickness = 1

  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontFamily = $fontText
  $t.FontSize = 13
  $t.FontWeight = 'SemiBold'
  $t.Foreground = $cText
  $t.HorizontalAlignment = 'Center'
  $t.VerticalAlignment = 'Center'
  $t.Tag = 'text'
  $b.Child = $t

  $b.Focusable = $true
  [void][System.Windows.Input.KeyboardNavigation]::SetIsTabStop($b, $true)
  $b.Add_MouseEnter({ $this.Background = $cControlHi; $this.BorderBrush = $cLineHi })
  $b.Add_MouseLeave({
    if ($strong) { $this.Background = $cControl } else { $this.Background = [System.Windows.Media.Brushes]::Transparent }
    if (-not $this.IsKeyboardFocused) { $this.BorderBrush = $cLine }
  })
  $b.Add_GotFocus({ $this.BorderThickness = 2; $this.BorderBrush = New-Brush '#8DB9FF' })
  $b.Add_LostFocus({ $this.BorderThickness = 1; $this.BorderBrush = $cLine })
  $b.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Enter' -or $e.Key -eq 'Space') { $this.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
  })
  $b
}

function New-Blocked($gate) {
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = 12
  $b.Padding = '20,18,20,16'
  $b.Background = $cRedWash
  $b.BorderBrush = $cRedEdge
  $b.BorderThickness = 1
  $b.HorizontalAlignment = 'Stretch'

  $grid = New-Object System.Windows.Controls.Grid
  [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $acts = New-Object System.Windows.Controls.ColumnDefinition
  $acts.Width = [System.Windows.GridLength]::new(396)
  [void]$grid.ColumnDefinitions.Add($acts)
  $b.Child = $grid

  $left = New-Object System.Windows.Controls.StackPanel
  $left.VerticalAlignment = 'Center'
  [void]$grid.Children.Add($left)

  $h = New-Object System.Windows.Controls.TextBlock
  $h.Text = 'Not safe to launch'
  $h.FontFamily = $fontText
  $h.FontSize = 15
  $h.FontWeight = 'SemiBold'
  $h.Foreground = $cRed
  [void]$left.Children.Add($h)

  $first = @($gate.Checks | Where-Object { $_.Fatal -and -not $_.Ok } | Select-Object -First 1)
  $detail = 'The tunnel is not doing its job.'
  if ($first.Count) { $detail = $first[0].Name + ' - ' + $first[0].Detail }
  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = $detail
  $sub.FontFamily = $fontText
  $sub.FontSize = 12
  $sub.Foreground = $cMuted
  $sub.Margin = '0,4,0,0'
  $sub.TextWrapping = 'Wrap'
  $sub.MaxWidth = 400
  [void]$left.Children.Add($sub)

  $rowBtns = New-Object System.Windows.Controls.StackPanel
  $rowBtns.Orientation = 'Horizontal'
  $rowBtns.HorizontalAlignment = 'Right'
  $rowBtns.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($rowBtns, 1)
  [void]$grid.Children.Add($rowBtns)

  $again = New-HeaderButton 'RE-CHECK' 92 44 $true
  $again.Margin = '0,0,8,0'
  $again.Add_MouseLeftButtonUp({ Recheck })
  [void]$rowBtns.Children.Add($again)

  $any = New-HeaderButton 'LAUNCH ANYWAY (LOGGED)' 288 44 $false
  $any.Margin = '0'
  $any.Add_MouseLeftButtonUp({
    $script:Override = $true
    Write-GateLog ('OVERRIDE  launched with failed gate: ' + (($script:LastGate.Checks | Where-Object { $_.Fatal -and -not $_.Ok } | ForEach-Object { $_.Name }) -join ', '))
    Render $script:LastGate
  })
  [void]$rowBtns.Children.Add($any)

  $b
}

# ---------------------------------------------------------------- window
$win = New-Object System.Windows.Window
$win.Width = 940
$win.Height = 764
$win.WindowStyle = 'None'
$win.ResizeMode = 'CanMinimize'   # gives the shell a minimise box to act on
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.WindowStartupLocation = 'CenterScreen'
$win.ShowInTaskbar = $true
$win.Title = 'AI Hub'
$hubIcon = Join-Path $here 'ai-hub.ico'
if (Test-Path $hubIcon) {
  try { $win.Icon = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$hubIcon) } catch { }
}

$root = New-Object System.Windows.Controls.Border
$root.CornerRadius = 16
$root.Background = $cInk
$root.BorderBrush = New-Brush '#2A323B'
$root.BorderThickness = 1
$root.Margin = '16'
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 30
$shadow.ShadowDepth = 0
$shadow.Opacity = 0.6
$shadow.Color = [System.Windows.Media.Colors]::Black
$root.Effect = $shadow
$win.Content = $root

$grid = New-Object System.Windows.Controls.Grid
$grid.Margin = '26,22,26,0'
foreach ($h in 'Auto', 'Auto', '*', 'Auto') {
  $rd = New-Object System.Windows.Controls.RowDefinition
  $rd.Height = $h
  [void]$grid.RowDefinitions.Add($rd)
}
$root.Child = $grid

# header
$header = New-Object System.Windows.Controls.Grid
$header.Height = 56
[System.Windows.Controls.Grid]::SetRow($header, 0)
[void]$header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
$col2 = New-Object System.Windows.Controls.ColumnDefinition
$col2.Width = [System.Windows.GridLength]::new(252)
[void]$header.ColumnDefinitions.Add($col2)
[void]$grid.Children.Add($header)

$drag = New-Object System.Windows.Controls.StackPanel
$drag.Orientation = 'Horizontal'
$drag.Background = [System.Windows.Media.Brushes]::Transparent
[void]$header.Children.Add($drag)

$markBorder = New-Object System.Windows.Controls.Border
$markBorder.Width = 44
$markBorder.Height = 44
$markBorder.CornerRadius = 12
$markBorder.Background = $cCardHi
$markBorder.BorderBrush = $cLine
$markBorder.BorderThickness = 1
$markBorder.VerticalAlignment = 'Center'
$canvas = New-Object System.Windows.Controls.Canvas
$canvas.Width = 44
$canvas.Height = 44
$star = New-Object System.Windows.Shapes.Path
$star.Data = [System.Windows.Media.Geometry]::Parse('M22,8 C23.5,15.5 27.5,19 34,20 C27.5,21 23.5,24.5 22,32 C20.5,24.5 16.5,21 10,20 C16.5,19 20.5,15.5 22,8 Z')
$star.Fill = $cText
[void]$canvas.Children.Add($star)
$baseline = New-Object System.Windows.Shapes.Rectangle
$baseline.Width = 12
$baseline.Height = 2
$baseline.Fill = $cDim
[System.Windows.Controls.Canvas]::SetLeft($baseline, 16)
[System.Windows.Controls.Canvas]::SetTop($baseline, 35)
[void]$canvas.Children.Add($baseline)
$markBorder.Child = $canvas
[void]$drag.Children.Add($markBorder)

$heads = New-Object System.Windows.Controls.StackPanel
$heads.VerticalAlignment = 'Center'
$heads.Margin = '12,0,0,0'
[void]$drag.Children.Add($heads)

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = 'AI Hub'
$title.FontFamily = $fontDisplay
$title.FontSize = 26
$title.FontWeight = 'SemiBold'
$title.Foreground = $cText
$title.LineHeight = 32
[void]$heads.Children.Add($title)

$subtitle = New-Object System.Windows.Controls.TextBlock
$subtitle.Text = 'Tunnel-checked apps and links'
$subtitle.FontFamily = $fontText
$subtitle.FontSize = 14
$subtitle.Foreground = $cMuted
$subtitle.LineHeight = 20
[void]$heads.Children.Add($subtitle)

$drag.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

$buttons = New-Object System.Windows.Controls.StackPanel
$buttons.Orientation = 'Horizontal'
$buttons.VerticalAlignment = 'Center'
$buttons.HorizontalAlignment = 'Right'
[System.Windows.Controls.Grid]::SetColumn($buttons, 1)
[void]$header.Children.Add($buttons)

$btnAdd = New-HeaderButton 'ADD' 80 44 $false
$btnAdd.Add_MouseLeftButtonUp({ Show-AddDialog })
[void]$buttons.Children.Add($btnAdd)

$btnRecheck = New-HeaderButton 'RE-CHECK' 112 44 $true
$btnRecheck.Add_MouseLeftButtonUp({ Recheck })
[void]$buttons.Children.Add($btnRecheck)

$close = New-Object System.Windows.Controls.Border
$close.Width = 44
$close.Height = 44
$close.CornerRadius = 10
$close.Background = [System.Windows.Media.Brushes]::Transparent
$close.BorderBrush = [System.Windows.Media.Brushes]::Transparent
$close.BorderThickness = 1
$close.Cursor = 'Hand'
$close.Margin = '8,0,0,0'
[void]$buttons.Children.Add($close)
$closeCanvas = New-Object System.Windows.Controls.Canvas
$closeCanvas.Width = 12
$closeCanvas.Height = 12
$c1 = New-Object System.Windows.Shapes.Line
$c1.X1 = 0; $c1.Y1 = 0; $c1.X2 = 12; $c1.Y2 = 12
$c1.Stroke = $cMuted; $c1.StrokeThickness = 1.5
$c2 = New-Object System.Windows.Shapes.Line
$c2.X1 = 12; $c2.Y1 = 0; $c2.X2 = 0; $c2.Y2 = 12
$c2.Stroke = $cMuted; $c2.StrokeThickness = 1.5
[void]$closeCanvas.Children.Add($c1)
[void]$closeCanvas.Children.Add($c2)
$close.Child = $closeCanvas
$close.Add_MouseEnter({ $this.Background = $cCardHi; $this.BorderBrush = $cLineHi })
$close.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent; $this.BorderBrush = [System.Windows.Media.Brushes]::Transparent })
$close.Add_MouseLeftButtonUp({ $win.Close() })

# tunnel check panel: heading, summary, two rows of seven, detail strip
$statusPanel = New-Object System.Windows.Controls.Border
$statusPanel.Margin = '0,16,0,0'
$statusPanel.CornerRadius = 14
$statusPanel.Background = $cPanel
$statusPanel.BorderBrush = $cLine
$statusPanel.BorderThickness = 1
$statusPanel.Padding = '15,15,9,15'
[System.Windows.Controls.Grid]::SetRow($statusPanel, 1)
[void]$grid.Children.Add($statusPanel)

$statusGrid = New-Object System.Windows.Controls.Grid
$statusPanel.Child = $statusGrid
foreach ($hgt in 24, 52, 52, 64) {
  $rd = New-Object System.Windows.Controls.RowDefinition
  $rd.Height = [System.Windows.GridLength]::new($hgt)
  [void]$statusGrid.RowDefinitions.Add($rd)
}

$headRow = New-Object System.Windows.Controls.Grid
$headRow.Margin = '0,0,0,8'
[System.Windows.Controls.Grid]::SetRow($headRow, 0)
[void]$statusGrid.Children.Add($headRow)
[void]$headRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
$sumCol = New-Object System.Windows.Controls.ColumnDefinition
$sumCol.Width = [System.Windows.GridLength]::Auto
[void]$headRow.ColumnDefinitions.Add($sumCol)

$checksHeading = New-Object System.Windows.Controls.TextBlock
$checksHeading.Text = 'Tunnel checks'
$checksHeading.FontFamily = $fontText
$checksHeading.FontSize = 16
$checksHeading.FontWeight = 'SemiBold'
$checksHeading.Foreground = $cText
$checksHeading.VerticalAlignment = 'Center'
[void]$headRow.Children.Add($checksHeading)

$summary = New-Object System.Windows.Controls.TextBlock
$summary.FontFamily = $fontText
$summary.FontSize = 13
$summary.FontWeight = 'SemiBold'
$summary.Foreground = $cDim
$summary.VerticalAlignment = 'Center'
$summary.HorizontalAlignment = 'Right'
[System.Windows.Controls.Grid]::SetColumn($summary, 1)
[void]$headRow.Children.Add($summary)

$colExits = New-Object System.Windows.Controls.ColumnDefinition
$colExits.Width = [System.Windows.GridLength]::Auto
[void]$headRow.ColumnDefinitions.Add($colExits)

$btnExits = New-HeaderButton 'EXITS' 76 30 $false
$btnExits.Margin = '12,0,0,0'
$btnExits.VerticalAlignment = 'Center'
$btnExits.ToolTip = 'Add or remove the exit addresses the hub will accept'
$btnExits.Add_MouseLeftButtonUp({ Show-ExitsDialog })
[System.Windows.Controls.Grid]::SetColumn($btnExits, 2)
[void]$headRow.Children.Add($btnExits)

$rowA = New-Object System.Windows.Controls.WrapPanel
$rowA.Width = 840
[System.Windows.Controls.Grid]::SetRow($rowA, 1)
[void]$statusGrid.Children.Add($rowA)

$rowB = New-Object System.Windows.Controls.WrapPanel
$rowB.Width = 840
[System.Windows.Controls.Grid]::SetRow($rowB, 2)
[void]$statusGrid.Children.Add($rowB)

$strip = New-Object System.Windows.Controls.Border
$strip.Height = 64
$strip.CornerRadius = 8
$strip.Background = $cField
$strip.BorderBrush = $cLine
$strip.BorderThickness = 1
$strip.Padding = '12,5,12,5'
[System.Windows.Controls.Grid]::SetRow($strip, 3)
[void]$statusGrid.Children.Add($strip)

$stripStack = New-Object System.Windows.Controls.StackPanel
$strip.Child = $stripStack

$stripTitle = New-Object System.Windows.Controls.TextBlock
$stripTitle.FontFamily = $fontText
$stripTitle.FontSize = 15
$stripTitle.FontWeight = 'SemiBold'
$stripTitle.Foreground = $cText
$stripTitle.LineHeight = 20
[void]$stripStack.Children.Add($stripTitle)

$stripDetail = New-Object System.Windows.Controls.TextBlock
$stripDetail.FontFamily = $fontText
$stripDetail.FontSize = 12
$stripDetail.Foreground = $cMuted
$stripDetail.TextWrapping = 'Wrap'
$stripDetail.LineHeight = 16
$stripDetail.MaxHeight = 32
[void]$stripStack.Children.Add($stripDetail)

$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$scroll.Margin = '0,14,0,0'
$scroll.Padding = '0,0,6,0'
[System.Windows.Controls.Grid]::SetRow($scroll, 2)
[void]$grid.Children.Add($scroll)

# dark scrollbar, so the default light Windows one does not break the surface
$sbXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ScrollBar">
  <Setter Property="Width" Value="8"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Grid Background="Transparent">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.DecreaseRepeatButton>
              <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
            </Track.DecreaseRepeatButton>
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border CornerRadius="4" Background="#2E3742" Margin="1,0"/>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
            <Track.IncreaseRepeatButton>
              <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
            </Track.IncreaseRepeatButton>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@
$scroll.Resources[[System.Windows.Controls.Primitives.ScrollBar]] = [System.Windows.Markup.XamlReader]::Parse($sbXaml)

$tileHost = New-Object System.Windows.Controls.StackPanel
$scroll.Content = $tileHost

# footer
$footer = New-Object System.Windows.Controls.Grid
$footer.Margin = '0,10,0,14'
[System.Windows.Controls.Grid]::SetRow($footer, 3)
[void]$grid.Children.Add($footer)
$fText = New-Object System.Windows.Controls.TextBlock
$fText.FontSize = 10.5
$fText.Foreground = $cDim
$footer.Children.Add($fText) | Out-Null

$win.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape') { $win.Close() }
})

# Drag anything onto the window: a program, a shortcut, a .url, a link from a
# browser. It opens ADD with the fields filled in, so dropping is the fast path
# and the dialog is just the confirmation.
$win.AllowDrop = $true
$win.Add_DragOver({
  param($s, $e)
  $ok = $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -or
        $e.Data.GetDataPresent([System.Windows.DataFormats]::Text)
  if ($ok) { $e.Effects = [System.Windows.DragDropEffects]::Copy } else { $e.Effects = [System.Windows.DragDropEffects]::None }
  $e.Handled = $true
})
$win.Add_Drop({
  param($s, $e)
  $drop = Resolve-Drop $e.Data
  $e.Handled = $true
  if (-not $drop.Kind -or -not $drop.Target) {
    $fText.Text = 'That item cannot be added. Drop a program, a shortcut, a .url file or a web link.'
    return
  }
  Write-GateLog ("DROP    {0} {1}" -f $drop.Kind, $drop.Target)
  Show-AddDialog -preName $drop.Name -preTarget $drop.Target -preKind $drop.Kind
})
$win.Add_Closing({
  # Shut down without blocking and without swallowing a click that races us:
  # stop the timers, let go of the mutex so a reopen starts a fresh hub, and ask
  # the worker to stop without waiting for it (the process exits shortly anyway).
  $script:Closing = $true
  try { $script:GateTimer.Stop() } catch { }
  try { $showTimer.Stop() } catch { }
  try { $script:Reaper.Stop() } catch { }
  try { if ($script:HubIsFirst) { [void]$script:HubMutex.ReleaseMutex() } } catch { }
  try { Stop-GateWorker } catch { }
})
$win.Add_ContentRendered({
  $win.WindowState = 'Normal'
  $win.Activate()
  Write-GateLog 'WINDOW shown'
  try {
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    [Hub.Win]::SwitchToThisWindow($hw, $true)
  } catch { }
  # Clicking the taskbar button of the active window sends SC_MINIMIZE. A
  # borderless popup has no frame to do that for us, so answer it here: second
  # click minimises, click again restores.
  try {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
    if ($src) {
      $script:HwndSource = $src
      $src.AddHook({
        param($h, $msg, $w, $l, [ref]$handled)
        try {
          if ($msg -eq 0x0112) {
            $cmd = $w.ToInt32() -band 0xFFF0
            if ($cmd -eq 0xF020) {
              # Off the message, not inside it: touching the window synchronously
              # here re-enters WPF while the shell is waiting for this call.
              [void]$win.Dispatcher.BeginInvoke([Action]{ $win.WindowState = 'Minimized' })
              $handled.Value = $true
            } elseif ($cmd -eq 0xF120) {
              [void]$win.Dispatcher.BeginInvoke([Action]{ $win.WindowState = 'Normal' })
              $handled.Value = $true
            }
          }
        } catch { }
        return [IntPtr]::Zero
      })
    }
  } catch { Write-GateLog ('HOOK failed: ' + $_.Exception.Message) }
})

# ---------------------------------------------------------------- render
function Set-Summary($verdict, $brush, $counts) {
  $summary.Inlines.Clear()
  $v = New-Object System.Windows.Documents.Run $verdict
  $v.FontWeight = 'SemiBold'
  $v.Foreground = $brush
  [void]$summary.Inlines.Add($v)
  if ($counts) {
    $cRun = New-Object System.Windows.Documents.Run ('  |  ' + $counts)
    $cRun.FontWeight = 'Normal'
    $cRun.Foreground = $cDim
    [void]$summary.Inlines.Add($cRun)
  }
}

function Show-Checking {
  $rowA.Children.Clear()
  $rowB.Children.Clear()
  Set-Summary 'Checking tunnel...' $cBlue ''
  $stripTitle.Text = 'Checking the tunnel'
  $stripTitle.Foreground = $cBlue
  $stripDetail.Text = 'Apps and links are available once the checks finish and the gate passes.'
  $tileHost.Children.Clear()
  $fText.Text = 'Checking the tunnel.'
}

function Show-CheckFailed($message) {
  $rowA.Children.Clear()
  $rowB.Children.Clear()
  Set-Summary 'Checks failed' $cRed ''
  $stripTitle.Text = 'Checks failed'
  $stripTitle.Foreground = $cRed
  $stripDetail.Text = $message
  $tileHost.Children.Clear()
  $fText.Text = 'Checks failed. Nothing can be launched.'
}

function Select-Check($control) {
  $entry = $script:Pills | Where-Object { $_.Control -eq $control } | Select-Object -First 1
  if (-not $entry) { return }
  $script:Selected = $entry
  foreach ($p in $script:Pills) {
    if ($p -eq $entry) { $p.Control.BorderBrush = $cSelected }
    else { $p.Control.BorderBrush = $p.Edge }
  }
  $c = $entry.Check
  $stripTitle.Text = $c.Name
  $stripDetail.Text = $c.Detail
  if (-not $c.Ok -and $c.Fatal) { $stripTitle.Foreground = $cRed }
  elseif (-not $c.Ok) { $stripTitle.Foreground = $cAmber }
  else { $stripTitle.Foreground = $cGreen }
}

function Render($gate) {
  $script:LastGate = $gate

  $checks = @($gate.Checks)
  $fails = @($checks | Where-Object { -not $_.Ok -and $_.Fatal })
  $warns = @($checks | Where-Object { -not $_.Ok -and -not $_.Fatal })
  $passes = @($checks | Where-Object { $_.Ok })

  $parts = @()
  if ($fails.Count) { $parts += "$($fails.Count) failed" }
  if ($warns.Count) { $parts += "$($warns.Count) warning" }
  if ($passes.Count) { $parts += "$($passes.Count) pass" }
  $counts = $parts -join '  |  '

  $rowA.Children.Clear()
  $rowB.Children.Clear()
  $script:Pills = @()
  $i = 0
  foreach ($c in $checks) {
    $pill = New-Pill $c
    $script:Pills += [pscustomobject]@{ Control = $pill; Check = $c; Edge = $pill.Tag.Edge }
    if ($i -lt 7) { [void]$rowA.Children.Add($pill) } else { [void]$rowB.Children.Add($pill) }
    $i++
  }

  if (-not $gate.Pass -and -not $script:Override) { Set-Summary 'Launch blocked' $cRed $counts }
  elseif ($script:Override) { Set-Summary 'Override active' $cRed $counts }
  else { Set-Summary 'Launch enabled' $cText $counts }

  # first failure selected, then first warning, then first pass
  $target = $null
  if ($fails.Count) { $target = $fails[0] }
  elseif ($warns.Count) { $target = $warns[0] }
  elseif ($passes.Count) { $target = $passes[0] }
  if ($target) {
    $entry = $script:Pills | Where-Object { $_.Check -eq $target } | Select-Object -First 1
    if ($entry) { Select-Check $entry.Control }
  } else {
    $stripTitle.Text = 'Checks'
    $stripTitle.Foreground = $cText
    $stripDetail.Text = ''
  }

  $tileHost.Children.Clear()
  $fText.Text = 'Esc closes. AI Hub stays open after a launch.'

  $blocked = (-not $gate.Pass -and -not $script:Override)
  if ($blocked) { [void]$tileHost.Children.Add((New-Blocked $gate)) }

  foreach ($grp in $script:GroupOrder) {
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $grp
    $label.FontFamily = $fontText
    $label.FontSize = 16
    $label.FontWeight = 'SemiBold'
    $label.Foreground = $cText
    $label.Margin = '0,4,0,12'
    [void]$tileHost.Children.Add($label)

    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Width = 884
    foreach ($it in ($script:Items | Where-Object { $_.group -eq $grp })) {
      [void]$wrap.Children.Add((New-Tile $it $blocked))
    }
    [void]$tileHost.Children.Add($wrap)

    $gap = New-Object System.Windows.Controls.Border
    $gap.Height = 10
    [void]$tileHost.Children.Add($gap)
  }
}

function Stop-GateWorker {
  # Never block the window thread: BeginStop and hand the worker to the reaper.
  # A synchronous Stop() can sit for seconds on a stuck DNS or socket call.
  $ps = $script:GatePS
  $rs = $script:GateRunspace
  $script:GatePS = $null
  $script:GateAsync = $null
  $script:GateRunspace = $null
  if (-not $ps) { return }
  $entry = [pscustomobject]@{ Ps = $ps; Rs = $rs; Async = $null }
  try {
    if ($ps.InvocationStateInfo.State -eq 'Running') { $entry.Async = $ps.BeginStop($null, $null) }
  } catch { }
  [void]$script:Zombies.Add($entry)
}

# Finishes stopped workers when they actually stop. Runs on the UI thread but only
# touches workers whose stop has already reported complete.
$script:Reaper = New-Object System.Windows.Threading.DispatcherTimer
$script:Reaper.Interval = [TimeSpan]::FromMilliseconds(400)
$script:Reaper.Add_Tick({
  if ($script:Zombies.Count -eq 0) { return }
  $keep = New-Object System.Collections.ArrayList
  foreach ($z in $script:Zombies) {
    if ($z.Async -and -not $z.Async.IsCompleted) { [void]$keep.Add($z); continue }
    try { if ($z.Async) { [void]$z.Ps.EndStop($z.Async) } } catch { }
    try { $z.Ps.Dispose() } catch { }
    try { if ($z.Rs) { $z.Rs.Dispose() } } catch { }
  }
  $script:Zombies = $keep
})
$script:Reaper.Start()

function Recheck {
  # While a check is outstanding (running or not yet collected) a second press is
  # ignored rather than queued: the answer is already on its way.
  if ($script:GatePS) { return }

  # No tile may launch on the old verdict while a new one is being measured.
  $script:LastGate = $null
  $script:Override = $false
  $tileHost.Children.Clear()
  Show-Checking
  $fText.Text = 'Checking the tunnel...'

  # The checks do network and DNS work for ~8 s. Running them on the UI thread
  # freezes the window: no repaint, no click, no raise. They run in a runspace and
  # the window stays live while they finish.
  Stop-GateWorker
  try {
    $script:GateRunspace = [runspacefactory]::CreateRunspace()
    $script:GateRunspace.Open()
    $script:GatePS = [powershell]::Create()
    $script:GatePS.Runspace = $script:GateRunspace
    [void]$script:GatePS.AddScript({
      param($checkPath)
      $ErrorActionPreference = 'Stop'   # a runspace does not inherit the caller's
      . $checkPath
      Test-HubGate
    }).AddArgument((Join-Path $here 'Check-Tunnel.ps1'))
    $script:GateAsync = $script:GatePS.BeginInvoke()
    Write-GateLog 'CHECK started (background)'
  } catch {
    Write-GateLog ('CHECK failed to start: ' + $_.Exception.Message)
    Stop-GateWorker
    Show-CheckFailed $_.Exception.Message
    $fText.Text = 'Checks could not run. Nothing can be launched.'
    return
  }
  if (-not $script:GateTimer.IsEnabled) { $script:GateTimer.Start() }
}

# Collect the background checks without blocking the window.
$script:GateTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GateTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:GateTimer.Add_Tick({
  if (-not $script:GatePS -or -not $script:GateAsync) { return }
  if (-not $script:GateAsync.IsCompleted) { return }
  $script:GateTimer.Stop()
  try {
    $out = $script:GatePS.EndInvoke($script:GateAsync)
    $g = $out | Where-Object { $_ -and $_.PSObject.Properties['Checks'] } | Select-Object -Last 1
    if (-not $g) {
      $msg = ($script:GatePS.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      throw ('no result from checks: ' + $msg)
    }
    if (@($g.Checks).Count -ne 14) {
      throw ('checks returned ' + @($g.Checks).Count + ' of 14 results - not trusted')
    }
    Write-GateLog ('GATE  pass=' + $g.Pass + '  exit=' + $g.Ip + ' ' + $g.Country)
    Render $g
  } catch {
    Write-GateLog ('CHECK error: ' + $_.Exception.Message)
    $script:LastGate = $null
    Show-CheckFailed $_.Exception.Message
    $tileHost.Children.Clear()
    $fText.Text = 'Checks failed. Nothing can be launched.'
  } finally {
    Stop-GateWorker
  }
})

# ---------------------------------------------------------------- add dialog
function New-Field($label, $hint) {
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = '0,0,0,14'

  $l = New-Object System.Windows.Controls.TextBlock
  $l.Text = $label.ToUpper()
  $l.FontSize = 9.5
  $l.Foreground = $cDim
  $l.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
  $l.Margin = '0,0,0,6'
  [void]$sp.Children.Add($l)

  $tb = New-Object System.Windows.Controls.TextBox
  $tb.FontSize = 13
  $tb.Padding = '9,7,9,7'
  $tb.Background = $cField
  $tb.Foreground = $cText
  $tb.CaretBrush = $cText
  $tb.BorderThickness = 1
  $tb.BorderBrush = $cLine
  $tb.ToolTip = $hint
  $tb.Tag = $label
  $tb.FocusVisualStyle = $null
  $tb.Add_GotFocus({ $this.BorderBrush = $cLineHi })
  $tb.Add_LostFocus({ $this.BorderBrush = $cLine })
  [void]$sp.Children.Add($tb)

  $sp
}

function Save-Exits($map) {
  $items = @()
  foreach ($k in $map.Keys) { $items += [pscustomobject]@{ ip = $k; label = $map[$k] } }
  $out = [pscustomobject]@{ exits = $items }
  ConvertTo-Json -InputObject $out -Depth 4 | Set-Content -LiteralPath (Join-Path $here 'exits.json') -Encoding UTF8
}

function Show-ExitsDialog {
  $dlg = New-Object System.Windows.Window
  $dlg.Width = 560
  $dlg.Height = 470
  $dlg.WindowStyle = 'None'
  $dlg.ResizeMode = 'NoResize'
  $dlg.AllowsTransparency = $true
  $dlg.Background = [System.Windows.Media.Brushes]::Transparent
  $dlg.WindowStartupLocation = 'CenterOwner'
  $dlg.Owner = $win
  $dlg.Title = 'Approved exits'

  $shell = New-Object System.Windows.Controls.Border
  $shell.CornerRadius = 16
  $shell.Background = $cInk
  $shell.BorderBrush = $cLine
  $shell.BorderThickness = 1
  $shell.Margin = '12'
  $dlg.Content = $shell

  $outer = New-Object System.Windows.Controls.StackPanel
  $outer.Margin = '24,20,24,18'
  $shell.Child = $outer

  $h = New-Object System.Windows.Controls.TextBlock
  $h.Text = 'Approved exits'
  $h.FontFamily = $fontDisplay
  $h.FontSize = 22
  $h.FontWeight = 'SemiBold'
  $h.Foreground = $cText
  [void]$outer.Children.Add($h)

  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = 'The hub only launches when its measured exit is one of these addresses.'
  $sub.FontFamily = $fontText
  $sub.FontSize = 12
  $sub.Foreground = $cMuted
  $sub.Margin = '0,4,0,14'
  $sub.TextWrapping = 'Wrap'
  [void]$outer.Children.Add($sub)

  $list = New-Object System.Windows.Controls.StackPanel
  [void]$outer.Children.Add($list)

  $err = New-Object System.Windows.Controls.TextBlock
  $err.FontFamily = $fontText
  $err.FontSize = 12
  $err.Foreground = $cRed
  $err.Margin = '0,6,0,0'
  [void]$outer.Children.Add($err)

  $ipBox = New-Object System.Windows.Controls.TextBox
  $ipBox.Width = 170
  $ipBox.Height = 40
  $ipBox.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
  $ipBox.FontSize = 13
  $ipBox.Padding = '9,8,9,8'
  $ipBox.Background = $cField
  $ipBox.Foreground = $cText
  $ipBox.CaretBrush = $cText
  $ipBox.BorderBrush = $cLine
  $ipBox.BorderThickness = 1
  $ipBox.ToolTip = 'e.g. 198.51.100.7'

  $labelBox = New-Object System.Windows.Controls.TextBox
  $labelBox.Width = 200
  $labelBox.Height = 40
  $labelBox.FontFamily = $fontText
  $labelBox.FontSize = 13
  $labelBox.Padding = '9,8,9,8'
  $labelBox.Background = $cField
  $labelBox.Foreground = $cText
  $labelBox.CaretBrush = $cText
  $labelBox.BorderBrush = $cLine
  $labelBox.BorderThickness = 1
  $labelBox.ToolTip = 'e.g. My server - Los Angeles'

  $addLabels = New-Object System.Windows.Controls.StackPanel
  $addLabels.Orientation = 'Horizontal'
  $addLabels.Margin = '0,12,0,4'
  $lab1 = New-Object System.Windows.Controls.TextBlock
  $lab1.Text = 'IP ADDRESS'
  $lab1.Width = 170
  $lab1.FontFamily = $fontText
  $lab1.FontSize = 10
  $lab1.Foreground = $cDim
  [void]$addLabels.Children.Add($lab1)
  $lab2 = New-Object System.Windows.Controls.TextBlock
  $lab2.Text = 'LABEL'
  $lab2.Width = 208
  $lab2.Margin = '8,0,0,0'
  $lab2.FontFamily = $fontText
  $lab2.FontSize = 10
  $lab2.Foreground = $cDim
  [void]$addLabels.Children.Add($lab2)
  [void]$outer.Children.Add($addLabels)

  $addRow = New-Object System.Windows.Controls.StackPanel
  $addRow.Orientation = 'Horizontal'
  $addRow.Margin = '0,10,0,0'
  [void]$addRow.Children.Add($ipBox)
  $gapBox = New-Object System.Windows.Controls.Border
  $gapBox.Width = 8
  [void]$addRow.Children.Add($gapBox)
  [void]$addRow.Children.Add($labelBox)
  $addBtn = New-HeaderButton 'ADD' 88 40 $true
  [void]$addRow.Children.Add($addBtn)
  [void]$outer.Children.Add($addRow)

  $drawList = {
    $list.Children.Clear()
    foreach ($k in $script:AllowedExits.Keys) {
      $row = New-Object System.Windows.Controls.Border
      $row.Height = 40
      $row.Margin = '0,0,0,6'
      $row.CornerRadius = 8
      $row.Background = $cCard
      $row.BorderBrush = $cLine
      $row.BorderThickness = 1
      $row.Padding = '12,0,12,0'

      $grid = New-Object System.Windows.Controls.Grid
      [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
      $cIpHolder = New-Object System.Windows.Controls.ColumnDefinition
      $cIpHolder.Width = [System.Windows.GridLength]::new(136)
      [void]$grid.ColumnDefinitions.Add($cIpHolder)
      $cLabel = New-Object System.Windows.Controls.ColumnDefinition
      [void]$grid.ColumnDefinitions.Add($cLabel)
      $cRemove = New-Object System.Windows.Controls.ColumnDefinition
      $cRemove.Width = [System.Windows.GridLength]::new(74)
      [void]$grid.ColumnDefinitions.Add($cRemove)

      $ipText = New-Object System.Windows.Controls.TextBlock
      $ipText.Text = $k
      $ipText.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
      $ipText.FontSize = 13
      $ipText.Foreground = $cText
      $ipText.VerticalAlignment = 'Center'
      $ipText.HorizontalAlignment = 'Left'
      [System.Windows.Controls.Grid]::SetColumn($ipText, 1)
      [void]$grid.Children.Add($ipText)

      $labelText = New-Object System.Windows.Controls.TextBlock
      $labelText.Text = $script:AllowedExits[$k]
      $labelText.FontFamily = $fontText
      $labelText.FontSize = 12
      $labelText.Foreground = $cMuted
      $labelText.VerticalAlignment = 'Center'
      $labelText.Margin = '0,0,10,0'
      $labelText.TextTrimming = 'CharacterEllipsis'
      [System.Windows.Controls.Grid]::SetColumn($labelText, 2)
      [void]$grid.Children.Add($labelText)

      $remove = New-Object System.Windows.Controls.TextBlock
      $remove.Text = 'REMOVE'
      $remove.FontFamily = $fontText
      $remove.FontSize = 11
      $remove.FontWeight = 'SemiBold'
      $remove.Foreground = $cDim
      $remove.Cursor = 'Hand'
      $remove.VerticalAlignment = 'Center'
      $remove.HorizontalAlignment = 'Right'
      $remove.Tag = $k
      $remove.Add_MouseEnter({ $this.Foreground = $cRed })
      $remove.Add_MouseLeave({ $this.Foreground = $cDim })
      $remove.Add_MouseLeftButtonUp({
        $key = $this.Tag
        $next = [ordered]@{}
        foreach ($kk in $script:AllowedExits.Keys) { if ($kk -ne $key) { $next[$kk] = $script:AllowedExits[$kk] } }
        if ($next.Count -eq 0) { $err.Text = 'Keep at least one approved exit.'; return }
        $script:AllowedExits = $next
        Save-Exits $script:AllowedExits
        Write-GateLog ("EXITS   removed " + $key)
        & $drawList
        $err.Text = 'Removed. Press RE-CHECK to measure again.'
      })
      [System.Windows.Controls.Grid]::SetColumn($remove, 3)
      [void]$grid.Children.Add($remove)

      $row.Child = $grid
      [void]$list.Children.Add($row)
    }
  }
  & $drawList

  $addBtn.Add_MouseLeftButtonUp({
    $ip = $ipBox.Text.Trim()
    $label = $labelBox.Text.Trim()
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $err.Text = 'That is not an IPv4 address.'; return }
    if (-not $label) { $label = 'Approved exit' }
    if ($script:AllowedExits.Contains($ip)) { $err.Text = 'That address is already approved.'; return }
    $next = [ordered]@{}
    foreach ($kk in $script:AllowedExits.Keys) { $next[$kk] = $script:AllowedExits[$kk] }
    $next[$ip] = $label
    $script:AllowedExits = $next
    Save-Exits $script:AllowedExits
    Write-GateLog ("EXITS   added " + $ip + "  " + $label)
    $ipBox.Text = ''
    $labelBox.Text = ''
    & $drawList
    $err.Text = 'Added. Press RE-CHECK to measure again.'
  })

  $actions = New-Object System.Windows.Controls.StackPanel
  $actions.Orientation = 'Horizontal'
  $actions.HorizontalAlignment = 'Right'
  $actions.Margin = '0,14,0,0'
  [void]$outer.Children.Add($actions)
  $closeBtn = New-HeaderButton 'CLOSE' 96 44 $false
  $closeBtn.Add_MouseLeftButtonUp({ $dlg.Close() })
  [void]$actions.Children.Add($closeBtn)

  $dlg.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $dlg.Close() }
  })
  $dlg.ShowDialog() | Out-Null
}
function Add-HubItem {
  param($name, $note, $kind, $target, $group, [ref]$message)
  $name = ([string]$name).Trim()
  $note = ([string]$note).Trim()
  $target = ([string]$target).Trim()
  $group = ([string]$group).Trim()
  if (-not $group) {
    switch ($kind) {
      'cli'   { $group = 'Terminals' }
      'url'   { $group = 'Web consoles' }
      default { $group = 'Desktop apps' }
    }
  }
  if (-not $name -or -not $target) { $message.Value = 'Name and target are required.'; return $false }
  if ($kind -eq 'url' -and $target -notmatch '^[a-zA-Z]+://') { $target = 'https://' + $target }
  try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = [object[]]@($cfg.items)
    $list += [pscustomobject]@{
      name = $name; note = $note; kind = $kind; target = $target; group = $group; enabled = $true
    }
    $out = [pscustomobject]@{ items = $list }
    ConvertTo-Json -InputObject $out -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    Load-Items
    Write-GateLog ("ADD     {0} :: {1} {2}" -f $name, $kind, $target)
    if ($script:LastGate) { Render $script:LastGate }
    $message.Value = ''
    return $true
  } catch {
    $message.Value = 'Could not save: ' + $_.Exception.Message
    return $false
  }
}
function Resolve-Drop($data) {
  # Turn whatever was dropped into a tile candidate: name, kind, target.
  $out = [pscustomobject]@{ Name = $null; Kind = $null; Target = $null; Group = $null }
  try {
    if ($data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
      $path = @($data.GetData([System.Windows.DataFormats]::FileDrop))[0]
      if (-not $path) { return $out }
      $leaf = Split-Path $path -Leaf
      $ext = [IO.Path]::GetExtension($path).ToLower()

      if ($ext -eq '.lnk') {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($path)
        $out.Name = [IO.Path]::GetFileNameWithoutExtension($leaf)
        if ($lnk.TargetPath -match '^https?://') { $out.Kind = 'url'; $out.Target = $lnk.TargetPath }
        else { $out.Kind = 'exe'; $out.Target = $lnk.TargetPath }
      }
      elseif ($ext -eq '.url') {
        $out.Kind = 'url'
        $out.Name = [IO.Path]::GetFileNameWithoutExtension($leaf)
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
          if ($line -match '^URL=(.+)$') { $out.Target = $Matches[1].Trim() }
        }
      }
      elseif ($ext -eq '.exe') {
        $out.Kind = 'exe'
        $out.Name = [IO.Path]::GetFileNameWithoutExtension($leaf)
        $out.Target = $path
      }
      elseif ($ext -in @('.txt', '.md', '.ps1', '.bat', '.cmd')) {
        # a command file: run it in a terminal
        $out.Kind = 'cli'
        $out.Name = [IO.Path]::GetFileNameWithoutExtension($leaf)
        $out.Target = '"' + $path + '"'
      }
      else { return $out }
    }
    else {
      $text = $null
      foreach ($fmt in @('UniformResourceLocatorW', 'UniformResourceLocator', [System.Windows.DataFormats]::Text)) {
        if (-not $text -and $data.GetDataPresent($fmt)) { $text = [string]$data.GetData($fmt) }
      }
      if ($text -and $text -match '^(https?://|www\.)') {
        $out.Kind = 'url'
        $out.Target = $text.Trim()
        $uri = $null
        if ([Uri]::TryCreate($out.Target, [UriKind]::Absolute, [ref]$uri)) {
          $out.Name = $uri.Host -replace '^www\.', ''
        } else { $out.Name = $out.Target }
      }
    }
  } catch { }
  $out
}

function Show-AddDialog($preName, $preTarget, $preKind, $preGroup) {
  $dlg = New-Object System.Windows.Window
  $dlg.Width = 592
  $dlg.Height = 552
  $dlg.WindowStyle = 'None'
  $dlg.ResizeMode = 'NoResize'
  $dlg.AllowsTransparency = $true
  $dlg.Background = [System.Windows.Media.Brushes]::Transparent
  $dlg.WindowStartupLocation = 'CenterOwner'
  $dlg.Owner = $win
  $dlg.Title = 'Add to AI Hub'

  $shell = New-Object System.Windows.Controls.Border
  $shell.CornerRadius = 16
  $shell.Background = $cInk
  $shell.BorderBrush = $cLine
  $shell.BorderThickness = 1
  $shell.Margin = '14'
  $dlg.Content = $shell

  $outer = New-Object System.Windows.Controls.StackPanel
  $outer.Margin = '24,20,24,18'
  $shell.Child = $outer

  $h = New-Object System.Windows.Controls.TextBlock
  $h = New-Object System.Windows.Controls.TextBlock
  $h.Text = 'Add to AI Hub'
  $h.FontFamily = $fontDisplay
  $h.FontSize = 22
  $h.FontWeight = 'SemiBold'
  $h.Foreground = $cText
  [void]$outer.Children.Add($h)

  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = 'It is saved straight into apps.json, so it is still there next time.'
  $sub.FontSize = 11
  $sub.Foreground = $cMuted
  $sub.Margin = '0,3,0,16'
  [void]$outer.Children.Add($sub)

  # kind chips
  $kindLabel = New-Object System.Windows.Controls.TextBlock
  $kindLabel.Text = 'KIND'
  $kindLabel.FontSize = 9.5
  $kindLabel.Foreground = $cDim
  $kindLabel.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
  $kindLabel.Margin = '0,0,0,6'
  [void]$outer.Children.Add($kindLabel)

  $kindRow = New-Object System.Windows.Controls.WrapPanel
  $kindRow.Margin = '0,0,0,14'
  [void]$outer.Children.Add($kindRow)

  $script:ChosenKind = 'url'
  $script:KindChips = @()

  function Set-Kind($value) {
    $script:ChosenKind = $value
    foreach ($c in $script:KindChips) {
      if ($c.Tag -eq $value) {
        $c.Background = New-Brush '#22303F'
        $c.BorderBrush = $cLineHi
        $c.Child.Foreground = $cText
      } else {
        $c.Background = [System.Windows.Media.Brushes]::Transparent
        $c.BorderBrush = $cLine
        $c.Child.Foreground = $cMuted
      }
    }
    # tell the user exactly what goes in Target, and default the section sensibly
    if ($script:Hint) {
      switch ($value) {
        'url'   { $script:Hint.Text = 'Full web address, e.g. https://example.com - https:// is added if you leave it off.'; $script:DefaultGroup = 'Web consoles' }
        'exe'   { $script:Hint.Text = 'Full path to a program, e.g. C:\Program Files\App\App.exe'; $script:DefaultGroup = 'Desktop apps' }
        'appid' { $script:Hint.Text = 'Store app ID. Run  Get-StartApps | Where Name -eq "App"  in PowerShell to find it, e.g. Claude_pzs8sxrjxfjjc!Claude'; $script:DefaultGroup = 'Desktop apps' }
        'cli'   { $script:Hint.Text = 'The command to run in a terminal, e.g. claude or codex'; $script:DefaultGroup = 'Terminals' }
      }
      if ($script:GroupField) {
        $current = $script:GroupField.Text
        if (-not $current -or $script:SuggestedGroup -contains $current) { $script:GroupField.Text = $script:DefaultGroup }
      }
      $script:SuggestedGroup = @('Web consoles', 'Desktop apps', 'Terminals', $script:DefaultGroup)
    }
  }

  foreach ($k in @(
    @{ v = 'url';   t = 'Web page' },
    @{ v = 'exe';   t = 'Program' },
    @{ v = 'appid'; t = 'Store app' },
    @{ v = 'cli';   t = 'Terminal' }
  )) {
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = 7
    $chip.Padding = '10,6,11,6'
    $chip.Margin = '0,0,6,6'
    $chip.Cursor = 'Hand'
    $chip.BorderThickness = 1
    $chip.Tag = $k.v
    $ct = New-Object System.Windows.Controls.TextBlock
    $ct.Text = $k.t
    $ct.FontSize = 11.5
    $chip.Child = $ct
    $chip.Add_MouseLeftButtonUp({ Set-Kind $this.Tag })
    $script:KindChips += $chip
    [void]$kindRow.Children.Add($chip)
  }

  $fName = New-Field 'Name' 'What the tile says'
  $fNote = New-Field 'Note' 'The small grey line under the name'
  $fTarget = New-Field 'Target' 'https://…  |  C:\path\app.exe  |  Store AppID  |  command'
  $fGroup = New-Field 'Group' 'Section heading, e.g. Web consoles'
  foreach ($f in $fName, $fNote, $fTarget, $fGroup) { [void]$outer.Children.Add($f) }

  $hint = New-Object System.Windows.Controls.TextBlock
  $hint.FontFamily = $fontText
  $hint.FontSize = 11.5
  $hint.Foreground = $cDim
  $hint.TextWrapping = 'Wrap'
  $hint.Margin = '0,-6,0,10'
  [void]$outer.Children.Add($hint)
  $script:Hint = $hint
  $script:GroupField = ($fGroup.Children[1])
  $script:SuggestedGroup = @('Web consoles', 'Desktop apps', 'Terminals')

  ($fName.Children[1]).Text = ''
  ($fGroup.Children[1]).Text = 'Web consoles'
  Set-Kind 'url'

  if ($preKind) { Set-Kind $preKind }
  if ($preName) { ($fName.Children[1]).Text = $preName }
  if ($preTarget) { ($fTarget.Children[1]).Text = $preTarget }
  if ($preGroup) { ($fGroup.Children[1]).Text = $preGroup }
  if ($preName -or $preTarget) { ($fName.Children[1]).Focus() | Out-Null }

  $actions = New-Object System.Windows.Controls.StackPanel
  $actions.Orientation = 'Horizontal'
  $actions.HorizontalAlignment = 'Right'
  $actions.Margin = '0,4,0,0'
  [void]$outer.Children.Add($actions)

  $err = New-Object System.Windows.Controls.TextBlock
  $err.FontSize = 11
  $err.Foreground = New-Brush '#FF8A8A'
  $err.Margin = '0,0,12,0'
  $err.VerticalAlignment = 'Center'
  [void]$actions.Children.Add($err)

  $cancel = New-HeaderButton 'CANCEL' 96 44 $false
  $cancel.Add_MouseLeftButtonUp({ $dlg.Close() })
  [void]$actions.Children.Add($cancel)

  $save = New-Object System.Windows.Controls.Border
  $save.Width = 88
  $save.Height = 44
  $save.CornerRadius = 8
  $save.Margin = '8,0,0,0'
  $save.Cursor = 'Hand'
  $save.Background = $cPrimary
  $saveText = New-Object System.Windows.Controls.TextBlock
  $saveText.Text = 'ADD'
  $saveText.FontFamily = $fontText
  $saveText.FontSize = 13
  $saveText.FontWeight = 'SemiBold'
  $saveText.Foreground = $cOnPrimary
  $saveText.HorizontalAlignment = 'Center'
  $saveText.VerticalAlignment = 'Center'
  $save.Child = $saveText
  [void]$actions.Children.Add($save)

  $save.Add_MouseLeftButtonUp({
    $message = ''
    $ok = Add-HubItem -name ($fName.Children[1]).Text -note ($fNote.Children[1]).Text -kind $script:ChosenKind -target ($fTarget.Children[1]).Text -group ($fGroup.Children[1]).Text -message ([ref]$message)
    if ($ok) { $dlg.Close() } else { $err.Text = $message }
  })

  $dlg.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $dlg.Close() }
  })
  $dlg.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------- start
Show-Checking
$fText.Text = 'Checking the tunnel…'

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
  $timer.Stop()
  Recheck
})
$timer.Start()

# "Open me" knock from a second click. The event is created at start-up (above),
# so a click that lands while the checks are still running is not lost: the first
# tick below sees it and shows the window straight away.
$showTimer = New-Object System.Windows.Threading.DispatcherTimer
$showTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$showTimer.Add_Tick({
  if ($script:ShowEvent.WaitOne(0)) {
    Write-GateLog 'RAISE requested by a second click'
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    $win.Show()
    $win.Topmost = $true
    try {
      $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
      [void][Hub.Win]::ShowWindow($hwnd, 9)
      [void][Hub.Win]::SetForegroundWindow($hwnd)
      [Hub.Win]::SwitchToThisWindow($hwnd, $true)
    } catch { }
    $win.Activate()
    # Hold "always on top" briefly: even when Windows refuses the focus change,
    # the window is still drawn above whatever is in front, so the click is answered.
    if (-not $script:TopTimer) {
      $script:TopTimer = New-Object System.Windows.Threading.DispatcherTimer
      $script:TopTimer.Interval = [TimeSpan]::FromSeconds(1.2)
      $script:TopTimer.Add_Tick({
        $script:TopTimer.Stop()
        $script:TopTimer = $null
        $win.Topmost = $false
      })
    }
    if (-not $script:TopTimer.IsEnabled) { $script:TopTimer.Start() }
  }
})
$showTimer.Start()

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'

# Never die silently: log to gate-log.txt and tell the user if the UI throws.
$app.add_DispatcherUnhandledException({
  param($s, $e)
  try {
    Write-GateLog ('UI error: ' + $e.Exception.Message)
    [System.Windows.MessageBox]::Show(('AI Hub hit an error: ' + $e.Exception.Message), 'AI Hub') | Out-Null
  } catch { }
  $e.Handled = $true
})

[void]$app.Run($win)