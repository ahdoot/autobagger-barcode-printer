# ============================================================================
#  Autobagger Barcode Printer
#  ---------------------------------------------------------------------------
#  Scan a QR code (or type a SKU/barcode) -> the product is QUEUED: looked up
#  in the ShipBots SQL warehouse and previewed, but nothing prints yet.
#  Each Ctrl+P (or the PRINT button) sends exactly ONE ShipHero-style label to
#  the selected Windows printer (e.g. the SATO CL4NX Plus on the WETIE bagger).
#  Press it as many times as labels are needed; the QR's quantity is shown as
#  a target counter ("Printed 2 of 3"). Scanning the next QR queues that
#  product and resets the counter.
#
#  QR payload format (pipe-delimited, made for keyboard-wedge scanners):
#      <SKU>|<Barcode>|<Quantity>
#  - SKU       shown big as [ SKU ] on the label
#  - Barcode   value encoded in the Code128 on the label
#  - Quantity  target label count shown on screen (each Ctrl+P prints one)
#  (an optional 4th field is treated as a product-name fallback; SQL lookup
#   overrides/fills all product info when reachable)
#  A plain scan with no pipes is treated as a SKU or barcode, qty 1.
#
#  Usage:
#      AutobaggerBarcodePrinter.ps1                 -> GUI
#      AutobaggerBarcodePrinter.ps1 -SelfTest "..." -> headless parse/lookup/
#                                                      render/print test
# ============================================================================
param(
    [string]$SelfTest = "",
    [string]$TestPrinter = "",
    [switch]$SmokeTest,
    [switch]$NoPrint
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Version of this release. Bump on every release - deployed stations compare
# against the copy on the office share (settings: updateSource) and offer to
# self-update when the shared copy is newer.
$script:AppVersion = '2.4.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

# ----------------------------------------------------------------------------
# Code 128 (subset B) encoder - returns module widths; drawn by Draw-Label
# ----------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;

public static class Code128B
{
    // Standard Code 128 symbol width patterns (bar,space,bar,space,bar,space)
    static readonly string[] P = new string[] {
        "212222","222122","222221","121223","121322","131222","122213","122312",
        "132212","221213","221312","231212","112232","122132","122231","113222",
        "123122","123221","223211","221132","221231","213212","223112","312131",
        "311222","321122","321221","312212","322112","322211","212123","212321",
        "232121","111323","131123","131321","112313","132113","132311","211313",
        "231113","231311","112133","112331","132131","113123","113321","133121",
        "313121","211331","231131","213113","213311","213131","311123","311321",
        "331121","312113","312311","332111","314111","221411","431111","111224",
        "111422","121124","121421","141122","141221","112214","112412","122114",
        "122411","142112","142211","241211","221114","413111","241112","134111",
        "111242","121142","121241","114212","124112","124211","411212","421112",
        "421211","212141","214121","412121","111143","111341","131141","114113",
        "114311","411113","411311","113141","114131","311141","411131","211412",
        "211214","211232","2331112"
    };

    // Returns alternating bar/space module widths, starting with a bar.
    public static int[] Encode(string text)
    {
        if (string.IsNullOrEmpty(text)) throw new ArgumentException("empty barcode text");
        var vals = new List<int>();
        vals.Add(104); // Start B
        foreach (char c in text)
        {
            int v = (int)c - 32;
            if (v < 0 || v > 94) v = (int)'?' - 32; // replace non-encodable
            vals.Add(v);
        }
        int check = vals[0];
        for (int i = 1; i < vals.Count; i++) check += vals[i] * i;
        vals.Add(check % 103);
        vals.Add(106); // Stop

        var widths = new List<int>();
        foreach (int v in vals)
            foreach (char w in P[v])
                widths.Add((int)w - (int)'0');
        return widths.ToArray();
    }
}
"@ -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# Paths / settings
# ----------------------------------------------------------------------------
$script:AppName    = 'Autobagger Barcode Printer'
$script:AppDir     = Join-Path $env:APPDATA 'AutobaggerBarcodePrinter'
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'
$script:LogFile    = Join-Path $script:AppDir 'print-log.csv'
if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

$script:DefaultSettings = [ordered]@{
    settingsVersion = 4            # bumped when defaults change (see migration below)
    printerName    = ''            # last selected printer
    paperWidthIn   = 4.0           # paper sent to the printer driver (4x2 thermal labels)
    paperHeightIn  = 2.0
    labelWidthIn   = 3.8           # printed label content fills the 4x2 label
    labelHeightIn  = 1.8
    maxCopies      = 50            # safety cap on qty from a QR code
    sqlTimeoutSec  = 5
    # No credentials ship inside this file. The SQL connection string is stored
    # once per station in %APPDATA%\AutobaggerBarcodePrinter\settings.json
    # (the app asks for it on first run if missing).
    sqlConn        = ''
    updateSource   = '\\PC1-AMD\Autobagger Barcode Printer\AutobaggerBarcodePrinter.ps1'  # LAN fallback release source
    # GitHub API endpoint (no CDN cache - new releases visible immediately;
    # the raw.githubusercontent URL lags ~5 min behind a push)
    updateSourceUrl= 'https://api.github.com/repos/ahdoot/autobagger-barcode-printer/contents/AutobaggerBarcodePrinter.ps1'
    language       = 'en'          # 'en' or 'es' (toggle in the GUI)
}

# read the AppVersion line out of a (possibly remote) copy of this script
function Get-ScriptVersion([string]$path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        foreach ($ln in (Get-Content -LiteralPath $path -TotalCount 60 -ErrorAction Stop)) {
            if ($ln -match "AppVersion\s*=\s*'([0-9][0-9.]*)'") { return [version]$Matches[1] }
        }
    } catch { }
    return $null
}

# Resolve a release source (https URL of a release page / raw ps1, or UNC/local
# path) to @{ Version; File } where File is a local path to the new script.
function Get-RemoteReleaseInfo([string]$src) {
    if ($src -match '^https?://') {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072  # TLS 1.2
            $tmp = Join-Path $env:TEMP 'abp-release-download.tmp'
            $headers = @{}
            if ($src -match 'api\.github\.com') {
                # ask the API for the raw file (fresh, not CDN-cached)
                $headers = @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'AutobaggerBarcodePrinter' }
            }
            Invoke-WebRequest -Uri $src -OutFile $tmp -UseBasicParsing -TimeoutSec 25 -Headers $headers | Out-Null
            $raw = [System.IO.File]::ReadAllText($tmp)
            $ps1 = Join-Path $env:TEMP 'abp-release.ps1'
            if ($raw -match '(?s)ABP-RELEASE-BEGIN:v(?<v>[0-9][0-9.]*):(?<b64>[A-Za-z0-9+/=\r\n\s]+?):ABP-RELEASE-END') {
                # release page: version + base64-embedded script
                [System.IO.File]::WriteAllBytes($ps1, [Convert]::FromBase64String(($Matches['b64'] -replace '\s', '')))
                return @{ Version = [version]$Matches['v']; File = $ps1 }
            }
            # plain .ps1 served directly
            $v = $null
            foreach ($ln in ($raw -split "`n" | Select-Object -First 60)) {
                if ($ln -match "AppVersion\s*=\s*'([0-9][0-9.]*)'") { $v = [version]$Matches[1]; break }
            }
            if ($v) { Copy-Item $tmp $ps1 -Force; return @{ Version = $v; File = $ps1 } }
        } catch { }
        return $null
    }
    $v = Get-ScriptVersion $src
    if ($v) { return @{ Version = $v; File = $src } }
    return $null
}

function Load-Settings {
    $s = @{}
    foreach ($k in $script:DefaultSettings.Keys) { $s[$k] = $script:DefaultSettings[$k] }
    $fileVersion = 0
    if (Test-Path $script:SettingsFile) {
        try {
            $j = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
            if ($j.PSObject.Properties['settingsVersion']) { $fileVersion = [int]$j.settingsVersion }
        } catch { }
        # Migrations for saved settings from older releases (only values still
        # at their old defaults are touched; deliberate customizations stick):
        # v2: 4x6 paper -> 4x2 thermal labels; v3: label content scaled up
        # from the small ShipHero block to fill the 4x2 label.
        if ($fileVersion -lt 3) {
            if ([double]$s.paperHeightIn -eq 6.0) { $s.paperHeightIn = 2.0 }
            if ([double]$s.labelWidthIn -eq 2.25 -and [double]$s.labelHeightIn -eq 1.25) {
                $s.labelWidthIn = 3.8; $s.labelHeightIn = 1.8
            }
            $s.settingsVersion = 3
            Save-Settings $s
        }
        # v4: saved raw-CDN update URL -> blank, so the API default takes over
        if ($fileVersion -lt 4) {
            if ("$($s.updateSourceUrl)" -like 'https://raw.githubusercontent.com/*') { $s.updateSourceUrl = '' }
            $s.settingsVersion = 4
            Save-Settings $s
        }
    }
    return $s
}

