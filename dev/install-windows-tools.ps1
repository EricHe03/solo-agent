[CmdletBinding()]
param(
    [string]$Destination = 'D:\Tools',
    [string]$GitHubCLIVersion = '2.103.3',
    [string]$NodeVersion = '26.13.0',
    [string]$BunVersion = '1.4.4',
    [string]$GoVersion = '1.27.3'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$archives = Join-Path $Destination '_downloads'
New-Item -ItemType Directory -Force -Path $archives | Out-Null

function Install-ZipTool {
    param(
        [string]$Name,
        [string]$Uri,
        [string]$ArchiveName,
        [string]$ExtractedDirectory
    )
    $target = Join-Path $Destination $Name
    if (Test-Path $target) {
        Write-Host "$Name is already installed at $target"
        return
    }
    $archive = Join-Path $archives $ArchiveName
    if ((Test-Path $archive) -and (Get-Item $archive).Length -eq 0) {
        Remove-Item -Force $archive
    }
    if (-not (Test-Path $archive)) {
        Invoke-WebRequest -Uri $Uri -OutFile $archive
    }
    $staging = Join-Path $Destination "_$Name-staging"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $staging
    Expand-Archive -Path $archive -DestinationPath $staging -Force
    $source = if ($ExtractedDirectory) { Join-Path $staging $ExtractedDirectory } else { $staging }
    Move-Item $source $target
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $staging
    Write-Host "Installed $Name at $target"
}

Install-ZipTool -Name 'GitHubCLI' -Uri "https://github.com/cli/cli/releases/download/v$GitHubCLIVersion/gh_${GitHubCLIVersion}_windows_amd64.zip" -ArchiveName "gh-$GitHubCLIVersion.zip" -ExtractedDirectory ''
Install-ZipTool -Name 'Node' -Uri "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip" -ArchiveName "node-$NodeVersion.zip" -ExtractedDirectory "node-v$NodeVersion-win-x64"
Install-ZipTool -Name 'Bun' -Uri "https://github.com/oven-sh/bun/releases/download/bun-v$BunVersion/bun-windows-x64.zip" -ArchiveName "bun-$BunVersion.zip" -ExtractedDirectory 'bun-windows-x64'
Install-ZipTool -Name 'Go' -Uri "https://go.dev/dl/go$GoVersion.windows-amd64.zip" -ArchiveName "go-$GoVersion.zip" -ExtractedDirectory 'go'

$toolPaths = @(
    (Join-Path $Destination 'GitHubCLI\bin'),
    (Join-Path $Destination 'Node'),
    (Join-Path $Destination 'Bun'),
    (Join-Path $Destination 'Go\bin')
)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @($userPath -split ';' | Where-Object { $_ })
foreach ($toolPath in $toolPaths) {
    if ($parts -notcontains $toolPath) { $parts += $toolPath }
}
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
$env:Path = (($toolPaths + ($env:Path -split ';')) -join ';')

Write-Host 'Installed tool versions:'
gh --version
node --version
bun --version
go version
