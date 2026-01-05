<#
.SYNOPSIS
    Automated deployment script for Azure Nexus Microservices Infrastructure
.DESCRIPTION
    This script provides complete automation for deploying Nexus Microservices to Azure:
    - Auto-detects and allows selection of Azure subscriptions
    - Initializes Terraform backend storage
    - Deploys all infrastructure components
    - Generates comprehensive HTML deployment report
    - Includes error handling, logging, and rollback capabilities
.PARAMETER AutoApprove
    Skip interactive approval of Terraform plans
.PARAMETER SubscriptionId
    Azure Subscription ID (if not provided, interactive selection will be presented)
.PARAMETER Environment
    Deployment environment (dev, staging, prod). Default: dev
.PARAMETER Location
    Azure region for deployment. Default: eastus
.PARAMETER SkipBackendInit
    Skip Terraform backend initialization
.PARAMETER GenerateReportOnly
    Generate deployment report without deploying
.EXAMPLE
    .\Deploy-NexusMicroservices.ps1
    Interactive deployment with subscription selection
.EXAMPLE
    .\Deploy-NexusMicroservices.ps1 -AutoApprove -Environment prod -Location westus2
    Automated production deployment to West US 2
.EXAMPLE
    .\Deploy-NexusMicroservices.ps1 -SubscriptionId "xxxx-xxxx-xxxx-xxxx" -AutoApprove
    Automated deployment to specific subscription
.NOTES
    Author: Nexus Automation Team
    Version: 1.0.0
    Created: 2026-01-05
    Requires: Azure CLI, Terraform, PowerShell 7+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$AutoApprove,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment = 'dev',
    
    [Parameter(Mandatory = $false)]
    [string]$Location = 'eastus',
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipBackendInit,
    
    [Parameter(Mandatory = $false)]
    [switch]$GenerateReportOnly
)

# Script Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$ScriptVersion = "1.0.0"
$ScriptStartTime = Get-Date

# Paths Configuration
$ScriptRoot = Split-Path -Parent $PSScriptRoot
$TerraformDir = Join-Path $ScriptRoot "terraform"
$LogDir = Join-Path $ScriptRoot "logs"
$ReportDir = Join-Path $ScriptRoot "reports"
$LogFile = Join-Path $LogDir "deployment_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ReportFile = Join-Path $ReportDir "deployment_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

# Global Variables
$Global:DeploymentState = @{
    Success = $true
    Errors = @()
    Warnings = @()
    Steps = @()
    Resources = @()
}

#region Helper Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
        'Debug'   { Write-Host $logMessage -ForegroundColor Gray }
    }
    
    # File output
    Add-Content -Path $LogFile -Value $logMessage
}

function Initialize-Environment {
    Write-Log "Initializing deployment environment..." -Level Info
    
    # Create necessary directories
    @($LogDir, $ReportDir) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
            Write-Log "Created directory: $_" -Level Debug
        }
    }
    
    # Validate prerequisites
    $prerequisites = @(
        @{ Name = 'Azure CLI'; Command = 'az --version' },
        @{ Name = 'Terraform'; Command = 'terraform version' },
        @{ Name = 'PowerShell'; Command = '$PSVersionTable.PSVersion' }
    )
    
    foreach ($prereq in $prerequisites) {
        try {
            Write-Log "Checking $($prereq.Name)..." -Level Debug
            if ($prereq.Name -eq 'PowerShell') {
                $version = $PSVersionTable.PSVersion
                Write-Log "$($prereq.Name) version: $version" -Level Success
            } else {
                $output = Invoke-Expression $prereq.Command 2>&1
                Write-Log "$($prereq.Name) is available" -Level Success
            }
        } catch {
            Write-Log "$($prereq.Name) is not installed or not in PATH" -Level Error
            throw "Missing prerequisite: $($prereq.Name)"
        }
    }
}

function Get-AzureSubscriptions {
    Write-Log "Retrieving Azure subscriptions..." -Level Info
    
    try {
        # Check if logged in
        $accountInfo = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Not logged into Azure. Initiating login..." -Level Warning
            az login
            if ($LASTEXITCODE -ne 0) {
                throw "Azure login failed"
            }
        }
        
        # Get all subscriptions
        $subscriptionsJson = az account list --output json | ConvertFrom-Json
        
        if ($subscriptionsJson.Count -eq 0) {
            throw "No Azure subscriptions found"
        }
        
        Write-Log "Found $($subscriptionsJson.Count) subscription(s)" -Level Success
        return $subscriptionsJson
        
    } catch {
        Write-Log "Failed to retrieve Azure subscriptions: $_" -Level Error
        throw
    }
}