function Save-Settings($s) {
    try { ($s | ConvertTo-Json) | Set-Content -Path $script:SettingsFile -Encoding UTF8 } catch { }
}

function Write-PrintLog($input_, $sku, $qty, $printer, $result, $name = '') {
    try {
        if (-not (Test-Path $script:LogFile)) {
            'timestamp,input,sku,qty,printer,result,product' | Set-Content -Path $script:LogFile -Encoding UTF8
        }
        $line = '"{0}","{1}","{2}",{3},"{4}","{5}","{6}"' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            ($input_ -replace '"',"'"), ($sku -replace '"',"'"), $qty, ($printer -replace '"',"'"),
            ($result -replace '"',"'"), ($name -replace '"',"'")
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

# Read the log back and group consecutive prints of the same SKU into one
# history row (chronological order; caller reverses for newest-first display).
function Load-History {
    $grouped = @()
    if (-not (Test-Path $script:LogFile)) { return @() }
    try { $lines = Get-Content $script:LogFile -ErrorAction Stop | Select-Object -Last 300 } catch { return @() }
    foreach ($ln in $lines) {
        if ($ln -match '^"(?<ts>[^"]*)","(?<in>[^"]*)","(?<sku>[^"]*)",(?<qty>\d+),"(?<pr>[^"]*)","(?<res>[^"]*)"(?:,"(?<name>[^"]*)")?\s*$') {
            if ($Matches['res'] -ne 'ok' -or $Matches['sku'] -eq '') { continue }
            $name = if ($Matches['name']) { $Matches['name'] } else { '' }
            if ($grouped.Count -gt 0 -and $grouped[-1].Sku -eq $Matches['sku']) {
                $grouped[-1].Count += [int]$Matches['qty']
                $grouped[-1].Ts = $Matches['ts']
                if ($name -ne '') { $grouped[-1].Name = $name }
            } else {
                $grouped += [pscustomobject]@{ Ts=$Matches['ts']; Sku=$Matches['sku']; Name=$name; Count=[int]$Matches['qty'] }
            }
        }
    }
    return $grouped
}

# total labels successfully printed today (from the log; survives restarts)
function Get-TodayPrinted {
    if (-not (Test-Path $script:LogFile)) { return 0 }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $n = 0
    try {
        foreach ($ln in (Get-Content $script:LogFile -ErrorAction Stop)) {
            if ($ln -match ('^"' + [regex]::Escape($today) + ' [^"]*","[^"]*","[^"]*",(\d+),"[^"]*","ok"')) { $n += [int]$Matches[1] }
        }
    } catch { }
    return $n
}

function Format-HistTime([string]$ts) {
    try {
        $dt = [datetime]::ParseExact($ts, 'yyyy-MM-dd HH:mm:ss', $null)
        if ($dt.Date -eq (Get-Date).Date) { return $dt.ToString('h:mm tt') }
        return $dt.ToString('ddd M/d  h:mm tt')
    } catch { return $ts }
}

# ----------------------------------------------------------------------------
# Scan payload parsing
# ----------------------------------------------------------------------------
function Parse-ScanPayload([string]$raw) {
    $raw = $raw.Trim()
    $job = @{ Barcode=''; Sku=''; Name=''; Qty=1; Raw=$raw; FromQR=$false }
    if ($raw -eq '') { return $null }

    if ($raw -like '*|*') {
        # <SKU>|<Barcode>|<Quantity>  (optional 4th field = product name)
        $parts = $raw -split '\|'
        $job.FromQR  = $true
        $job.Sku     = $parts[0].Trim()
        if ($parts.Count -gt 1) { $job.Barcode = $parts[1].Trim() }
        $q = 0
        if ($parts.Count -gt 2 -and [int]::TryParse($parts[2].Trim(), [ref]$q) -and $q -gt 0) { $job.Qty = $q }
        if ($parts.Count -gt 3) { $job.Name = ($parts[3..($parts.Count-1)] -join '|').Trim() }
        if ($job.Barcode -eq '' -and $job.Sku -eq '') { return $null }
    }
    elseif ($raw -match '^\s*\{') {
        # JSON fallback: {"barcode":"..","qty":2,"sku":"..","name":".."}
        try {
            $j = $raw | ConvertFrom-Json
            $job.FromQR = $true
            if ($j.PSObject.Properties['barcode']) { $job.Barcode = [string]$j.barcode }
            if ($j.PSObject.Properties['sku'])     { $job.Sku     = [string]$j.sku }
            if ($j.PSObject.Properties['name'])    { $job.Name    = [string]$j.name }
            if ($j.PSObject.Properties['qty'])     { $q = 0; if ([int]::TryParse([string]$j.qty, [ref]$q) -and $q -gt 0) { $job.Qty = $q } }
        } catch { return $null }
    }
    else {
        # plain SKU or barcode scan/typed
        $job.Barcode = $raw
        $job.Sku     = $raw
    }
    return $job
}

# ----------------------------------------------------------------------------
# ShipBots SQL lookup
# ----------------------------------------------------------------------------
function Lookup-Product($settings, [string]$barcode, [string]$sku) {
    if ([string]"$($settings.sqlConn)" -eq '') { throw 'SQL not configured on this station (settings.json: sqlConn)' }
    $conn = New-Object System.Data.SqlClient.SqlConnection($settings.sqlConn)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = [int]$settings.sqlTimeoutSec
        $cmd.CommandText = @'
SELECT TOP 5 p.sku, p.barcode, p.name, p.account_id, c.client_name, p.created_at, p.large_thumbnail
FROM dbo.de_products p
LEFT JOIN (
    SELECT customer_id, MAX(NULLIF(from_name,'')) AS client_name
    FROM dbo.de_warehouse_to_customers GROUP BY customer_id
) c ON p.account_id = c.customer_id
WHERE (@barcode <> '' AND p.barcode = @barcode)
   OR (@sku     <> '' AND p.sku     = @sku)
ORDER BY CASE WHEN p.barcode = @barcode AND p.sku = @sku THEN 0
              WHEN p.barcode = @barcode THEN 1 ELSE 2 END,
         p.created_at DESC
'@
        [void]$cmd.Parameters.AddWithValue('@barcode', $barcode)
        [void]$cmd.Parameters.AddWithValue('@sku', $sku)
        $rd = $cmd.ExecuteReader()
        $rows = @()
        while ($rd.Read()) {
            $rows += [pscustomobject]@{
                Sku      = [string]$rd['sku']
                Barcode  = [string]$rd['barcode']
                Name     = [string]$rd['name']
                Client   = [string]$rd['client_name']
                ImageUrl = [string]$rd['large_thumbnail']
            }
        }
        $rd.Close()
        return ,$rows
    }
    finally { $conn.Close() }
}

# Build final label data from scan payload + SQL (SQL wins; QR fills gaps)
function Resolve-Job($settings, $job) {
    $job.SqlStatus = ''
    $rows = $null
    try {
        $rows = Lookup-Product $settings $job.Barcode $job.Sku
    } catch {
        $job.SqlStatus = "SQL offline: $($_.Exception.Message)"
    }
    $job.ImageUrl = ''
    if ($rows -and $rows.Count -gt 0) {
        $p = $rows[0]
        $job.Sku  = $p.Sku
        $job.Name = $p.Name
        $job.Client = $p.Client
        $job.ImageUrl = [string]$p.ImageUrl
        if ($p.Barcode -ne '') { $job.Barcode = $p.Barcode } elseif ($job.Barcode -eq '') { $job.Barcode = $p.Sku }
        if ($rows.Count -gt 1) { $job.SqlStatus = "Note: $($rows.Count) products matched; using newest." }
    }
    else {
        if (-not $job.ContainsKey('Client')) { $job.Client = '' }
        if ($job.SqlStatus -eq '') { $job.SqlStatus = 'SKU not found in ShipBots SQL.' }
        if ($job.Barcode -eq '') { $job.Barcode = $job.Sku }
        # allowed to proceed if the QR itself carried enough info
    }
    if ($job.Name -eq '' -and -not $job.FromQR -and (-not $rows -or $rows.Count -eq 0)) {
        $job.CanPrint = $false     # bare scan that SQL doesn't know -> block
    } else {
        $job.CanPrint = ($job.Barcode -ne '')
    }
    return $job
}

# ----------------------------------------------------------------------------
# Label rendering (ShipHero style: name / [ SKU ] / V:client / Code128)
# ----------------------------------------------------------------------------
function Draw-Label([System.Drawing.Graphics]$g, [System.Drawing.RectangleF]$rc, $job) {
    $g.SmoothingMode     = 'None'
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $black = [System.Drawing.Brushes]::Black
    $px2pt = 72.0 / $g.DpiY   # px height -> font points

    # Layout fractions of label height (fills the whole 4x2 label)
    $nameH = $rc.Height * 0.30
    $skuH  = $rc.Height * 0.24
    $vendH = $rc.Height * 0.13
    $barZ  = $rc.Height - $nameH - $skuH - $vendH   # bars + digits zone

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $fmt.Trimming  = 'EllipsisCharacter'

    # Product name: large, wraps up to 2 lines; shrinks until it fits the zone
    $namePt = $nameH * 0.40 * $px2pt
    $fName = New-Object System.Drawing.Font('Arial', $namePt, [System.Drawing.FontStyle]::Bold)
    while ($namePt -gt 6 -and $g.MeasureString($job.Name, $fName, (New-Object System.Drawing.SizeF($rc.Width, 10000))).Height -gt $nameH) {
        $namePt -= 0.5; $fName.Dispose(); $fName = New-Object System.Drawing.Font('Arial', $namePt, [System.Drawing.FontStyle]::Bold)
    }
    $g.DrawString($job.Name, $fName, $black, (New-Object System.Drawing.RectangleF($rc.X, $rc.Y, $rc.Width, $nameH)), $fmt)

    # small "SKU:" prefix + [ SKU ] big, centered together
    $skuText = if ($job.Sku -ne '') { "[ $($job.Sku) ]" } else { "[ $($job.Barcode) ]" }
    $smallPt = [Math]::Max(5.0, ($skuH * 0.18 * $px2pt))
    $fSmall = New-Object System.Drawing.Font('Arial', $smallPt)
    $smallW = $g.MeasureString('SKU:', $fSmall).Width
    $gap = $rc.Width * 0.012
    $skuPt = [Math]::Max(6.0, ($skuH * 0.62 * $px2pt))
    $fSku = New-Object System.Drawing.Font('Arial', $skuPt, [System.Drawing.FontStyle]::Bold)
    while ($skuPt -gt 5 -and $g.MeasureString($skuText, $fSku).Width -gt ($rc.Width - $smallW - $gap)) {
        $skuPt -= 1; $fSku.Dispose(); $fSku = New-Object System.Drawing.Font('Arial', $skuPt, [System.Drawing.FontStyle]::Bold)
    }
    $bigW = $g.MeasureString($skuText, $fSku).Width
    $startX = $rc.X + [Math]::Max(0, (($rc.Width - $smallW - $gap - $bigW) / 2))
    $g.DrawString('SKU:', $fSmall, $black, (New-Object System.Drawing.RectangleF($startX, ($rc.Y + $nameH), ($smallW + 2), $skuH)), $fmt)
    $g.DrawString($skuText, $fSku, $black, (New-Object System.Drawing.RectangleF(($startX + $smallW + $gap), ($rc.Y + $nameH), ($bigW + 2), $skuH)), $fmt)
    $fSmall.Dispose()

    # V:client (slightly larger)
    if ($job.Client -ne '') {
        $vendPt = [Math]::Max(4.0, ($vendH * 0.62 * $px2pt))
        $fV = New-Object System.Drawing.Font('Arial', $vendPt, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("V:$($job.Client)", $fV, $black, (New-Object System.Drawing.RectangleF($rc.X, ($rc.Y + $nameH + $skuH), $rc.Width, $vendH)), $fmt)
        $fV.Dispose()
    }

    # Code128 barcode, wide, with human-readable digits underneath
    $widths = [Code128B]::Encode($job.Barcode)
    $totalModules = 0; foreach ($w in $widths) { $totalModules += $w }
    $quiet = 8  # quiet zone in modules each side
    $modulePx = [Math]::Floor(($rc.Width / ($totalModules + 2*$quiet)))
    if ($modulePx -lt 1) { $modulePx = 1 }
    $barWidthPx = $totalModules * $modulePx
    $x = $rc.X + [Math]::Max(0, (($rc.Width - $barWidthPx) / 2))
    $y = $rc.Y + $nameH + $skuH + $vendH + ($barZ * 0.02)
    $h = $barZ * 0.60
    $isBar = $true
    foreach ($w in $widths) {
        $wp = $w * $modulePx
        if ($isBar) { $g.FillRectangle($black, [single]$x, [single]$y, [single]$wp, [single]$h) }
        $x += $wp
        $isBar = -not $isBar
    }
    $digits = ($job.Barcode.ToCharArray() -join ' ')
    $digPt = [Math]::Max(4.5, ($barZ * 0.26 * $px2pt))
    $fDig = New-Object System.Drawing.Font('Arial', $digPt)
    $g.DrawString($digits, $fDig, $black, (New-Object System.Drawing.RectangleF($rc.X, ($y + $h + $barZ * 0.02), $rc.Width, ($barZ * 0.32))), $fmt)
    $fDig.Dispose()

    $fName.Dispose(); $fSku.Dispose(); $fmt.Dispose()
}

function Render-LabelBitmap($settings, $job, [int]$dpi = 203) {
    $wpx = [int]($settings.labelWidthIn  * $dpi)
    $hpx = [int]($settings.labelHeightIn * $dpi)
    $bmp = New-Object System.Drawing.Bitmap($wpx, $hpx)
    $bmp.SetResolution($dpi, $dpi)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $pad = [int]($dpi * 0.05)
    Draw-Label $g (New-Object System.Drawing.RectangleF($pad, $pad, ($wpx - 2*$pad), ($hpx - 2*$pad))) $job
    $g.Dispose()
    return $bmp
}

# ----------------------------------------------------------------------------
# Printing
# ----------------------------------------------------------------------------
function Print-Labels($settings, $job, [string]$printerName, [int]$copies, [string]$printToFile = '') {
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $doc.DocumentName = "Autobagger $($job.Sku) x$copies"
    $doc.PrinterSettings.PrinterName = $printerName
    if (-not $doc.PrinterSettings.IsValid) { throw "Printer '$printerName' is not available." }
    if ($printToFile -ne '') {
        $doc.PrinterSettings.PrintToFile = $true
        $doc.PrinterSettings.PrintFileName = $printToFile
    }

    # paper size in hundredths of an inch
    $pw = [int]($settings.paperWidthIn  * 100)
    $ph = [int]($settings.paperHeightIn * 100)
    $paper = $null
    foreach ($ps in $doc.PrinterSettings.PaperSizes) {
        if ([Math]::Abs($ps.Width - $pw) -le 3 -and [Math]::Abs($ps.Height - $ph) -le 3) { $paper = $ps; break }
    }
    if (-not $paper) { $paper = New-Object System.Drawing.Printing.PaperSize('AutobaggerLabel', $pw, $ph) }
    $doc.DefaultPageSettings.PaperSize = $paper
    $doc.DefaultPageSettings.Margins   = New-Object System.Drawing.Printing.Margins(0,0,0,0)
    $doc.OriginAtMargins = $false

    $state = @{ Printed = 0; Total = $copies; Job = $job; Settings = $settings }
    $doc.add_PrintPage({
        param($sender, $e)
        $s = $state
        $e.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Inch
        # label block at top-left with a small offset
        $rc = New-Object System.Drawing.RectangleF(0.06, 0.06, [single]$s.Settings.labelWidthIn, [single]$s.Settings.labelHeightIn)
        # Draw-Label works in device px terms via DpiY for fonts; PageUnit inch keeps sizes physical
        Draw-LabelInch $e.Graphics $rc $s.Job
        $s.Printed++
        $e.HasMorePages = ($s.Printed -lt $s.Total)
    }.GetNewClosure())

    $doc.Print()
    return $state.Printed
}

# Inch-unit variant used on the printer graphics surface
function Draw-LabelInch([System.Drawing.Graphics]$g, [System.Drawing.RectangleF]$rc, $job) {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $black = [System.Drawing.Brushes]::Black

    $nameH = $rc.Height * 0.30
    $skuH  = $rc.Height * 0.24
    $vendH = $rc.Height * 0.13
    $barZ  = $rc.Height - $nameH - $skuH - $vendH   # bars + digits zone

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $fmt.Trimming  = 'EllipsisCharacter'

    # fonts: size in points (1pt = 1/72 in) regardless of PageUnit
    # Product name: large, wraps up to 2 lines; shrinks until it fits the zone
    $namePt = $nameH * 0.40 * 72
    $fName = New-Object System.Drawing.Font('Arial', [single]$namePt, [System.Drawing.FontStyle]::Bold)
    while ($namePt -gt 6 -and $g.MeasureString($job.Name, $fName, (New-Object System.Drawing.SizeF($rc.Width, 100))).Height -gt $nameH) {
        $namePt -= 0.5; $fName.Dispose(); $fName = New-Object System.Drawing.Font('Arial', [single]$namePt, [System.Drawing.FontStyle]::Bold)
    }
    $g.DrawString($job.Name, $fName, $black, (New-Object System.Drawing.RectangleF($rc.X, $rc.Y, $rc.Width, [single]$nameH)), $fmt)

    # small "SKU:" prefix + [ SKU ] big, centered together
    $skuText = if ($job.Sku -ne '') { "[ $($job.Sku) ]" } else { "[ $($job.Barcode) ]" }
    $fSmall = New-Object System.Drawing.Font('Arial', [single][Math]::Max(5.0, ($skuH * 0.18 * 72)))
    $smallW = $g.MeasureString('SKU:', $fSmall).Width
    $gap = $rc.Width * 0.012
    $skuPt = [Math]::Max(6.0, ($skuH * 0.62 * 72))
    $fSku = New-Object System.Drawing.Font('Arial', [single]$skuPt, [System.Drawing.FontStyle]::Bold)
    while ($skuPt -gt 5 -and $g.MeasureString($skuText, $fSku).Width -gt ($rc.Width - $smallW - $gap)) {
        $skuPt -= 1; $fSku.Dispose(); $fSku = New-Object System.Drawing.Font('Arial', [single]$skuPt, [System.Drawing.FontStyle]::Bold)
    }
    $bigW = $g.MeasureString($skuText, $fSku).Width
    $startX = $rc.X + [Math]::Max(0, (($rc.Width - $smallW - $gap - $bigW) / 2))
    $g.DrawString('SKU:', $fSmall, $black, (New-Object System.Drawing.RectangleF([single]$startX, ($rc.Y + $nameH), [single]($smallW + 0.02), [single]$skuH)), $fmt)
    $g.DrawString($skuText, $fSku, $black, (New-Object System.Drawing.RectangleF([single]($startX + $smallW + $gap), ($rc.Y + $nameH), [single]($bigW + 0.02), [single]$skuH)), $fmt)
    $fSmall.Dispose()

    if ($job.Client -ne '') {
        $fV = New-Object System.Drawing.Font('Arial', [single][Math]::Max(4.0, ($vendH * 0.62 * 72)), [System.Drawing.FontStyle]::Bold)
        $g.DrawString("V:$($job.Client)", $fV, $black, (New-Object System.Drawing.RectangleF($rc.X, ($rc.Y + $nameH + $skuH), $rc.Width, [single]$vendH)), $fmt)
        $fV.Dispose()
    }

    $widths = [Code128B]::Encode($job.Barcode)
    $totalModules = 0; foreach ($w in $widths) { $totalModules += $w }
    # module width in inches; 8-module quiet zones, wide bars like ShipHero's
    $quiet = 8
    $module = $rc.Width / ($totalModules + 2*$quiet)
    $minModule = 2.0 / 203.0   # at least 2 dots on a 203dpi head
    if ($module -gt 5*$minModule) { $module = 5*$minModule }
    if ($module -lt $minModule) { $module = $minModule }
    $barWidth = $totalModules * $module
    $x = $rc.X + [Math]::Max(0, (($rc.Width - $barWidth) / 2))
    $y = $rc.Y + $nameH + $skuH + $vendH + ($barZ * 0.02)
    $h = $barZ * 0.60
    $isBar = $true
    foreach ($w in $widths) {
        $wp = $w * $module
        if ($isBar) { $g.FillRectangle($black, [single]$x, [single]$y, [single]$wp, [single]$h) }
        $x += $wp
        $isBar = -not $isBar
    }
    # human-readable digits under the bars
    $digits = ($job.Barcode.ToCharArray() -join ' ')
    $fDig = New-Object System.Drawing.Font('Arial', [single][Math]::Max(4.5, ($barZ * 0.26 * 72)))
    $g.DrawString($digits, $fDig, $black, (New-Object System.Drawing.RectangleF($rc.X, ($y + $h + $barZ * 0.02), $rc.Width, [single]($barZ * 0.32))), $fmt)
    $fDig.Dispose()

    $fName.Dispose(); $fSku.Dispose(); $fmt.Dispose()
}

# ----------------------------------------------------------------------------
# Headless self-test mode
# ----------------------------------------------------------------------------
if ($SelfTest -ne '') {
    $settings = Load-Settings
    Write-Host "== Autobagger Barcode Printer self-test =="
    $job = Parse-ScanPayload $SelfTest
    if (-not $job) { Write-Host "PARSE: FAILED (empty/invalid payload)"; exit 1 }
    Write-Host ("PARSE: barcode='{0}' qty={1} sku='{2}' name='{3}' fromQR={4}" -f $job.Barcode, $job.Qty, $job.Sku, $job.Name, $job.FromQR)
    if ($job.FromQR -and $job.Sku -eq '') { Write-Host 'ALERT: SKU MISSING - would show red popup, nothing queued'; exit 2 }
    $job = Resolve-Job $settings $job
    Write-Host ("RESOLVE: sku='{0}' barcode='{1}' name='{2}' client='{3}' canPrint={4} status='{5}'" -f $job.Sku, $job.Barcode, $job.Name, $job.Client, $job.CanPrint, $job.SqlStatus)
    $bmp = Render-LabelBitmap $settings $job 203
    $png = Join-Path $script:AppDir 'selftest-label.png'
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "RENDER: saved $png"
    if (-not $NoPrint -and $TestPrinter -ne '') {
        $pdf = Join-Path $script:AppDir 'selftest-print.pdf'
        if (Test-Path $pdf) { Remove-Item $pdf -Force }
        $target = if ($TestPrinter -like '*PDF*') { $pdf } else { '' }
        $printed = Print-Labels $settings $job $TestPrinter 1 $target
        Write-Host "PRINT: sent $printed page(s) to '$TestPrinter' $(if($target){" -> $target"})"
    }
    exit 0
}

# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
$settings = Load-Settings

# --- English / Spanish string table ---
$script:Lang = if ("$($settings.language)" -eq 'es') { 'es' } else { 'en' }
$script:Strings = @{
    en = @{
        scanCap        = 'SCAN QR CODE  (or type SKU / barcode and press Enter)'
        ready          = 'READY  -  scan a QR code'
        readySub       = 'QR format: SKU|Barcode|Quantity'
        looking        = 'Looking up product...'
        cantRead       = 'Could not read that scan - try again.'
        labelWordOne   = 'LABEL'
        labelWordMany  = 'LABELS'
        printLabels    = 'PRINT {0} {1}  -  press Ctrl+P'
        printOffline   = 'PRINT {0} {1} (from QR - SQL offline)  -  press Ctrl+P'
        printedProgress= 'PRINTED {0} of {1}  -  {2} more, press Ctrl+P'
        printedAll     = 'ALL {0} PRINTED  -  scan the next item'
        printedOver    = 'PRINTED {0}  (target was {1})'
        notFound       = 'NOT FOUND - check the scan and try again'
        scanned        = 'scanned: '
        skuMissing     = 'SKU MISSING - the QR code has no SKU'
        skuMissingPop  = "SKU MISSING`n`nThe scanned QR code does not contain a SKU.`nNothing was queued - fix the QR code and scan again.`n`nScanned:  {0}"
        skuMissingTitle= 'SKU MISSING'
        printFailed    = 'PRINT FAILED - try again or press the fix-printer button'
        noPrinter      = 'No printer selected!'
        wProduct       = 'Product:'
        wSku           = 'SKU:'
        wBarcode       = 'Barcode:'
        wClient        = 'Client:'
        grpPrinting    = 'Printing'
        sendTo         = 'Send labels to:'
        countCap       = 'PRINTED / NEEDED'
        moreToPrint    = '{0} MORE TO PRINT'
        allDone        = 'ALL DONE'
        targetWas      = 'target was {0}'
        btnPrint       = 'PRINT 1 LABEL   (Ctrl+P)'
        btnScanFirst   = 'SCAN A QR CODE FIRST'
        histCap        = 'RECENT PRINTS  (newest on top)'
        colTime        = 'Time'
        colLabels      = 'Labels'
        colProduct     = 'Product'
        btnSpooler     = 'fix stuck printer'
        spoolClearing  = 'Clearing print queue - approve the admin prompt...'
        spoolFixed     = 'PRINTER FIXED - queue cleared, ready'
        spoolFixedSub  = 'print spooler was restarted'
        spoolCanceled  = 'Spooler restart canceled (admin approval declined).'
        todayBar       = 'Labels printed today:  {0}'
        updateLink     = 'New version {0} - click here to update'
        updTooltip     = 'Check for updates'
        updUpToDate    = 'Up to date - v{0} is the latest version.'
        updNoServer    = 'Could not check for updates - no connection to the release server.'
    }
    es = @{
        scanCap        = 'ESCANEE EL CÓDIGO QR  (o escriba el SKU / código y presione Enter)'
        ready          = 'LISTO  -  escanee un código QR'
        readySub       = 'Formato QR: SKU|Código|Cantidad'
        looking        = 'Buscando el producto...'
        cantRead       = 'No se pudo leer el escaneo - intente de nuevo.'
        labelWordOne   = 'ETIQUETA'
        labelWordMany  = 'ETIQUETAS'
        printLabels    = 'IMPRIMIR {0} {1}  -  presione Ctrl+P'
        printOffline   = 'IMPRIMIR {0} {1} (desde QR - SQL sin conexión)  -  presione Ctrl+P'
        printedProgress= 'IMPRESAS {0} de {1}  -  {2} más, presione Ctrl+P'
        printedAll     = 'TODAS IMPRESAS ({0})  -  escanee el siguiente artículo'
        printedOver    = 'IMPRESAS {0}  (la meta era {1})'
        notFound       = 'NO ENCONTRADO - revise el escaneo e intente de nuevo'
        scanned        = 'escaneado: '
        skuMissing     = 'FALTA EL SKU - el código QR no tiene SKU'
        skuMissingPop  = "FALTA EL SKU`n`nEl código QR escaneado no contiene un SKU.`nNo se agregó nada - corrija el código QR y escanee de nuevo.`n`nEscaneado:  {0}"
        skuMissingTitle= 'FALTA EL SKU'
        printFailed    = 'FALLÓ LA IMPRESIÓN - intente de nuevo o presione el botón de arreglar impresora'
        noPrinter      = '¡No hay impresora seleccionada!'
        wProduct       = 'Producto:'
        wSku           = 'SKU:'
        wBarcode       = 'Código:'
        wClient        = 'Cliente:'
        grpPrinting    = 'Impresión'
        sendTo         = 'Imprimir en:'
        countCap       = 'IMPRESAS / NECESARIAS'
        moreToPrint    = '{0} MÁS POR IMPRIMIR'
        allDone        = '¡COMPLETO!'
        targetWas      = 'la meta era {0}'
        btnPrint       = 'IMPRIMIR 1 ETIQUETA   (Ctrl+P)'
        btnScanFirst   = 'PRIMERO ESCANEE UN CÓDIGO QR'
        histCap        = 'IMPRESIONES RECIENTES  (la más nueva arriba)'
        colTime        = 'Hora'
        colLabels      = 'Etiq.'
        colProduct     = 'Producto'
        btnSpooler     = 'arreglar impresora'
        spoolClearing  = 'Limpiando la cola de impresión - apruebe el aviso de administrador...'
        spoolFixed     = 'IMPRESORA ARREGLADA - cola limpia, listo'
        spoolFixedSub  = 'se reinició el spooler de impresión'
        spoolCanceled  = 'Reinicio cancelado (no se aprobó el permiso de administrador).'
        todayBar       = 'Etiquetas impresas hoy:  {0}'
        updateLink     = 'Nueva versión {0} - clic aquí para actualizar'
        updTooltip     = 'Buscar actualización'
        updUpToDate    = 'Actualizado - v{0} es la última versión.'
        updNoServer    = 'No se pudo buscar actualizaciones - sin conexión al servidor.'
    }
}
function T([string]$key) {
    $v = $script:Strings[$script:Lang][$key]
    if ($null -eq $v) { $v = $script:Strings['en'][$key] }
    return $v
}

$emojiPrinter = [char]::ConvertFromUtf32(0x1F5A8) + [char]0xFE0F   # printer
$emojiBroom   = [char]::ConvertFromUtf32(0x1F9F9)                  # broom

$form = New-Object System.Windows.Forms.Form
$script:ModDate = try { (Get-Item $PSCommandPath).LastWriteTime.ToString('M/d/yyyy') } catch { '' }
$form.Text = "$($script:AppName)   v$($script:AppVersion)" + $(if ($script:ModDate) { "   -   $script:ModDate" })
$form.Size = New-Object System.Drawing.Size(760, 680)
$form.MinimumSize = New-Object System.Drawing.Size(700, 584)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.KeyPreview = $true

$font   = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Font = $font

# --- scan row + language toggle ---
$lblScan = New-Object System.Windows.Forms.Label
$lblScan.Location = New-Object System.Drawing.Point(16, 12)
$lblScan.AutoSize = $true
$lblScan.ForeColor = [System.Drawing.Color]::FromArgb(60,60,60)

$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text = [char]::ConvertFromUtf32(0x2B06)   # up arrow: check for updates
$btnUpdate.Location = New-Object System.Drawing.Point(700, 5)
$btnUpdate.Size = New-Object System.Drawing.Size(28, 24)
$btnUpdate.FlatStyle = 'Flat'
$btnUpdate.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
$btnUpdate.BackColor = [System.Drawing.Color]::White
$btnUpdate.ForeColor = [System.Drawing.Color]::FromArgb(11,92,173)
$btnUpdate.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 9)
$btnUpdate.Anchor = 'Top,Right'
$script:Tip = New-Object System.Windows.Forms.ToolTip

$btnLang = New-Object System.Windows.Forms.Button
$btnLang.Location = New-Object System.Drawing.Point(598, 5)
$btnLang.Size = New-Object System.Drawing.Size(94, 24)
$btnLang.FlatStyle = 'Flat'
$btnLang.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
$btnLang.BackColor = [System.Drawing.Color]::White
$btnLang.ForeColor = [System.Drawing.Color]::FromArgb(11,92,173)
$btnLang.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$btnLang.Anchor = 'Top,Right'

$txtScan = New-Object System.Windows.Forms.TextBox
$txtScan.Font = New-Object System.Drawing.Font('Consolas', 16)
$txtScan.Location = New-Object System.Drawing.Point(16, 34)
$txtScan.Width = 712
$txtScan.Anchor = 'Top,Left,Right'
$txtScan.BackColor = [System.Drawing.Color]::FromArgb(255,255,220)

# --- status banner (colored panel: big state line + small admin detail) ---
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Location = New-Object System.Drawing.Point(16, 76)
$pnlStatus.Size = New-Object System.Drawing.Size(712, 52)
$pnlStatus.Anchor = 'Top,Left,Right'
$pnlStatus.BackColor = [System.Drawing.Color]::FromArgb(224,240,224)

$lblStatusMain = New-Object System.Windows.Forms.Label
$lblStatusMain.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblStatusMain.Location = New-Object System.Drawing.Point(10, 3)
$lblStatusMain.Size = New-Object System.Drawing.Size(694, 28)
$lblStatusMain.Anchor = 'Top,Left,Right'
$lblStatusMain.BackColor = [System.Drawing.Color]::Transparent
$lblStatusMain.ForeColor = [System.Drawing.Color]::FromArgb(19,115,51)

$lblStatusSub = New-Object System.Windows.Forms.Label
$lblStatusSub.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$lblStatusSub.Location = New-Object System.Drawing.Point(12, 33)
$lblStatusSub.Size = New-Object System.Drawing.Size(692, 16)
$lblStatusSub.Anchor = 'Top,Left,Right'
$lblStatusSub.BackColor = [System.Drawing.Color]::Transparent
$lblStatusSub.ForeColor = [System.Drawing.Color]::FromArgb(120,120,120)
$pnlStatus.Controls.AddRange(@($lblStatusMain, $lblStatusSub))

# --- product photo (left) + product info ---
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072  # TLS 1.2 for image/update fetches
$script:ImgCacheDir = Join-Path $script:AppDir 'imgcache'
if (-not (Test-Path $script:ImgCacheDir)) { New-Item -ItemType Directory -Path $script:ImgCacheDir -Force | Out-Null }

$picProduct = New-Object System.Windows.Forms.PictureBox
$picProduct.Location = New-Object System.Drawing.Point(16, 138)
$picProduct.Size = New-Object System.Drawing.Size(148, 145)
$picProduct.SizeMode = 'Zoom'
$picProduct.BorderStyle = 'FixedSingle'
$picProduct.BackColor = [System.Drawing.Color]::White

# neutral placeholder (camera glyph), shown while loading / when no photo exists
$script:NoPhotoImg = New-Object System.Drawing.Bitmap(148, 145)
$gph = [System.Drawing.Graphics]::FromImage($script:NoPhotoImg)
$gph.Clear([System.Drawing.Color]::FromArgb(246,247,249))
$phFont = New-Object System.Drawing.Font('Segoe UI Emoji', 34)
$phFmt = New-Object System.Drawing.StringFormat
$phFmt.Alignment = 'Center'; $phFmt.LineAlignment = 'Center'
$gph.DrawString([char]::ConvertFromUtf32(0x1F4F7), $phFont, [System.Drawing.Brushes]::Silver,
    (New-Object System.Drawing.RectangleF(0, 0, 148, 145)), $phFmt)
$gph.Dispose(); $phFont.Dispose(); $phFmt.Dispose()
$picProduct.Image = $script:NoPhotoImg

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = ''
$lblInfo.Location = New-Object System.Drawing.Point(176, 138)
$lblInfo.Size = New-Object System.Drawing.Size(284, 145)
$lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 10)

