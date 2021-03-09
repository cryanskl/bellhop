#################################################################################
#
#
# Bellhop Deploy Script
# Created by CSA's: Matthew Garrett, Nills Franssens, and Tyler Peterson 
#
#
##################################################################################

# Set preference variables
$ErrorActionPreference = "Stop"

# Validate the Name parameter
function Test-Name {
    param (
        [ValidateLength(5, 17)]
        [ValidatePattern('^(?!-)(?!.*--)[a-z]')]
        [Parameter(Mandatory = $true)]
        [String]
        $name
    )

    Write-Host "Name is '$name'" -ForegroundColor Green
}

Function Test-Location {
    param (
        [Parameter(Mandatory = $true)]
        [String]
        $location
    )

    Write-Host "INFO: Validating location selected is valid Azure Region..." -ForegroundColor Green

    # Get current Azure Regions
    $azRegions = Get-AzLocation

    $azLocationData = $azRegions | Where-Object { $_.Location -like $location }

    if ($null -ne $azLocationData) {
        $script:locationName = $azLocationData.DisplayName
    }
    else {
        Write-Host "ERROR: Location provided is not a valid Azure Region!" -ForegroundColor red
        exit
    }
}

# Intake and set script parameters
$name = Read-Host "Enter a unique name for your deployment"
$location = Read-Host "Which Azure Region to deploy to?"
$logFile = "./logs/deploy_$(get-date -format `"yyyyMMddhhmmsstt`").log"

Test-Name $name
Test-Location $location

# Create log folder
Write-Host "INFO: Creating log folder..." -ForegroundColor green
New-Item -Name "logs" -ItemType "directory" -ErrorAction Ignore | Out-Null

# Verify PowerShell Core v7 or higher is installed
Write-Host "INFO: Checking for PowerShell v7 or higher..." -ForegroundColor Green

if( [version]::Parse($PSVersionTable.PSVersion) -ge [version]::Parse('7.0.0') ) {
    Write-Host "INFO: PowerShell $($PSVersionTable.PSVersion.ToString()) detected" -ForegroundColor Green
} else {
    Write-Host "ERROR: Script requires PowerShell 7.x or higher!"
    exit
}

# Verify Azure PowerShell Module v5.4.0 or higher is installed
Write-Host "INFO: Checking for Azure PowerShell Module v5.4.0 or higher..." -ForegroundColor Green

$azPsVersion = $(Get-InstalledModule -Name Az -AllVersions | Select-Object Version | Sort-Object Version -Descending)[0].Version

if( [version]::Parse($azPsVersion) -ge [version]::Parse('5.4.0') ) {
    Write-Host "INFO: Azure PowerShell Module v$azPsVersion detected" -ForegroundColor Green
} else {
    Write-Host "ERROR: Script requires PowerShell 7.x or higher!"
    exit
}

# Verify the .NET Core 3.1 SDK is installed
Write-Host "INFO: Checking for .NET Core 3.1 SDK..." -ForegroundColor Green

try {
    $dotNet = Invoke-Expression -Command 'dotnet --list-sdks 2>&1'
}
catch {
    Write-Host "ERROR: Unable to verify presence .NET Core 3.1 SDK"
}

if($null-ne $dotNet) {
    $dotNetList = $dotNet.Split([Environment]::NewLine)
    $dotNetArray = [System.Collections.ArrayList]@()

    foreach ($version in $dotNetList) {
        $v = $version -replace '( \[.*\])',""
        $dotNetArray.Add($v) | Out-Null
    }

    if (($dotNetArray | ForEach-Object { $_ -like '3.1.*' }) -notcontains $true) {
        Write-Host "ERROR: .NET Core 3.1 SDK not installed, cannot build Bellhop engine!"
        exit
    } else {
        Write-Host "INFO: .NET Core 3.1 SDK installed" -ForegroundColor Green
    }
} else {
    Write-Host "ERROR: .NET Core 3.1 SDK not installed, cannot build Bellhop engine!"
    exit
}

# Build Bellhop engine using dotnet publish tools
Write-Host "INFO: Building Bellhop engine..." -ForegroundColor Green
try {
    $dotNetPublish = Invoke-Expression -Command 'dotnet publish --configuration Release .\functions\engine\ 2>&1'
}
catch {
    Write-Host "ERROR: Unable to build Bellhop engine"
    Write-Host $dotNetPublish
    exit
}

# Check if Bellhop engine build results contained an error
if ($dotNetPublish -like '*error*') {
    Write-Host "ERROR: Unable to build Bellhop engine"
    Write-Host $dotNetPublish
    exit
}

# Deploy Bellhop project infrastructure
Write-Host "INFO: Deploying ARM template to create Bellhop infrastructure" -ForegroundColor green
Write-Verbose -Message "Deploying ARM template to create Bellhop infrastructure"

try {
    $autoscaleParams = @{
        appName     = $name
    }

    $res = New-AzDeployment `
        -Location $location `
        -TemplateFile ./templates/infra.json `
        -TemplateParameterObject $autoscaleParams
}
catch {
    $_ | Out-File -FilePath $logFile -Append
    Write-Host "ERROR: Unable to deploy Bellhop infrastructure ARM template due to an exception, see $logFile for detailed information!" -ForegroundColor red
    exit
}

