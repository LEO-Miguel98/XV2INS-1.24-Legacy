param(
    [string]$WorkRoot = "$PSScriptRoot\..\work",
    [string]$OutputRoot = "$PSScriptRoot\..\dist"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Xv2InsRepo = 'https://github.com/HAWGT/xv2ins.git'
$Xv2InsCommit = '373a03a24866ec85b9fa36edfaa1cc91f1cf4a8e'
$Xv2InsCommonRepo = 'https://github.com/HAWGT/xv2ins_common.git'
$Xv2InsCommonCommit = '25a0d0630fa2bb79e1fc6786f1c9534f61cc0e87'
$EternityCommonRepo = 'https://github.com/HAWGT/eternity_common.git'
$EternityCommonCommit = '315ee95ed4e9c4de0ea00e940a38928f5347a2bd'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed: git $($Arguments -join ' ')"
    }
}

function Clone-PinnedSource {
    param(
        [string]$Repository,
        [string]$Directory,
        [string]$Commit
    )

    Invoke-Git clone --quiet --no-tags --filter=blob:none $Repository $Directory
    Push-Location $Directory
    try {
        Invoke-Git checkout --quiet --detach $Commit
        $actual = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actual -ne $Commit) {
            throw "Pinned source verification failed for $Repository. Expected $Commit, got $actual"
        }
    }
    finally {
        Pop-Location
    }
}