# --- label preview ---
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location = New-Object System.Drawing.Point(468, 138)
$pic.Size = New-Object System.Drawing.Size(260, 145)
$pic.SizeMode = 'Zoom'
$pic.BorderStyle = 'FixedSingle'
$pic.Anchor = 'Top,Right'
$pic.BackColor = [System.Drawing.Color]::White

# --- printer / qty / buttons panel ---
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Location = New-Object System.Drawing.Point(16, 292)
$grp.Size = New-Object System.Drawing.Size(712, 134)
$grp.Anchor = 'Top,Left,Right'

$lblPrinter = New-Object System.Windows.Forms.Label
$lblPrinter.Location = New-Object System.Drawing.Point(14, 28)
$lblPrinter.AutoSize = $true

$cboPrinter = New-Object System.Windows.Forms.ComboBox
$cboPrinter.DropDownStyle = 'DropDownList'
$cboPrinter.Location = New-Object System.Drawing.Point(120, 24)
$cboPrinter.Width = 400
foreach ($p in [System.Drawing.Printing.PrinterSettings]::InstalledPrinters) { [void]$cboPrinter.Items.Add($p) }
if ($settings.printerName -and $cboPrinter.Items.Contains($settings.printerName)) {
    $cboPrinter.SelectedItem = $settings.printerName
} else {
    # prefer a SATO / label printer if present
    $guess = $null
    foreach ($p in $cboPrinter.Items) { if ($p -match 'SATO|CL4NX|Zebra|ZDesigner|Thermal') { $guess = $p; break } }
    if ($guess) { $cboPrinter.SelectedItem = $guess } elseif ($cboPrinter.Items.Count -gt 0) { $cboPrinter.SelectedIndex = 0 }
}