# Upload Azure Function contents via Zip-Deploy
# Bellhop Scaler Function Upload First
Write-Host "INFO: Creating staging folder for function archives..." -ForegroundColor green
Remove-Item .\staging\ -Recurse -Force -ErrorAction Ignore
New-Item -Name "staging" -ItemType "directory" -ErrorAction Ignore | Out-Null

try {
    Write-Host "INFO: Zipping up scaler function contents" -ForegroundColor Green
    Write-Verbose -Message "Zipping up scaler function..."

    $scalerFolder = ".\functions\scaler"
    $scalerZipFile = ".\staging\scaler.zip"
    $scalerExcludeDir = @(".vscode")
    $scalerExcludeFile = @("local.settings.json")
    $scalerDirs = Get-ChildItem $scalerFolder -Directory | Where-Object { $_.Name -notin $scalerExcludeDir }
    $scalerFiles = Get-ChildItem $scalerFolder -File | Where-Object { $_.Name -notin $scalerExcludeFile }
    $scalerDirs | Compress-Archive -DestinationPath $scalerZipFile -Update
    $scalerFiles | Compress-Archive -DestinationPath $scalerZipFile -Update

    Write-Host "INFO: Deploying scaler function via Zip-Deploy" -ForegroundColor Green
    Write-Verbose -Message "Deploying scaler function via Azure CLI Zip-Deploy"
    Publish-AzWebapp -ResourceGroupName "$name-rg" -Name "$name-function-scaler" -ArchivePath $(Resolve-Path $scalerZipFile) -Force | Out-Null
}
catch {
    $_ | Out-File -FilePath $logFile -Append
    Write-Host "ERROR: Bellhop scaler function Zip Deploy failed due to an exception, please check $logfile for details."
    exit
}

# Bellhop Engine Function Upload
try {
    # Build for .NET App: dotnet publish --configuration Release
    Write-Host "INFO: Zipping up engine function contents" -ForegroundColor Green
    Write-Verbose -Message "Zipping up engine function..."

    $engineFolder = ".\functions\engine\bin\Release\netcoreapp3.1\publish"
    $engineZipFile = ".\staging\engine.zip"
    $engineExcludeDir = @()
    $engineExcludeFile = @()
    $engineDirs = Get-ChildItem $engineFolder -Directory | Where-Object { $_.Name -notin $engineExcludeDir }
    $engineFiles = Get-ChildItem $engineFolder -File | Where-Object { $_.Name -notin $engineExcludeFile }
    $engineDirs | Compress-Archive -DestinationPath $engineZipFile -Update
    $engineFiles | Compress-Archive -DestinationPath $engineZipFile -Update

    Write-Host "INFO: Deploying engine function via Zip-Deploy" -ForegroundColor Green
    Write-Verbose -Message "Deploying engine function via Azure CLI Zip-Deploy"
    Publish-AzWebapp -ResourceGroupName "$name-rg" -Name "$name-function-engine" -ArchivePath $(Resolve-Path $engineZipFile) -Force | Out-Null
}
catch {
    $_ | Out-File -FilePath $logFile -Append
    Write-Host "ERROR: Bellhop engine function Zip Deploy failed due to an exception, please check $logfile for details."
    exit
}

Write-Host "INFO: Cleaning up..." -ForegroundColor green
Remove-Item .\staging\ -Recurse -Force -ErrorAction Ignore

Write-Host "INFO: Bellhop has deployed successfully!" -ForegroundColor Green