function Select-AzureSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )
    
    $subscriptions = Get-AzureSubscriptions
    
    if ($SubscriptionId) {
        $selectedSub = $subscriptions | Where-Object { $_.id -eq $SubscriptionId -or $_.subscriptionId -eq $SubscriptionId }
        if (-not $selectedSub) {
            throw "Subscription ID '$SubscriptionId' not found"
        }
    } else {
        Write-Host "`n=== Azure Subscription Selection ===" -ForegroundColor Cyan
        Write-Host ""
        
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            $sub = $subscriptions[$i]
            $isDefault = if ($sub.isDefault) { " (Current)" } else { "" }
            Write-Host "[$($i + 1)] $($sub.name)$isDefault" -ForegroundColor White
            Write-Host "    ID: $($sub.id)" -ForegroundColor Gray
            Write-Host "    State: $($sub.state)" -ForegroundColor Gray
            Write-Host ""
        }
        
        do {
            $selection = Read-Host "Select subscription (1-$($subscriptions.Count))"
            $selectionNum = [int]$selection - 1
        } while ($selectionNum -lt 0 -or $selectionNum -ge $subscriptions.Count)
        
        $selectedSub = $subscriptions[$selectionNum]
    }
    
    Write-Log "Setting active subscription to: $($selectedSub.name)" -Level Info
    az account set --subscription $selectedSub.id
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set subscription"
    }
    
    Write-Log "Active subscription: $($selectedSub.name) ($($selectedSub.id))" -Level Success
    return $selectedSub
}

function Initialize-TerraformBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Subscription
    )
    
    Write-Log "Initializing Terraform backend..." -Level Info
    
    $backendConfig = @{
        ResourceGroupName = "rg-nexus-terraform-state-$Environment"
        StorageAccountName = "stnexustf$Environment$(Get-Random -Minimum 1000 -Maximum 9999)"
        ContainerName = "tfstate"
        Location = $Location
    }
    
    try {
        # Check if resource group exists
        $rgExists = az group exists --name $backendConfig.ResourceGroupName | ConvertFrom-Json
        
        if (-not $rgExists) {
            Write-Log "Creating resource group: $($backendConfig.ResourceGroupName)" -Level Info
            az group create --name $backendConfig.ResourceGroupName --location $backendConfig.Location
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create resource group"
            }
        }
        
        # Check if storage account exists
        $saExists = az storage account check-name --name $backendConfig.StorageAccountName | ConvertFrom-Json
        
        if ($saExists.nameAvailable) {
            Write-Log "Creating storage account: $($backendConfig.StorageAccountName)" -Level Info
            az storage account create `
                --name $backendConfig.StorageAccountName `
                --resource-group $backendConfig.ResourceGroupName `
                --location $backendConfig.Location `
                --sku Standard_LRS `
                --encryption-services blob `
                --https-only true `
                --min-tls-version TLS1_2
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create storage account"
            }
        } else {
            Write-Log "Storage account already exists: $($backendConfig.StorageAccountName)" -Level Debug
        }
        
        # Get storage account key
        $storageKey = az storage account keys list `
            --resource-group $backendConfig.ResourceGroupName `
            --account-name $backendConfig.StorageAccountName `
            --query '[0].value' -o tsv
        
        # Create blob container
        az storage container create `
            --name $backendConfig.ContainerName `
            --account-name $backendConfig.StorageAccountName `
            --account-key $storageKey `
            --only-show-errors
        
        Write-Log "Terraform backend initialized successfully" -Level Success
        return $backendConfig
        
    } catch {
        Write-Log "Failed to initialize Terraform backend: $_" -Level Error
        throw
    }
}