$lblCountCap = New-Object System.Windows.Forms.Label
$lblCountCap.Location = New-Object System.Drawing.Point(16, 56)
$lblCountCap.AutoSize = $true
$lblCountCap.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblCountCap.ForeColor = [System.Drawing.Color]::Gray

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '-'
$lblCount.Location = New-Object System.Drawing.Point(14, 70)
$lblCount.Size = New-Object System.Drawing.Size(210, 36)
$lblCount.Font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold)
$lblCount.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)

$lblLeft = New-Object System.Windows.Forms.Label
$lblLeft.Text = ''
$lblLeft.Location = New-Object System.Drawing.Point(16, 107)
$lblLeft.Size = New-Object System.Drawing.Size(210, 20)
$lblLeft.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblLeft.ForeColor = [System.Drawing.Color]::FromArgb(176,98,0)

$btnPrint = New-Object System.Windows.Forms.Button
$btnPrint.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 13, [System.Drawing.FontStyle]::Bold)
$btnPrint.Location = New-Object System.Drawing.Point(240, 58)
$btnPrint.Size = New-Object System.Drawing.Size(456, 62)
$btnPrint.FlatStyle = 'Flat'
$btnPrint.FlatAppearance.BorderSize = 0
$btnPrint.Enabled = $false
# blue+white when armed; quiet gray "what to do next" when nothing is queued
$script:UpdatePrintButtonLook = {
    if ($btnPrint.Enabled) {
        $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(0,120,215)
        $btnPrint.ForeColor = [System.Drawing.Color]::White
        $btnPrint.Text = "$emojiPrinter  " + (T 'btnPrint')
    } else {
        $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(233,236,239)
        $btnPrint.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
        $btnPrint.Text = "$emojiPrinter  " + (T 'btnScanFirst')
    }
}
$btnPrint.add_EnabledChanged({ & $script:UpdatePrintButtonLook })
& $script:UpdatePrintButtonLook

