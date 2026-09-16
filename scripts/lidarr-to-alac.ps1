# lidarr-to-alac.ps1 — lossless (prefer FLAC) → parallel ALAC tree + cover embed.
# Windows-native Lidarr Custom Script (On Release Import / On Upgrade) and CLI.
# Behavior aligned with lidarr-to-alac.sh. Does not write into the master/FLAC root.
#
# Cover priority (exact):
#   1. Embedded picture from the source lossless file
#   2. Album folder cover.jpg / Cover.jpg
#   3. Album folder folder.jpg / Folder.jpg
#   4. Other Lidarr art in the album folder (named list; prefer larger)
#   5. Cover Art Archive, only with a MusicBrainz Release ID (never scrape)
#   6. Skip embed, log, treat missing art as non-fatal
[CmdletBinding()]
param(
    [switch]$Scan,
    [string]$PrintCover,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$CaaUserAgent = "music-library-apple-alac/$Version (https://github.com/wing199901/music-library-apple-alac)"

function Get-EnvOr {
    param([string]$Name, [string]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$MasterRoot = Get-EnvOr 'MASTER_ROOT' 'M:\'
$AlacRoot = Get-EnvOr 'ALAC_ROOT' 'D:\Music-ALAC'
$LogFile = Get-EnvOr 'LOG_FILE' ''
$Ffmpeg = Get-EnvOr 'FFMPEG' 'ffmpeg'
$Ffprobe = Get-EnvOr 'FFPROBE' 'ffprobe'
$CoverArtArchive = Get-EnvOr 'COVER_ART_ARCHIVE' '1'
$CaaReleaseUrl = Get-EnvOr 'CAA_RELEASE_URL' 'https://coverartarchive.org/release/{0}/front'

$LossyExt = @('.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wma', '.mp4', '.mpc')
$LosslessExt = @('.flac', '.dsf', '.dff', '.tak', '.ape', '.wav', '.wv', '.aiff', '.aif', '.w64', '.tta')
$SkipDirNames = @(
    'System Volume Information', '$RECYCLE.BIN', 'Recycler', '.Trash', '.Trashes',
    '#recycle', '@eaDir', '.Spotlight-V100', '.fseventsd'
)

$script:WorkDir = $null
$script:ConvertOk = 0
$script:ConvertSkip = 0
$script:ConvertFail = 0
$script:CoverOk = 0
$script:CoverSkip = 0
$script:CoverNone = 0

function Show-Usage {
    @'
Usage: lidarr-to-alac.ps1 [-Scan] [-PrintCover FILE] [FILE_OR_DIR ...]

Lidarr: Settings → Connect → Custom Script (On Release Import + On Upgrade).
Reads lidarr_eventtype / lidarr_addedtrackpaths (pipe-separated). Test → exit 0.

Env:
  MASTER_ROOT   default M:\
  ALAC_ROOT     default D:\Music-ALAC
  LOG_FILE      default %ALAC_ROOT%\_lidarr_to_alac.log
  COVER_ART_ARCHIVE=0 to disable Cover Art Archive
'@
}

function Write-AlacLog([string]$Message) {
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "$ts $Message"
    [Console]::Error.WriteLine($line)
    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Get-Ext([string]$Path) {
    return ([IO.Path]::GetExtension($Path)).ToLowerInvariant()
}

function Get-Stem([string]$Path) {
    return [IO.Path]::GetFileNameWithoutExtension($Path)
}

function Test-Lossy([string]$Path) { return $LossyExt -contains (Get-Ext $Path) }
function Test-Lossless([string]$Path) { return $LosslessExt -contains (Get-Ext $Path) }

function Test-Uuid([string]$Value) {
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-LidarrArtName([string]$FileName) {
    switch ($FileName.ToLowerInvariant()) {
        { $_ -in @(
                'cover.jpg', 'cover.jpeg', 'cover.png', 'cover.webp', 'cover.bmp',
                'folder.jpg', 'folder.jpeg', 'folder.png', 'folder.webp', 'folder.bmp',
                'poster.jpg', 'poster.jpeg', 'poster.png', 'poster.webp',
                'fanart.jpg', 'fanart.jpeg', 'fanart.png', 'fanart.webp',
                'banner.jpg', 'banner.jpeg', 'banner.png', 'banner.webp',
                'disc.jpg', 'disc.jpeg', 'disc.png', 'disc.webp',
                'front.jpg', 'front.jpeg', 'front.png', 'front.webp',
                'back.jpg', 'back.jpeg', 'back.png', 'back.webp',
                'album.jpg', 'album.jpeg', 'album.png', 'album.webp',
                'albumart.jpg', 'albumart.jpeg', 'albumart.png', 'albumartsmall.jpg',
                'artwork.jpg', 'artwork.jpeg', 'artwork.png', 'artwork.webp',
                'scan.jpg', 'scan.jpeg', 'scan.png',
                'logo.jpg', 'logo.jpeg', 'logo.png', 'clearlogo.png', 'clearlogo.jpg'
            ) } { return $true }
        default { return $false }
    }
}

function Test-SkipDirName([string]$Name) {
    if ($Name.StartsWith('.')) { return $true }
    foreach ($n in $SkipDirNames) {
        if ($Name -eq $n) { return $true }
    }
    return $false
}

function Get-Canon([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Test-UnderRoot([string]$Path, [string]$Root) {
    $p = (Get-Canon $Path).TrimEnd('\', '/')
    $r = (Get-Canon $Root).TrimEnd('\', '/')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $r + [IO.Path]::DirectorySeparatorChar
    return $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-HasVideoStream([string]$File) {
    $out = & $Ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 $File 2>$null
    return -not [string]::IsNullOrWhiteSpace($out)
}

function Get-ImageArea([string]$File) {
    $dim = & $Ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x $File 2>$null
    if ($dim -match '^(\d+)x(\d+)$') {
        return [int]$Matches[1] * [int]$Matches[2]
    }
    return 0
}

function Get-FileSize([string]$File) {
    return (Get-Item -LiteralPath $File).Length
}

function Get-LargerImage([string[]]$Files) {
    $best = $null
    $bestArea = -1
    $bestSize = -1L
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $area = Get-ImageArea $f
        $sz = Get-FileSize $f
        if (($area -gt $bestArea) -or (($area -eq $bestArea) -and ($sz -gt $bestSize))) {
            $best = $f
            $bestArea = $area
            $bestSize = $sz
        }
    }
    return $best
}

function Get-ReleaseMbidFromTags([string]$File) {
    $lines = & $Ffprobe -v error -show_entries format_tags -of default=nw=1 $File 2>$null
    foreach ($line in $lines) {
        if ($line -notmatch '=') { continue }
        $key, $val = $line.Split('=', 2)
        $key = $key -replace '^TAG:', ''
        switch ($key.ToLowerInvariant()) {
            'musicbrainz_albumid' { if (Test-Uuid $val) { return $val } }
            'musicbrainz album id' { if (Test-Uuid $val) { return $val } }
            'musicbrainz_releaseid' { if (Test-Uuid $val) { return $val } }
            'musicbrainz release id' { if (Test-Uuid $val) { return $val } }
        }
    }
    return $null
}

function Get-ReleaseMbid([string]$Src) {
    $envId = Get-EnvOr 'lidarr_albumrelease_mbid' (Get-EnvOr 'RELEASE_MBID' '')
    if (Test-Uuid $envId) { return $envId }
    $tagId = Get-ReleaseMbidFromTags $Src
    if (Test-Uuid $tagId) { return $tagId }
    return $null
}

function Invoke-CoverArtArchive([string]$Mbid, [string]$Dest) {
    $url = ($CaaReleaseUrl -f $Mbid)
    Invoke-WebRequest -Uri $url -OutFile $Dest -UserAgent $CaaUserAgent -TimeoutSec 30 -UseBasicParsing | Out-Null
}

function Find-Cover([string]$Src) {
    $albumDir = Split-Path -Parent $Src
    $pic = Join-Path $script:WorkDir ("embedded-" + (Get-Stem $Src) + ".jpg")

    if (Test-HasVideoStream $Src) {
        & $Ffmpeg -hide_banner -loglevel error -nostdin -y -i $Src -an -map 0:v:0 -frames:v 1 -c:v mjpeg -q:v 2 -f image2 $pic 2>$null
        if ((Test-Path -LiteralPath $pic) -and ((Get-Item -LiteralPath $pic).Length -gt 0)) {
            return @{ Kind = 'embedded'; Path = $pic }
        }
    }

    foreach ($name in @('cover.jpg', 'Cover.jpg')) {
        $p = Join-Path $albumDir $name
        if (Test-Path -LiteralPath $p) { return @{ Kind = 'cover.jpg'; Path = $p } }
    }
    foreach ($name in @('folder.jpg', 'Folder.jpg')) {
        $p = Join-Path $albumDir $name
        if (Test-Path -LiteralPath $p) { return @{ Kind = 'folder.jpg'; Path = $p } }
    }

    $cands = @()
    Get-ChildItem -LiteralPath $albumDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-LidarrArtName $_.Name) { $cands += $_.FullName }
    }
    $winner = Get-LargerImage $cands
    if ($winner) { return @{ Kind = 'folder-art'; Path = $winner } }

    if ($CoverArtArchive -eq '1') {
        $mbid = Get-ReleaseMbid $Src
        if (Test-Uuid $mbid) {
            $caa = Join-Path $script:WorkDir "caa-$mbid.jpg"
            if (-not ((Test-Path -LiteralPath $caa) -and ((Get-Item -LiteralPath $caa).Length -gt 0))) {
                try {
                    Invoke-CoverArtArchive $mbid $caa
                }
                catch {
                    Remove-Item -LiteralPath $caa -ErrorAction SilentlyContinue
                }
            }
            if ((Test-Path -LiteralPath $caa) -and ((Get-Item -LiteralPath $caa).Length -gt 0)) {
                return @{ Kind = 'cover-art-archive'; Path = $caa }
            }
            Write-AlacLog "COVER_CAA_MISS mbid=$mbid src=$Src"
        }
        else {
            Write-AlacLog "COVER_CAA_SKIP no MusicBrainz Release ID for $Src"
        }
    }

    return @{ Kind = 'none'; Path = '' }
}

function Get-PreferredSource([string]$Src) {
    $dir = Split-Path -Parent $Src
    $stem = Get-Stem $Src
    $flac = Join-Path $dir ($stem + '.flac')
    if (Test-Path -LiteralPath $flac) { return $flac }
    return $Src
}

function Get-RelUnderMaster([string]$Src) {
    $full = (Get-Canon $Src).TrimEnd('\', '/')
    $root = (Get-Canon $MasterRoot).TrimEnd('\', '/')
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full.Substring($prefix.Length)
}

function Get-DestForSource([string]$Src) {
    $rel = Get-RelUnderMaster $Src
    if ($null -eq $rel) { return $null }
    $relDir = Split-Path -Parent $rel
    $stem = Get-Stem $Src
    $root = (Get-Canon $AlacRoot).TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($relDir) -or $relDir -eq '.') {
        return (Join-Path $root ($stem + '.m4a'))
    }
    return (Join-Path (Join-Path $root $relDir) ($stem + '.m4a'))
}

function Assert-DestSafe([string]$Dest) {
    if (Test-UnderRoot $Dest $MasterRoot) {
        Write-AlacLog "REFUSE would write ALAC inside MASTER_ROOT dest=$Dest master=$MasterRoot"
        return $false
    }
    if (-not (Test-UnderRoot $Dest $AlacRoot)) {
        Write-AlacLog "REFUSE dest not under ALAC_ROOT dest=$Dest alac=$AlacRoot"
        return $false
    }
    return $true
}

function Test-NeedsConvert([string]$Src, [string]$Dest) {
    if (-not (Test-Path -LiteralPath $Dest)) { return $true }
    if ((Get-Item -LiteralPath $Dest).Length -le 0) { return $true }
    $sm = (Get-Item -LiteralPath $Src).LastWriteTimeUtc
    $dm = (Get-Item -LiteralPath $Dest).LastWriteTimeUtc
    return $sm -gt $dm
}

function Convert-One([string]$Src, [string]$Dest) {
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $partial = [IO.Path]::ChangeExtension($Dest, $null).TrimEnd('.') + '.partial.m4a'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    & $Ffmpeg -hide_banner -loglevel error -nostdin -y -i $Src -map 0:a:0 -map_metadata 0 -vn -c:a alac -f mp4 $partial
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $partial) -or ((Get-Item -LiteralPath $partial).Length -le 0)) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        return $false
    }
    Move-Item -LiteralPath $partial -Destination $Dest -Force
    return $true
}

function Embed-Cover([string]$Dest, [string]$Cover) {
    $tmp = [IO.Path]::ChangeExtension($Dest, $null).TrimEnd('.') + '.embed.partial.m4a'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    & $Ffmpeg -hide_banner -loglevel error -nostdin -y -i $Dest -i $Cover `
        -map 0:a:0 -map 1:0 -map_metadata 0 `
        -c:a copy -c:v:0 mjpeg -disposition:v:0 attached_pic -f mp4 $tmp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp) -or ((Get-Item -LiteralPath $tmp).Length -le 0)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    Move-Item -LiteralPath $tmp -Destination $Dest -Force
    return $true
}

function Invoke-ProcessSource([string]$Raw) {
    if (-not (Test-Path -LiteralPath $Raw -PathType Leaf)) {
        Write-AlacLog "SKIP_MISSING $Raw"
        return
    }
    $src = Get-PreferredSource $Raw
    if (Test-Lossy $src) {
        Write-AlacLog "SKIP_LOSSY $src"
        $script:ConvertSkip++
        return
    }
    if (-not (Test-Lossless $src)) {
        Write-AlacLog "SKIP_NOT_LOSSLESS $src"
        $script:ConvertSkip++
        return
    }
    $dest = Get-DestForSource $src
    if ($null -eq $dest) {
        Write-AlacLog "SKIP_OUTSIDE_MASTER $src master=$MasterRoot"
        $script:ConvertSkip++
        return
    }
    if (-not (Assert-DestSafe $dest)) {
        $script:ConvertFail++
        return
    }
    if (Test-NeedsConvert $src $dest) {
        Write-AlacLog "CONV $src -> $dest"
        if (Convert-One $src $dest) {
            $script:ConvertOk++
            Write-AlacLog "CONV_OK $dest"
        }
        else {
            $script:ConvertFail++
            Write-AlacLog "CONV_FAIL $src"
            return
        }
    }
    else {
        $script:ConvertSkip++
        Write-AlacLog "SKIP_UPTODATE $dest"
    }

    if (Test-HasVideoStream $dest) {
        Write-AlacLog "COVER_SKIP already has video/attached pic: $dest"
        $script:CoverSkip++
        return
    }

    $found = Find-Cover $src
    if ($found.Kind -eq 'none' -or [string]::IsNullOrWhiteSpace($found.Path)) {
        Write-AlacLog "COVER_NONE no art for $dest (convert ok; missing art non-fatal)"
        $script:CoverNone++
        return
    }
    Write-AlacLog "COVER_EMBED kind=$($found.Kind) cover=$($found.Path) dest=$dest"
    if (Embed-Cover $dest $found.Path) {
        $script:CoverOk++
        Write-AlacLog "COVER_OK kind=$($found.Kind) dest=$dest"
    }
    else {
        Write-AlacLog "COVER_FAIL kind=$($found.Kind) dest=$dest (convert kept; embed non-fatal)"
        $script:CoverNone++
    }
}

function Get-ScanSources([string]$Root) {
    $chosen = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $skip = $false
        foreach ($part in $_.FullName.Split([IO.Path]::DirectorySeparatorChar)) {
            if (Test-SkipDirName $part) { $skip = $true; break }
        }
        if ($skip) { return }
        $ext = Get-Ext $_.FullName
        if ($LosslessExt -notcontains $ext) { return }
        $dir = Split-Path -Parent $_.FullName
        $stem = Get-Stem $_.FullName
        $key = Join-Path $dir $stem
        if ($ext -eq '.flac') {
            $chosen[$key] = $_.FullName
        }
        elseif (-not $chosen.ContainsKey($key)) {
            $chosen[$key] = $_.FullName
        }
    }
    return @($chosen.Values | Sort-Object)
}

function Initialize-Paths {
    Set-Variable -Name MasterRoot -Value (Get-Canon $MasterRoot) -Scope Script
    Set-Variable -Name AlacRoot -Value (Get-Canon $AlacRoot) -Scope Script
    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $script:LogFile = Join-Path $AlacRoot '_lidarr_to_alac.log'
    }
    else {
        $script:LogFile = $LogFile
    }
    if (-not (Test-Path -LiteralPath $AlacRoot)) {
        New-Item -ItemType Directory -Force -Path $AlacRoot | Out-Null
    }
    if ((Get-Canon $AlacRoot).TrimEnd('\', '/').Equals((Get-Canon $MasterRoot).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "ALAC_ROOT must not equal MASTER_ROOT (got $AlacRoot)"
    }
    $script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("lidarr-to-alac-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
}

try {
    $event = Get-EnvOr 'lidarr_eventtype' ''
    if ($event -eq 'Test') {
        Write-Output 'lidarr-to-alac: Test OK'
        exit 0
    }

    if ($args -contains '-h' -or $args -contains '--help') {
        Show-Usage
        exit 0
    }

    Initialize-Paths
    Write-AlacLog "START version=$Version master=$MasterRoot alac=$AlacRoot event=$(if ($event) { $event } else { 'cli' })"

    if (-not [string]::IsNullOrWhiteSpace($PrintCover)) {
        $found = Find-Cover $PrintCover
        Write-Output ("{0}`t{1}" -f $found.Kind, $found.Path)
        Write-AlacLog "PRINT_COVER $PrintCover -> $($found.Kind)"
        exit 0
    }

    if ($event -eq 'AlbumDownload') {
        $added = Get-EnvOr 'lidarr_addedtrackpaths' ''
        if ([string]::IsNullOrWhiteSpace($added)) {
            Write-AlacLog 'AlbumDownload with empty lidarr_addedtrackpaths; nothing to do'
            exit 0
        }
        foreach ($p in ($added -split '\|')) {
            if (-not [string]::IsNullOrWhiteSpace($p)) { Invoke-ProcessSource $p }
        }
    }
    elseif ($Scan) {
        if (-not (Test-Path -LiteralPath $MasterRoot -PathType Container)) {
            throw "MASTER_ROOT not a directory: $MasterRoot"
        }
        foreach ($f in (Get-ScanSources $MasterRoot)) { Invoke-ProcessSource $f }
    }
    elseif ($Paths -and $Paths.Count -gt 0) {
        foreach ($a in $Paths) {
            if (Test-Path -LiteralPath $a -PathType Container) {
                foreach ($f in (Get-ScanSources $a)) { Invoke-ProcessSource $f }
            }
            else {
                Invoke-ProcessSource $a
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($event)) {
        Write-AlacLog "IGNORE event=$event (only AlbumDownload / Test / CLI)"
        exit 0
    }
    else {
        Show-Usage
        exit 2
    }

    Write-AlacLog "DONE ok=$($script:ConvertOk) skip=$($script:ConvertSkip) fail=$($script:ConvertFail) cover_ok=$($script:CoverOk) cover_skip=$($script:CoverSkip) cover_none=$($script:CoverNone)"
    if ($script:ConvertFail -gt 0) { exit 1 }
    exit 0
}
finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