function Resolve-VcpkgLibrary {
    param(
        [string]$LibraryDirectory,
        [string[]]$CandidateNames,
        [string]$FallbackPattern
    )

    foreach ($name in $CandidateNames) {
        $candidate = Join-Path $LibraryDirectory $name
        if (Test-Path $candidate) {
            return (Get-Item $candidate).FullName
        }
    }

    $fallback = Get-ChildItem -Path $LibraryDirectory -Filter $FallbackPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    $available = (Get-ChildItem -Path $LibraryDirectory -Filter '*.lib' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    throw "Required vcpkg library was not found. Tried: $($CandidateNames -join ', '). Available .lib files: $available"
}

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

if (Test-Path $WorkRoot) { Remove-Item -Recurse -Force $WorkRoot }
if (Test-Path $OutputRoot) { Remove-Item -Recurse -Force $OutputRoot }
New-Item -ItemType Directory -Force -Path $WorkRoot, $OutputRoot | Out-Null

$eternityDir = Join-Path $WorkRoot 'eternity_common'
$xv2CommonDir = Join-Path $WorkRoot 'xv2ins_common'
$xv2InsDir = Join-Path $WorkRoot 'xv2ins'

Write-Host 'Fetching pinned 1.24-era sources...'
Clone-PinnedSource $EternityCommonRepo $eternityDir $EternityCommonCommit
Clone-PinnedSource $Xv2InsCommonRepo $xv2CommonDir $Xv2InsCommonCommit
Clone-PinnedSource $Xv2InsRepo $xv2InsDir $Xv2InsCommit

$requirementsHeader = Join-Path $xv2CommonDir 'xv2ins_common.h'
$requirements = Get-Content -Raw $requirementsHeader
if ($requirements -notmatch 'PROGRAM_VERSION\s+"4\.5"') {
    throw 'Unexpected xv2ins_common version; expected the pinned 4.5 source line.'
}
if ($requirements -notmatch 'MINIMUM_EXE_VERSION_REQUIRED\s+1\.24f') {
    throw 'Unexpected minimum game version; refusing to build a source tree that is not explicitly 1.24-compatible.'
}
if ($requirements -notmatch 'MINIMUM_PATCHER_REQUIRED\s+4\.5f') {
    throw 'Unexpected patcher requirement; expected xv2patcher 4.5.'
}

$qtRoot = $env:QT_ROOT
if ([string]::IsNullOrWhiteSpace($qtRoot) -or -not (Test-Path (Join-Path $qtRoot 'bin\qmake.exe'))) {
    throw 'QT_ROOT must point to a Qt 6 MSVC installation containing bin\qmake.exe.'
}

$vcpkgRoot = $env:VCPKG_INSTALLATION_ROOT
if ([string]::IsNullOrWhiteSpace($vcpkgRoot)) {
    throw 'VCPKG_INSTALLATION_ROOT is not set.'
}
$vcpkgInstalled = (Join-Path $vcpkgRoot 'installed\x64-windows')
$vcpkgInclude = Join-Path $vcpkgInstalled 'include'
$vcpkgLib = Join-Path $vcpkgInstalled 'lib'
if (-not (Test-Path $vcpkgInclude) -or -not (Test-Path $vcpkgLib)) {
    throw "vcpkg x64-windows dependencies were not found at $vcpkgInstalled"
}

# qmake's -l name translation proved unreliable with the current vcpkg layout on
# GitHub's Windows image. Resolve the exact import-library files and link those
# absolute paths instead. This also fails early with a useful package listing if
# a future vcpkg port renames one of them.
$zipLib = Resolve-VcpkgLibrary $vcpkgLib @('zip.lib') '*zip.lib'
$zlibLib = Resolve-VcpkgLibrary $vcpkgLib @('zlib.lib', 'zlib1.lib', 'z.lib') '*zlib*.lib'
$bz2Lib = Resolve-VcpkgLibrary $vcpkgLib @('bz2.lib', 'bzip2.lib') '*bz*.lib'

Write-Host "Resolved libzip: $zipLib"
Write-Host "Resolved zlib:   $zlibLib"
Write-Host "Resolved bzip2:  $bz2Lib"

Write-Host 'Making the upstream qmake project portable for the GitHub runner...'
$proPath = Join-Path $xv2InsDir 'xv2ins.pro'
$portableInclude = $vcpkgInclude.Replace('\', '/')
$portableZipLib = $zipLib.Replace('\', '/')
$portableZlibLib = $zlibLib.Replace('\', '/')
$portableBz2Lib = $bz2Lib.Replace('\', '/')
$proLines = Get-Content $proPath
$proLines = foreach ($line in $proLines) {
    if ($line -match '^\s*QMAKE_POST_LINK \+= mt ') {
        # The upstream rule expands an empty DESTDIR to /xv2ins.exe when building
        # out-of-tree, which makes mt.exe target the root of the drive. Disable
        # that rule here and embed the same upstream manifest explicitly after
        # the linker has produced the real executable.
        '    QMAKE_POST_LINK ='
    }
    elseif ($line -match '^INCLUDEPATH \+= ".*vcpkg.*include"\s*$') {
        "INCLUDEPATH += `"$portableInclude`""
    }
    elseif ($line -match '^LIBS \+= -L".*vcpkg.*lib"') {
        "LIBS += `"$portableZipLib`" `"$portableZlibLib`" `"$portableBz2Lib`" -lversion -lAdvapi32 -lUser32"
    }
    else {
        $line
    }
}
Set-Content -Path $proPath -Value $proLines -Encoding UTF8

$patchedPro = Get-Content -Raw $proPath
if ($patchedPro -notmatch [regex]::Escape($portableZlibLib)) {
    throw 'Portable qmake rewrite failed: explicit vcpkg library paths were not written to xv2ins.pro.'
}
if ($patchedPro -match 'QMAKE_POST_LINK \+= mt ') {
    throw 'Portable qmake rewrite failed: upstream manifest post-link rule is still active.'
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe was not found.' }
$vsInstall = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if ([string]::IsNullOrWhiteSpace($vsInstall)) { throw 'Visual Studio C++ build tools were not found.' }
$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'

$buildDir = Join-Path $WorkRoot 'build-xv2ins'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$qmake = Join-Path $qtRoot 'bin\qmake.exe'
$cmdFile = Join-Path $env:RUNNER_TEMP 'build-xv2ins-legacy.cmd'
@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64 || exit /b 1
set "PATH=$qtRoot\bin;%PATH%"
cd /d "$buildDir" || exit /b 1
"$qmake" "$proPath" CONFIG+=release CONFIG-=debug || exit /b 1
nmake /NOLOGO || exit /b 1
"@ | Set-Content -Path $cmdFile -Encoding ASCII

Write-Host 'Building XV2INS...'
& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$exe = Get-ChildItem -Path $buildDir -Recurse -Filter 'xv2ins.exe' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $exe) { throw 'Build completed but xv2ins.exe was not found.' }

# Preserve the upstream UTF-8 active-code-page manifest, but attach it to the
# actual out-of-tree executable instead of relying on the broken DESTDIR rule.
$manifestPath = Join-Path $xv2CommonDir 'manifest.xml'
$windowsKitBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$mt = Get-ChildItem -Path $windowsKitBin -Recurse -Filter 'mt.exe' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\mt\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $mt) {
    throw "Windows SDK mt.exe was not found under $windowsKitBin"
}

Write-Host "Embedding upstream manifest with $($mt.FullName)..."
& $mt.FullName -nologo -manifest $manifestPath "-outputresource:$($exe.FullName);#1"
if ($LASTEXITCODE -ne 0) { throw "mt.exe failed with exit code $LASTEXITCODE" }

$packageDir = Join-Path $OutputRoot 'XV2INS-1.24-Legacy'
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
Copy-Item $exe.FullName (Join-Path $packageDir 'xv2ins-1.24-legacy.exe')

$windeployqt = Join-Path $qtRoot 'bin\windeployqt.exe'
& $windeployqt --release --no-translations --compiler-runtime (Join-Path $packageDir 'xv2ins-1.24-legacy.exe')
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed with exit code $LASTEXITCODE" }

$vcpkgBin = Join-Path $vcpkgInstalled 'bin'
if (Test-Path $vcpkgBin) {
    Get-ChildItem $vcpkgBin -Filter '*.dll' -File | ForEach-Object {
        Copy-Item $_.FullName $packageDir -Force
    }
}

@"
XV2INS 1.24 Legacy - experimental build

Target game: Dragon Ball Xenoverse 2 1.24.x (including 1.24.1)
Required xv2patcher: 4.5-compatible build

This is a source-based legacy build. It does NOT modify or bypass XV2INS 4.7.
Keep a backup of your game data before installing/uninstalling mods.

Pinned source revisions:
HAWGT/xv2ins: $Xv2InsCommit
HAWGT/xv2ins_common: $Xv2InsCommonCommit
HAWGT/eternity_common: $EternityCommonCommit
"@ | Set-Content -Path (Join-Path $packageDir 'LEGACY-BUILD.txt') -Encoding UTF8

$hash = Get-FileHash (Join-Path $packageDir 'xv2ins-1.24-legacy.exe') -Algorithm SHA256
"$($hash.Hash)  xv2ins-1.24-legacy.exe" | Set-Content -Path (Join-Path $packageDir 'SHA256SUMS.txt') -Encoding ASCII

Write-Host "Built: $($exe.FullName)"
Write-Host "Packaged: $packageDir"
Write-Host "SHA-256: $($hash.Hash)"