$grp.Controls.AddRange(@($lblPrinter, $cboPrinter, $lblCountCap, $lblCount, $lblLeft, $btnPrint))

# big count display: "2 / 3" plus a loud what's-left line underneath
function Update-CountDisplay($job) {
    $total = [int]$job.Qty
    $done  = [int]$script:PrintedCount
    $lblCount.Text = "$done / $total"
    $left = $total - $done
    if ($left -gt 0) {
        $lblLeft.Text = (T 'moreToPrint') -f $left
        $lblLeft.ForeColor  = [System.Drawing.Color]::FromArgb(176,98,0)
        $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)
    } elseif ($done -eq $total) {
        $lblLeft.Text = T 'allDone'
        $lblLeft.ForeColor  = [System.Drawing.Color]::FromArgb(19,115,51)
        $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(19,115,51)
    } else {
        $lblLeft.Text = (T 'targetWas') -f $total
        $lblLeft.ForeColor  = [System.Drawing.Color]::Gray
        $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)
    }
}

# --- print history (newest first) ---
$lblHist = New-Object System.Windows.Forms.Label
$lblHist.Location = New-Object System.Drawing.Point(16, 436)
$lblHist.AutoSize = $true
$lblHist.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblHist.ForeColor = [System.Drawing.Color]::FromArgb(60,60,60)