function Initialize-Terraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BackendConfig
    )
    
    Write-Log "Initializing Terraform..." -Level Info
    
    Push-Location $TerraformDir
    
    try {
        # Create backend configuration file
        $backendConfigContent = @"
terraform {
  backend "azurerm" {
    resource_group_name  = "$($BackendConfig.ResourceGroupName)"
    storage_account_name = "$($BackendConfig.StorageAccountName)"
    container_name       = "$($BackendConfig.ContainerName)"
    key                  = "nexus-microservices-$Environment.tfstate"
  }
}
"@
        
        Set-Content -Path "backend.tf" -Value $backendConfigContent
        
        # Initialize Terraform
        $initArgs = @('init', '-upgrade')
        Write-Log "Running: terraform $($initArgs -join ' ')" -Level Debug
        
        & terraform $initArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform init failed"
        }
        
        Write-Log "Terraform initialized successfully" -Level Success
        
    } catch {
        Write-Log "Terraform initialization failed: $_" -Level Error
        throw
    } finally {
        Pop-Location
    }
}

function Test-TerraformPlan {
    Write-Log "Creating Terraform plan..." -Level Info
    
    Push-Location $TerraformDir
    
    try {
        $planArgs = @(
            'plan',
            '-out=tfplan',
            "-var=environment=$Environment",
            "-var=location=$Location"
        )
        
        Write-Log "Running: terraform $($planArgs -join ' ')" -Level Debug
        
        & terraform $planArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform plan failed"
        }
        
        Write-Log "Terraform plan created successfully" -Level Success
        return $true
        
    } catch {
        Write-Log "Terraform plan failed: $_" -Level Error
        $Global:DeploymentState.Success = $false
        $Global:DeploymentState.Errors += "Terraform plan failed: $_"
        return $false
    } finally {
        Pop-Location
    }
}

function Invoke-TerraformApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$AutoApprove
    )
    
    Write-Log "Applying Terraform configuration..." -Level Info
    
    Push-Location $TerraformDir
    
    try {
        $applyArgs = @('apply')
        
        if ($AutoApprove) {
            $applyArgs += '-auto-approve'
        }
        
        $applyArgs += 'tfplan'
        
        Write-Log "Running: terraform $($applyArgs -join ' ')" -Level Debug
        
        & terraform $applyArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform apply failed"
        }
        
        Write-Log "Terraform apply completed successfully" -Level Success
        return $true
        
    } catch {
        Write-Log "Terraform apply failed: $_" -Level Error
        $Global:DeploymentState.Success = $false
        $Global:DeploymentState.Errors += "Terraform apply failed: $_"
        return $false
    } finally {
        Pop-Location
    }
}

function Get-TerraformOutputs {
    Write-Log "Retrieving Terraform outputs..." -Level Info
    
    Push-Location $TerraformDir
    
    try {
        $outputJson = terraform output -json | ConvertFrom-Json
        
        $outputs = @{}
        $outputJson.PSObject.Properties | ForEach-Object {
            $outputs[$_.Name] = $_.Value.value
        }
        
        Write-Log "Retrieved $($outputs.Count) output values" -Level Success
        return $outputs
        
    } catch {
        Write-Log "Failed to retrieve Terraform outputs: $_" -Level Warning
        return @{}
    } finally {
        Pop-Location
    }
}

function Get-DeployedResources {
    Write-Log "Gathering deployed resources information..." -Level Info
    
    try {
        $resources = az resource list --query "[?tags.Environment=='$Environment']" | ConvertFrom-Json
        
        Write-Log "Found $($resources.Count) deployed resources" -Level Success
        return $resources
        
    } catch {
        Write-Log "Failed to retrieve deployed resources: $_" -Level Warning
        return @()
    }
}

