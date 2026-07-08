$ErrorActionPreference = "Stop"

$APP_NAME_TITLE = "Calf"
$DIST_DIR = "dist"

function Get-ProjectVersion {
    $match = Select-String -Path "backend/version/version.go" -Pattern 'const Version = "(.*)"'
    if ($null -eq $match) {
        throw "could not extract version from backend/version/version.go"
    }
    $version = $match.Matches.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not extract version from backend/version/version.go"
    }
    return $version
}

function Get-FlutterVersion {
    $match = Select-String -Path "ui/pubspec.yaml" -Pattern '^version: ([0-9.]+)'
    if ($null -eq $match) {
        throw "could not extract version from ui/pubspec.yaml"
    }
    $version = $match.Matches.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not extract version from ui/pubspec.yaml"
    }
    return $version
}

function Assert-VersionMatch {
    $goVersion = Get-ProjectVersion
    $flutterVersion = Get-FlutterVersion
    if ($goVersion -ne $flutterVersion) {
        throw "version mismatch: backend/version/version.go=$goVersion, ui/pubspec.yaml=$flutterVersion"
    }
    return $goVersion
}

function Write-InnoSetupScript {
    param(
        [string]$Version,
        [string]$Source,
        [string]$Dist,
        [string]$Output
    )
    return @"
[Setup]
AppName=$APP_NAME_TITLE
AppVersion=$Version
DefaultDirName={autopf}\$APP_NAME_TITLE
OutputDir=$Dist
OutputBaseFilename=$Output
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin

[Files]
Source: "$Source\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\$APP_NAME_TITLE"; Filename: "{app}\ui.exe"; WorkingDir: "{app}"
Name: "{commondesktop}\$APP_NAME_TITLE"; Filename: "{app}\ui.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\ui.exe"; Description: "Launch $APP_NAME_TITLE"; Flags: nowait postinstall skipifsilent
"@
}

function Get-ISCCPath {
    if (Get-Command iscc -ErrorAction SilentlyContinue) {
        return "iscc"
    }
    $defaultPath = "${env:ProgramFiles(x86)}\Inno Setup 6\iscc.exe"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }
    throw "Inno Setup compiler (iscc) not found"
}

$VERSION = Assert-VersionMatch
$SOURCE = "ui/build/windows/x64/runner/Release"
$OUTPUT = "$APP_NAME_TITLE-$VERSION"

if (!(Test-Path $SOURCE)) {
    throw "Windows release bundle not found at $SOURCE. Run 'make release-windows' first."
}

New-Item -ItemType Directory -Force -Path $DIST_DIR | Out-Null

$sourceAbsolute = (Resolve-Path $SOURCE).Path
$distAbsolute = (Resolve-Path $DIST_DIR).Path
$issPath = "$distAbsolute\Calf.iss"

Write-InnoSetupScript -Version $VERSION -Source $sourceAbsolute -Dist $distAbsolute -Output $OUTPUT | Out-File -FilePath $issPath -Encoding UTF8

$isccPath = Get-ISCCPath
& $isccPath "$issPath"

$expectedExe = "$distAbsolute\$OUTPUT.exe"
if (!(Test-Path $expectedExe)) {
    throw "expected installer not found at $expectedExe"
}
Write-Host "created $expectedExe"