# discreet spooler-fix button, tucked next to the history header
$btnSpooler = New-Object System.Windows.Forms.Button
$btnSpooler.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 8.5)
$btnSpooler.Location = New-Object System.Drawing.Point(590, 432)
$btnSpooler.Size = New-Object System.Drawing.Size(138, 26)
$btnSpooler.FlatStyle = 'Flat'
$btnSpooler.ForeColor = [System.Drawing.Color]::Gray
$btnSpooler.BackColor = [System.Drawing.Color]::White
$btnSpooler.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
$btnSpooler.Anchor = 'Top,Right'

$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.MultiSelect = $false
$lv.HideSelection = $true
$lv.HeaderStyle = 'Nonclickable'
$lv.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
$lv.Location = New-Object System.Drawing.Point(16, 462)
$lv.Size = New-Object System.Drawing.Size(712, 140)
$lv.Anchor = 'Top,Left,Right,Bottom'
[void]$lv.Columns.Add('Time', 120)
[void]$lv.Columns.Add('Labels', 55)
[void]$lv.Columns.Add('SKU', 225)
[void]$lv.Columns.Add('Product', 270)
# Product column fills the remaining width - no horizontal scrollbar
$lv.add_ClientSizeChanged({
    try { $lv.Columns[3].Width = [Math]::Max(150, ($lv.ClientSize.Width - 400 - 4)) } catch { }
})

# --- bottom status bar: today's total + update link ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.SizingGrip = $false
$statusStrip.AutoSize = $false
$statusStrip.Height = 28    # room for descenders at higher DPI scaling
$sbToday = New-Object System.Windows.Forms.ToolStripStatusLabel
$sbToday.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$sbToday.Spring = $true
$sbToday.TextAlign = 'MiddleLeft'
$sbUpdate = New-Object System.Windows.Forms.ToolStripStatusLabel
$sbUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$sbUpdate.ForeColor = [System.Drawing.Color]::FromArgb(11,92,173)
$sbUpdate.IsLink = $true
$sbUpdate.Text = ''
[void]$statusStrip.Items.Add($sbToday)
[void]$statusStrip.Items.Add($sbUpdate)

$script:TodayCount = Get-TodayPrinted
$script:TodayDate  = (Get-Date).Date
function Update-TodayBar {
    $sbToday.Text = (T 'todayBar') -f $script:TodayCount
}
function Bump-TodayCount {
    if ((Get-Date).Date -ne $script:TodayDate) { $script:TodayDate = (Get-Date).Date; $script:TodayCount = 0 }
    $script:TodayCount++
    Update-TodayBar
}
Update-TodayBar

$form.Controls.AddRange(@($lblScan, $btnUpdate, $btnLang, $txtScan, $pnlStatus, $picProduct, $lblInfo, $pic, $grp, $lblHist, $btnSpooler, $lv, $statusStrip))

# --- product photo loading: cache-first, then a parallel background download.
# Never blocks scanning/printing; a stale download never overwrites a newer scan.
function Set-ProductPhoto($img) {
    $old = $picProduct.Image
    $picProduct.Image = $img
    if ($old -and -not [object]::ReferenceEquals($old, $script:NoPhotoImg)) { try { $old.Dispose() } catch { } }
}
function Show-ProductImage($job) {
    $script:ImgReqSku = [string]$job.Sku
    $safe = ($job.Sku -replace '[^\w\-\.]', '_')
    if ($safe -eq '') { Set-ProductPhoto $script:NoPhotoImg; return }
    $cacheFile = Join-Path $script:ImgCacheDir "$safe.img"
    if (Test-Path $cacheFile) {
        try {
            $ms = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($cacheFile))
            Set-ProductPhoto ([System.Drawing.Image]::FromStream($ms))
            return
        } catch { }
    }
    Set-ProductPhoto $script:NoPhotoImg
    if ("$($job.ImageUrl)" -eq '') { return }
    try {
        $wc = New-Object System.Net.WebClient
        $wc | Add-Member -NotePropertyName JobSku -NotePropertyValue ([string]$job.Sku)
        $wc | Add-Member -NotePropertyName CacheFile -NotePropertyValue $cacheFile
        $wc.add_DownloadDataCompleted({
            param($sender, $e)
            try {
                if (-not $e.Cancelled -and -not $e.Error -and $e.Result.Length -gt 200) {
                    [System.IO.File]::WriteAllBytes($sender.CacheFile, $e.Result)
                    if ($script:ImgReqSku -eq $sender.JobSku) {
                        $ms2 = New-Object System.IO.MemoryStream(, $e.Result)
                        Set-ProductPhoto ([System.Drawing.Image]::FromStream($ms2))
                    }
                }
            } catch { }
            try { $sender.Dispose() } catch { }
        })
        $wc.DownloadDataAsync([Uri]$job.ImageUrl)
    } catch { }
}