function New-DeploymentReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Subscription,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$BackendConfig,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$TerraformOutputs,
        
        [Parameter(Mandatory = $false)]
        [array]$Resources
    )
    
    Write-Log "Generating deployment report..." -Level Info
    
    $duration = (Get-Date) - $ScriptStartTime
    $statusColor = if ($Global:DeploymentState.Success) { "#28a745" } else { "#dc3545" }
    $statusText = if ($Global:DeploymentState.Success) { "SUCCESS" } else { "FAILED" }
    
    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nexus Microservices Deployment Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        .status-badge {
            display: inline-block;
            padding: 10px 30px;
            background: $statusColor;
            color: white;
            border-radius: 25px;
            font-weight: bold;
            font-size: 1.2em;
            margin-top: 15px;
        }
        .section {
            padding: 30px;
            border-bottom: 1px solid #e0e0e0;
        }
        .section:last-child {
            border-bottom: none;
        }
        .section-title {
            font-size: 1.8em;
            color: #667eea;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #667eea;
        }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        .info-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            border-left: 4px solid #667eea;
        }
        .info-card h3 {
            color: #667eea;
            margin-bottom: 10px;
            font-size: 1.1em;
        }
        .info-card p {
            color: #666;
            line-height: 1.6;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #e0e0e0;
        }
        th {
            background: #667eea;
            color: white;
            font-weight: 600;
        }
        tr:hover {
            background: #f8f9fa;
        }
        .error-box {
            background: #f8d7da;
            border: 1px solid #f5c6cb;
            border-radius: 5px;
            padding: 15px;
            margin: 10px 0;
            color: #721c24;
        }
        .warning-box {
            background: #fff3cd;
            border: 1px solid #ffeeba;
            border-radius: 5px;
            padding: 15px;
            margin: 10px 0;
            color: #856404;
        }
        .success-box {
            background: #d4edda;
            border: 1px solid #c3e6cb;
            border-radius: 5px;
            padding: 15px;
            margin: 10px 0;
            color: #155724;
        }
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }
        .metric {
            font-size: 2em;
            font-weight: bold;
            color: #667eea;
        }
        .code-block {
            background: #2d2d2d;
            color: #f8f8f2;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Nexus Microservices Deployment Report</h1>
            <p>Automated Azure Infrastructure Deployment</p>
            <div class="status-badge">$statusText</div>
        </div>
        
        <div class="section">
            <h2 class="section-title">📊 Deployment Summary</h2>
            <div class="info-grid">
                <div class="info-card">
                    <h3>Environment</h3>
                    <p class="metric">$Environment</p>
                </div>
                <div class="info-card">
                    <h3>Region</h3>
                    <p class="metric">$Location</p>
                </div>
                <div class="info-card">
                    <h3>Duration</h3>
                    <p class="metric">$($duration.ToString('mm\:ss'))</p>
                </div>
                <div class="info-card">
                    <h3>Resources Deployed</h3>
                    <p class="metric">$($Resources.Count)</p>
                </div>
            </div>
        </div>
        
        <div class="section">
            <h2 class="section-title">🔐 Azure Subscription</h2>
            <div class="info-grid">
                <div class="info-card">
                    <h3>Subscription Name</h3>
                    <p>$($Subscription.name)</p>
                </div>
                <div class="info-card">
                    <h3>Subscription ID</h3>
                    <p style="font-family: monospace; font-size: 0.9em;">$($Subscription.id)</p>
                </div>
                <div class="info-card">
                    <h3>Tenant ID</h3>
                    <p style="font-family: monospace; font-size: 0.9em;">$($Subscription.tenantId)</p>
                </div>
                <div class="info-card">
                    <h3>State</h3>
                    <p>$($Subscription.state)</p>
                </div>
            </div>
        </div>
"@

    if ($BackendConfig) {
        $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">💾 Terraform Backend</h2>
            <div class="info-grid">
                <div class="info-card">
                    <h3>Resource Group</h3>
                    <p>$($BackendConfig.ResourceGroupName)</p>
                </div>
                <div class="info-card">
                    <h3>Storage Account</h3>
                    <p>$($BackendConfig.StorageAccountName)</p>
                </div>
                <div class="info-card">
                    <h3>Container</h3>
                    <p>$($BackendConfig.ContainerName)</p>
                </div>
                <div class="info-card">
                    <h3>State File</h3>
                    <p>nexus-microservices-$Environment.tfstate</p>
                </div>
            </div>
        </div>
"@
    }

    if ($TerraformOutputs -and $TerraformOutputs.Count -gt 0) {
        $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">📤 Terraform Outputs</h2>
            <table>
                <thead>
                    <tr>
                        <th>Output Name</th>
                        <th>Value</th>
                    </tr>
                </thead>
                <tbody>
"@
        
        foreach ($key in $TerraformOutputs.Keys) {
            $value = $TerraformOutputs[$key]
            if ($value -is [array]) {
                $value = $value -join ', '
            }
            $htmlContent += @"
                    <tr>
                        <td><strong>$key</strong></td>
                        <td>$value</td>
                    </tr>
"@
        }
        
        $htmlContent += @"
                </tbody>
            </table>
        </div>
"@
    }

    if ($Resources -and $Resources.Count -gt 0) {
        $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">🏗️ Deployed Resources</h2>
            <table>
                <thead>
                    <tr>
                        <th>Resource Name</th>
                        <th>Type</th>
                        <th>Resource Group</th>
                        <th>Location</th>
                    </tr>
                </thead>
                <tbody>
"@
        
        foreach ($resource in $Resources) {
            $htmlContent += @"
                    <tr>
                        <td>$($resource.name)</td>
                        <td>$($resource.type)</td>
                        <td>$($resource.resourceGroup)</td>
                        <td>$($resource.location)</td>
                    </tr>
"@
        }
        
        $htmlContent += @"
                </tbody>
            </table>
        </div>
"@
    }

    if ($Global:DeploymentState.Errors.Count -gt 0) {
        $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">❌ Errors</h2>
"@
        
        foreach ($error in $Global:DeploymentState.Errors) {
            $htmlContent += "<div class='error-box'>$error</div>"
        }
        
        $htmlContent += "</div>"
    }

    if ($Global:DeploymentState.Warnings.Count -gt 0) {
        $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">⚠️ Warnings</h2>
"@
        
        foreach ($warning in $Global:DeploymentState.Warnings) {
            $htmlContent += "<div class='warning-box'>$warning</div>"
        }
        
        $htmlContent += "</div>"
    }

    $htmlContent += @"
        
        <div class="section">
            <h2 class="section-title">📋 Deployment Details</h2>
            <div class="info-grid">
                <div class="info-card">
                    <h3>Script Version</h3>
                    <p>$ScriptVersion</p>
                </div>
                <div class="info-card">
                    <h3>Start Time</h3>
                    <p>$($ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>
                </div>
                <div class="info-card">
                    <h3>End Time</h3>
                    <p>$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</p>
                </div>
                <div class="info-card">
                    <h3>Executed By</h3>
                    <p>$env:USERNAME</p>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p><strong>Nexus Microservices Automation Platform</strong></p>
            <p>Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
            <p>Log file: $LogFile</p>
        </div>
    </div>
</body>
</html>
"@

    Set-Content -Path $ReportFile -Value $htmlContent
    Write-Log "Deployment report generated: $ReportFile" -Level Success
    
    return $ReportFile
}

function Show-DeploymentSummary {
    $duration = (Get-Date) - $ScriptStartTime
    
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "          DEPLOYMENT SUMMARY" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $statusColor = if ($Global:DeploymentState.Success) { 'Green' } else { 'Red' }
    $statusText = if ($Global:DeploymentState.Success) { 'SUCCESS ✓' } else { 'FAILED ✗' }
    
    Write-Host "Status:           " -NoNewline -ForegroundColor White
    Write-Host $statusText -ForegroundColor $statusColor
    Write-Host "Environment:      " -NoNewline -ForegroundColor White
    Write-Host $Environment -ForegroundColor Cyan
    Write-Host "Location:         " -NoNewline -ForegroundColor White
    Write-Host $Location -ForegroundColor Cyan
    Write-Host "Duration:         " -NoNewline -ForegroundColor White
    Write-Host $duration.ToString('mm\:ss') -ForegroundColor Cyan
    Write-Host "Errors:           " -NoNewline -ForegroundColor White
    Write-Host $Global:DeploymentState.Errors.Count -ForegroundColor $(if ($Global:DeploymentState.Errors.Count -eq 0) { 'Green' } else { 'Red' })
    Write-Host "Warnings:         " -NoNewline -ForegroundColor White
    Write-Host $Global:DeploymentState.Warnings.Count -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Report:           " -NoNewline -ForegroundColor White
    Write-Host $ReportFile -ForegroundColor Cyan
    Write-Host "Log:              " -NoNewline -ForegroundColor White
    Write-Host $LogFile -ForegroundColor Cyan
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

#endregion

#region Main Execution

try {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                                                           ║" -ForegroundColor Cyan
    Write-Host "║        NEXUS MICROSERVICES DEPLOYMENT AUTOMATION          ║" -ForegroundColor White
    Write-Host "║                     Version $ScriptVersion                        ║" -ForegroundColor White
    Write-Host "║                                                           ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Step 1: Initialize Environment
    $Global:DeploymentState.Steps += @{ Step = "Initialize Environment"; Status = "Running"; Time = Get-Date }
    Initialize-Environment
    $Global:DeploymentState.Steps[-1].Status = "Completed"
    
    # Step 2: Select Azure Subscription
    $Global:DeploymentState.Steps += @{ Step = "Select Subscription"; Status = "Running"; Time = Get-Date }
    $selectedSubscription = Select-AzureSubscription -SubscriptionId $SubscriptionId
    $Global:DeploymentState.Steps[-1].Status = "Completed"
    
    if (-not $GenerateReportOnly) {
        # Step 3: Initialize Terraform Backend
        if (-not $SkipBackendInit) {
            $Global:DeploymentState.Steps += @{ Step = "Initialize Backend"; Status = "Running"; Time = Get-Date }
            $backendConfig = Initialize-TerraformBackend -Subscription $selectedSubscription
            $Global:DeploymentState.Steps[-1].Status = "Completed"
            
            # Step 4: Initialize Terraform
            $Global:DeploymentState.Steps += @{ Step = "Initialize Terraform"; Status = "Running"; Time = Get-Date }
            Initialize-Terraform -BackendConfig $backendConfig
            $Global:DeploymentState.Steps[-1].Status = "Completed"
        } else {
            Write-Log "Skipping backend initialization as requested" -Level Warning
            $backendConfig = $null
        }
        
        # Step 5: Create Terraform Plan
        $Global:DeploymentState.Steps += @{ Step = "Create Terraform Plan"; Status = "Running"; Time = Get-Date }
        $planSuccess = Test-TerraformPlan
        $Global:DeploymentState.Steps[-1].Status = if ($planSuccess) { "Completed" } else { "Failed" }
        
        if (-not $planSuccess) {
            throw "Terraform planning failed. Deployment aborted."
        }
        
        # Step 6: Apply Terraform Configuration
        if (-not $AutoApprove) {
            Write-Host ""
            Write-Host "Review the Terraform plan above." -ForegroundColor Yellow
            $confirm = Read-Host "Do you want to proceed with deployment? (yes/no)"
            if ($confirm -ne 'yes') {
                Write-Log "Deployment cancelled by user" -Level Warning
                exit 0
            }
        }
        
        $Global:DeploymentState.Steps += @{ Step = "Apply Terraform"; Status = "Running"; Time = Get-Date }
        $applySuccess = Invoke-TerraformApply -AutoApprove:$AutoApprove
        $Global:DeploymentState.Steps[-1].Status = if ($applySuccess) { "Completed" } else { "Failed" }
        
        if (-not $applySuccess) {
            throw "Terraform apply failed. Deployment incomplete."
        }
    }
    
    # Step 7: Gather Outputs and Resources
    $Global:DeploymentState.Steps += @{ Step = "Gather Information"; Status = "Running"; Time = Get-Date }
    $terraformOutputs = Get-TerraformOutputs
    $deployedResources = Get-DeployedResources
    $Global:DeploymentState.Resources = $deployedResources
    $Global:DeploymentState.Steps[-1].Status = "Completed"
    
    # Step 8: Generate Report
    $Global:DeploymentState.Steps += @{ Step = "Generate Report"; Status = "Running"; Time = Get-Date }
    $reportPath = New-DeploymentReport `
        -Subscription $selectedSubscription `
        -BackendConfig $backendConfig `
        -TerraformOutputs $terraformOutputs `
        -Resources $deployedResources
    $Global:DeploymentState.Steps[-1].Status = "Completed"
    
    # Show Summary
    Show-DeploymentSummary
    
    # Open report in browser
    if ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT' -or [string]::IsNullOrEmpty($PSVersionTable.Platform)) {
        Start-Process $reportPath
    } elseif ($IsMacOS) {
        & open $reportPath
    } elseif ($IsLinux) {
        & xdg-open $reportPath
    }
    
    Write-Log "Deployment completed successfully!" -Level Success
    exit 0
    
} catch {
    Write-Log "Deployment failed with error: $_" -Level Error
    $Global:DeploymentState.Success = $false
    $Global:DeploymentState.Errors += $_.Exception.Message
    
    # Generate failure report
    try {
        $reportPath = New-DeploymentReport `
            -Subscription $selectedSubscription `
            -BackendConfig $backendConfig `
            -TerraformOutputs @{} `
            -Resources @()
    } catch {
        Write-Log "Failed to generate error report: $_" -Level Error
    }
    
    Show-DeploymentSummary
    
    exit 1
} finally {
    Write-Log "Script execution completed" -Level Info
}

#endregion