$script:HistActive = $false   # true while the top row belongs to the queued product

function Add-HistRow($job) {
    if ($script:HistActive -and $lv.Items.Count -gt 0) {
        $it = $lv.Items[0]
        $it.SubItems[0].Text = (Get-Date).ToString('h:mm tt')
        $it.SubItems[1].Text = [string]$script:PrintedCount
    } else {
        $it = New-Object System.Windows.Forms.ListViewItem((Get-Date).ToString('h:mm tt'))
        [void]$it.SubItems.Add([string]$script:PrintedCount)
        [void]$it.SubItems.Add([string]$job.Sku)
        [void]$it.SubItems.Add([string]$job.Name)
        [void]$lv.Items.Insert(0, $it)
        $script:HistActive = $true
    }
}

# fill history from the log so workers can see where they left off
try {
    $hist = @(Load-History)
    if ($hist.Count -gt 50) { $hist = @($hist[($hist.Count-50)..($hist.Count-1)]) }
    [array]::Reverse($hist)
    foreach ($h in $hist) {
        $it = New-Object System.Windows.Forms.ListViewItem((Format-HistTime $h.Ts))
        [void]$it.SubItems.Add([string]$h.Count)
        [void]$it.SubItems.Add([string]$h.Sku)
        [void]$it.SubItems.Add([string]$h.Name)
        [void]$lv.Items.Add($it)
    }
} catch { }

$script:CurrentJob = $null
$script:PrintedCount = 0

function Set-Status([string]$text, [string]$kind, [string]$sub = '') {
    $lblStatusMain.Text = $text
    $lblStatusSub.Text = $sub
    switch ($kind) {
        'ok'    { $bg = [System.Drawing.Color]::FromArgb(224,240,224); $fg = [System.Drawing.Color]::FromArgb(19,115,51) }
        'info'  { $bg = [System.Drawing.Color]::FromArgb(222,236,252); $fg = [System.Drawing.Color]::FromArgb(11,92,173) }
        'warn'  { $bg = [System.Drawing.Color]::FromArgb(254,243,224); $fg = [System.Drawing.Color]::FromArgb(160,98,0) }
        'error' { $bg = [System.Drawing.Color]::FromArgb(250,228,228); $fg = [System.Drawing.Color]::FromArgb(180,30,30) }
        default { $bg = [System.Drawing.Color]::FromArgb(224,240,224); $fg = [System.Drawing.Color]::FromArgb(19,115,51) }  # ready = green
    }
    $pnlStatus.BackColor = $bg
    $lblStatusMain.ForeColor = $fg
}

function Update-Preview($job) {
    try {
        $bmp = Render-LabelBitmap $settings $job 203
        if ($pic.Image) { $pic.Image.Dispose() }
        $pic.Image = $bmp
    } catch { }
}

# banner text for the current job state (used after prints and language toggles)
function Show-JobStatus($job) {
    $printer = [string]$cboPrinter.SelectedItem
    $done = $script:PrintedCount; $total = [int]$job.Qty; $left = $total - $done
    $detail = "[$($job.Sku)]  $($job.Name)     ->  $printer"
    if ($done -eq 0) {
        $word = if ($total -eq 1) { T 'labelWordOne' } else { T 'labelWordMany' }
        $qdetail = "[$($job.Sku)]  $($job.Name)" + $(if ($job.Client) { "     $(T 'wClient')  $($job.Client)" })
        if ($job.SqlStatus -ne '' -and $job.SqlStatus -notlike 'Note:*') {
            Set-Status ((T 'printOffline') -f $total, $word) 'warn' "$qdetail     $($job.SqlStatus)"
        } else {
            Set-Status ((T 'printLabels') -f $total, $word) 'info' $qdetail
        }
    } elseif ($left -gt 0) {
        Set-Status ((T 'printedProgress') -f $done, $total, $left) 'info' $detail
    } elseif ($done -eq $total) {
        Set-Status ((T 'printedAll') -f $total) 'ok' $detail
    } else {
        Set-Status ((T 'printedOver') -f $done, $total) 'warn' $detail
    }
}

function Do-Print($job) {
    $printer = [string]$cboPrinter.SelectedItem
    if (-not $printer) { Set-Status (T 'noPrinter') 'error'; return }
    try {
        [void](Print-Labels $settings $job $printer 1)
        $script:PrintedCount++
        Update-CountDisplay $job
        Bump-TodayCount
        Add-HistRow $job
        Show-JobStatus $job
        Write-PrintLog $job.Raw $job.Sku 1 $printer 'ok' $job.Name
    } catch {
        Set-Status (T 'printFailed') 'error' $_.Exception.Message
        Write-PrintLog $job.Raw $job.Sku 1 $printer ("error: " + $_.Exception.Message)
    }
}

function Show-JobInfo($job) {
    $info = "$(T 'wProduct')`n$($job.Name)`n`n$(T 'wSku')  $($job.Sku)`n$(T 'wBarcode')  $($job.Barcode)"
    if ($job.Client) { $info += "`n$(T 'wClient')  $($job.Client)" }
    $lblInfo.Text = $info
}

function Handle-Scan([string]$raw) {
    $job = Parse-ScanPayload $raw
    if (-not $job) { Set-Status (T 'cantRead') 'error'; return }
    if ($job.FromQR -and $job.Sku -eq '') {
        $script:CurrentJob = $null
        $btnPrint.Enabled = $false
        $lblCount.Text = '-'
        $lblLeft.Text = ''
        Set-Status (T 'skuMissing') 'error' ((T 'scanned') + $raw)
        Write-PrintLog $raw '' 0 '' 'sku missing'
        [void][System.Windows.Forms.MessageBox]::Show($form, ((T 'skuMissingPop') -f $raw),
            (T 'skuMissingTitle'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        $txtScan.Focus()
        return
    }
    Set-Status (T 'looking') 'info'
    $form.Refresh()
    $job = Resolve-Job $settings $job
    $script:CurrentJob = $job
    $script:PrintedCount = 0
    $script:HistActive = $false
    Update-CountDisplay $job
    Show-JobInfo $job
    Show-ProductImage $job
    Update-Preview $job

    if (-not $job.CanPrint) {
        $btnPrint.Enabled = $false
        $lblCount.Text = '-'
        $lblLeft.Text = ''
        Set-Status (T 'notFound') 'error' ((T 'scanned') + $raw)
        Write-PrintLog $raw '' 0 '' 'not found'
        return
    }
    $btnPrint.Enabled = $true
    Show-JobStatus $job
}

$txtScan.add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true
        $raw = $txtScan.Text
        $txtScan.Clear()
        if ($raw.Trim() -ne '') { Handle-Scan $raw }
    }
})

$btnPrint.add_Click({ if ($script:CurrentJob) { Do-Print $script:CurrentJob }; $txtScan.Focus() })
$cboPrinter.add_SelectedIndexChanged({ $settings.printerName = [string]$cboPrinter.SelectedItem; Save-Settings $settings; $txtScan.Focus() })
# Clear all stuck print jobs and restart the Windows print spooler (elevated)
function Clear-Spooler {
    Set-Status (T 'spoolClearing') 'warn' ''
    $form.Refresh()
    # single-quoted: $env expands inside the ELEVATED powershell, not here
    $cmd = 'Stop-Service Spooler -Force; Start-Sleep 1; Remove-Item $env:SystemRoot\System32\spool\PRINTERS\* -Force -ErrorAction SilentlyContinue; Start-Service Spooler'
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
             -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command $cmd"
        if ($p.ExitCode -eq 0) {
            Set-Status (T 'spoolFixed') 'ok' (T 'spoolFixedSub')
            Write-PrintLog 'spooler-reset' '' 0 '' 'ok'
        } else {
            Set-Status "Spooler restart finished with exit code $($p.ExitCode)." 'warn' ''
            Write-PrintLog 'spooler-reset' '' 0 '' "exit $($p.ExitCode)"
        }
    } catch {
        Set-Status (T 'spoolCanceled') 'error' ''
        Write-PrintLog 'spooler-reset' '' 0 '' 'canceled'
    }
    $txtScan.Focus()
}
$btnSpooler.add_Click({ Clear-Spooler })

# --- one-time station setup: SQL connection string (kept out of the app file) ---
if ([string]"$($settings.sqlConn)" -eq '' -and -not $SmokeTest) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $entered = [Microsoft.VisualBasic.Interaction]::InputBox(
        "One-time station setup`n`nPaste the ShipBots SQL connection string for this station.`n(Ask the admin - it looks like:  Server=...;Database=sbsql;User ID=...;Password=...)`n`nLeave empty to skip: the app still prints from QR data, but product names/clients won't fill in.",
        'Autobagger Barcode Printer - SQL setup', '')
    if ($entered -and $entered.Trim() -ne '') {
        $settings.sqlConn = $entered.Trim()
        Save-Settings $settings
    }
}

# --- language toggle ---
function Apply-Language {
    $btnLang.Text = if ($script:Lang -eq 'en') { 'Español' } else { 'English' }
    if ("$($script:AvailableVersion)" -ne '') {
        $script:Tip.SetToolTip($btnUpdate, ((T 'updateLink') -f $script:AvailableVersion))
        $sbUpdate.Text = (T 'updateLink') -f $script:AvailableVersion
    } else {
        $script:Tip.SetToolTip($btnUpdate, (T 'updTooltip'))
    }
    $lblScan.Text = T 'scanCap'
    $grp.Text = T 'grpPrinting'
    $lblPrinter.Text = T 'sendTo'
    $lblCountCap.Text = T 'countCap'
    $lblHist.Text = T 'histCap'
    $btnSpooler.Text = "$emojiBroom " + (T 'btnSpooler')
    $lv.Columns[0].Text = T 'colTime'
    $lv.Columns[1].Text = T 'colLabels'
    $lv.Columns[3].Text = T 'colProduct'
    Update-TodayBar
    & $script:UpdatePrintButtonLook
    if ($script:CurrentJob -and $script:CurrentJob.CanPrint) {
        Update-CountDisplay $script:CurrentJob
        Show-JobInfo $script:CurrentJob
        Show-JobStatus $script:CurrentJob
    } else {
        Set-Status (T 'ready') 'ready' (T 'readySub')
    }
}
$btnLang.add_Click({
    $script:Lang = if ($script:Lang -eq 'en') { 'es' } else { 'en' }
    $settings.language = $script:Lang
    Save-Settings $settings
    Apply-Language
    $txtScan.Focus()
})
Apply-Language

# --- self-update: compare against the released copy on the office share ---
$script:AvailableVersion = ''

# non-intrusive hint: blue arrow button + status-bar link; never a popup
function Set-UpdateHint([string]$ver) {
    $script:AvailableVersion = $ver
    if ($ver -ne '') {
        $sbUpdate.Text = (T 'updateLink') -f $ver
        $btnUpdate.BackColor = [System.Drawing.Color]::FromArgb(0,120,215)
        $btnUpdate.ForeColor = [System.Drawing.Color]::White
        $script:Tip.SetToolTip($btnUpdate, ((T 'updateLink') -f $ver))
    } else {
        $sbUpdate.Text = ''
        $btnUpdate.BackColor = [System.Drawing.Color]::White
        $btnUpdate.ForeColor = [System.Drawing.Color]::FromArgb(11,92,173)
        $script:Tip.SetToolTip($btnUpdate, (T 'updTooltip'))
    }
}
function Invoke-SelfUpdate([string]$remotePath) {
    try {
        Copy-Item -LiteralPath $remotePath -Destination $PSCommandPath -Force
        [void][System.Windows.Forms.MessageBox]::Show($form,
            'Updated! The app will now restart.', 'Update complete',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        Start-Process 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
        $form.Close()
    } catch {
        Set-Status 'UPDATE FAILED - keeping the current version' 'error' $_.Exception.Message
    }
}

function Check-ForUpdate([switch]$Silent, [switch]$Interactive) {
    # web release page first, LAN share as fallback
    $info = $null
    $url = [string]$settings.updateSourceUrl
    if ($url -eq '') { $url = [string]$script:DefaultSettings.updateSourceUrl }  # blank saved value -> current default
    if ($url -ne '') { $info = Get-RemoteReleaseInfo $url }
    if (-not $info) {
        $src = [string]$settings.updateSource
        if ($src -ne '' -and $src -ine $PSCommandPath) { $info = Get-RemoteReleaseInfo $src }
    }
    if (-not $info) {
        if ($Interactive) { $script:Tip.Show((T 'updNoServer'), $btnUpdate, -220, 30, 3500) }  # fades by itself
        return
    }
    if ($info.Version -le [version]$script:AppVersion) {
        Set-UpdateHint ''
        if ($Interactive) { $script:Tip.Show(((T 'updUpToDate') -f $script:AppVersion), $btnUpdate, -160, 30, 3500) }
        return
    }
    $rv = $info.Version
    Set-UpdateHint "$rv"
    if (-not $Interactive) { return }   # timer/startup: hint only, never interrupt
    $ans = [System.Windows.Forms.MessageBox]::Show($form,
        "A new version of $($script:AppName) is available.`n`nYou have:   v$($script:AppVersion)`nAvailable:  v$rv`n`nDownload and update now? (takes a few seconds, the app restarts)",
        'Update available', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-SelfUpdate $info.File }
}

$sbUpdate.add_Click({ Check-ForUpdate -Interactive })
$btnUpdate.add_Click({
    Check-ForUpdate -Interactive
    $txtScan.Focus()
})

# check shortly after launch (so startup is never delayed), then every 4 hours
$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 8000
$updTimer.add_Tick({
    $updTimer.Interval = 4 * 60 * 60 * 1000
    Check-ForUpdate
})
$updTimer.Start()

# Ctrl+P anywhere in the window = print one label (KeyPreview is on)
$form.add_KeyDown({
    param($sender, $e)
    if ($e.Control -and $e.KeyCode -eq 'P') {
        $e.SuppressKeyPress = $true
        if ($script:CurrentJob -and $btnPrint.Enabled) { Do-Print $script:CurrentJob }
    }
})
$form.add_Shown({
    $txtScan.Focus()
    # never taller than the screen's working area (small monitors / DPI scaling):
    # the anchored history list absorbs the shrink, status bar stays visible
    try {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        if ($form.Height -gt $wa.Height) { $form.Height = $wa.Height }
        if ($form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
        if ($form.Top -lt $wa.Top) { $form.Top = $wa.Top }
    } catch { }
    # snap the history list to whole rows so the last visible line isn't cut off
    try {
        if ($lv.Items.Count -gt 0) {
            $r0 = $lv.GetItemRect(0)
            $rows = [Math]::Max(2, [Math]::Floor(($lv.ClientSize.Height - $r0.Y) / $r0.Height))
            $lv.Height = ($lv.Height - $lv.ClientSize.Height) + $r0.Y + ($rows * $r0.Height) + 2
        }
    } catch { }
})
# keep the scan box focused so wedge scans always land there
$form.add_Click({ $txtScan.Focus() })

if ($SmokeTest) {
    # render the form off-screen to a PNG and exit (used for automated UI check)
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-3000, -3000)
    $form.Show()
    $bmp0 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp0, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp0.Save((Join-Path $script:AppDir 'smoketest-ui-ready.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp0.Dispose()
    $job = Parse-ScanPayload '7199-205|781910689|3'
    $job = Resolve-Job $settings $job
    $script:CurrentJob = $job
    $lblInfo.Text = "Product:`n$($job.Name)`n`nSKU:  $($job.Sku)`nBarcode:  $($job.Barcode)`nClient:  $($job.Client)"
    Update-Preview $job
    # seed a fake cached product photo to prove the photo pane renders
    $tb = New-Object System.Drawing.Bitmap(300, 300)
    $tg = [System.Drawing.Graphics]::FromImage($tb)
    $tg.Clear([System.Drawing.Color]::FromArgb(70,105,140))
    $tf = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $tg.DrawString("JEANS`nPHOTO", $tf, [System.Drawing.Brushes]::White, 60, 100)
    $tg.Dispose(); $tf.Dispose()
    $tcache = Join-Path $script:ImgCacheDir '7199-205.img'
    $tb.Save($tcache, [System.Drawing.Imaging.ImageFormat]::Png); $tb.Dispose()
    Show-ProductImage $job
    $btnPrint.Enabled = $true
    $script:PrintedCount = 2
    Add-HistRow $job
    $script:HistActive = $false
    $script:PrintedCount = 1
    Add-HistRow $job
    $script:PrintedCount = 2
    Update-CountDisplay $job
    Set-Status 'PRINTED 2 of 3  -  1 more, press Ctrl+P' 'info' "[$($job.Sku)]  $($job.Name)     ->  SATO CL4NX Plus (203 dpi)"
    # verify update detection against a fake newer release
    $fake = Join-Path $env:TEMP 'abp-fake-release.ps1'
    "`$script:AppVersion = '9.9.9'" | Set-Content $fake
    $settings.updateSource = $fake
    Check-ForUpdate -Silent
    Write-Host "UPDATECHECK: '$($sbUpdate.Text)' (local v$($script:AppVersion))"
    Remove-Item $fake -Force
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $out = Join-Path $script:AppDir 'smoketest-ui.png'
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    # Spanish rendering check
    $script:Lang = 'es'
    Apply-Language
    $form.Refresh()
    $bmp2 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp2, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp2.Save((Join-Path $script:AppDir 'smoketest-ui-es.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
    $form.Close()
    Write-Host "SMOKETEST: saved $out (+ smoketest-ui-es.png)"
    exit 0
}

[void]$form.ShowDialog()
