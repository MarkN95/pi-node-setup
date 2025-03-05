# Pi Node Setup Automation Script (Improved Version)
# This script will:
#  - Check for Administrator privileges and re-launch as admin if needed.
#  - Verify that hardware virtualization is supported and enabled.
#  - Enable required Windows features (WSL, VirtualMachinePlatform, Hyper-V if available).
#  - Prompt for reboot if those features were just enabled (required for WSL2).
#  - Install Ubuntu WSL distribution and configure it (set WSL2 as default, update packages).
#  - Configure Windows Firewall to allow Pi Node ports (31400-31409 TCP).
#  - Download the Pi Node installer with retries, and run it silently.
#  - Create a scheduled task to auto-start Pi Node on user logon and restart it on failure.
#  - Create a scheduled task to monitor system (CPU, RAM, external IP) and log it, with optional email alerts.
#  - Provide clear output and logging, and pause at the end for user to read messages.

# --------------------------- Begin Script ----------------------------

# Ensure the script is running as Administrator
Try {
    $isAdmin = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent()).
                IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} Catch {
    $isAdmin = $false
}
if (-not $isAdmin) {
    Write-Host "Elevating script to run as Administrator..."
    # Re-launch the script with admin privileges
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runAs"
    Try {
        $proc = [Diagnostics.Process]::Start($psi)
        Write-Host "Please accept the UAC prompt. The script will continue in an elevated window."
    } Catch {
        Write-Error "Failed to launch script as Administrator. $_"
    }
    exit  # Exit the current non-elevated instance
}

# Start transcript logging to a file for debugging/troubleshooting
$logPath = Join-Path $env:USERPROFILE "PiNodeSetup.log"
Try {
    Start-Transcript -Path $logPath -Append -ErrorAction Stop
} Catch {
    Write-Warning "Could not start transcript logging: $_"
}

Write-Host "`n=== Pi Node Setup Script Started (Logging to $logPath) ===`n"

# Step 1: Verify hardware virtualization support and status
Write-Host "Checking CPU virtualization support..."
$virtSupported = $false
$virtEnabled = $false
$hypervisorPresent = $false
Try {
    $cpu = Get-CimInstance -Class Win32_Processor
    $virtSupported = ($cpu | Select-Object -ExpandProperty VMMonitorModeExtensions)[0]
    $virtEnabled   = ($cpu | Select-Object -ExpandProperty VirtualizationFirmwareEnabled)[0]
    $hypervisorPresent = (Get-CimInstance -Class Win32_ComputerSystem).HypervisorPresent
} Catch {
    Write-Warning "Unable to query virtualization status via CIM, trying WMI..."
    Try {
        $cpu = Get-WmiObject -Class Win32_Processor
        $virtSupported = ($cpu | Select-Object -ExpandProperty VMMonitorModeExtensions)[0]
        $virtEnabled   = ($cpu | Select-Object -ExpandProperty VirtualizationFirmwareEnabled)[0]
        $hypervisorPresent = (Get-WmiObject -Class Win32_ComputerSystem).HypervisorPresent
    } Catch {
        Write-Warning "Unable to determine virtualization status. $_"
    }
}

if (($virtSupported -and $virtEnabled) -or $hypervisorPresent) {
    Write-Host "Virtualization is supported and ENABLED on this system."
} else {
    Write-Error "Hardware virtualization is not enabled or not supported on this machine."
    Write-Host "Please ensure that CPU virtualization extensions (Intel VT-x or AMD-V) are enabled in your BIOS/UEFI settings before running this script&#8203;:contentReference[oaicite:8]{index=8}."
    Write-Host "Cannot continue without virtualization enabled. Exiting."
    Stop-Transcript
    exit 1
}

# Step 2: Enable required Windows features (WSL, Virtual Machine Platform, Hyper-V)
Write-Host "`nChecking required Windows features (WSL, Virtual Machine Platform, Hyper-V)...`n"
$featuresToEnable = @()
# WSL (Subsystem for Linux)
$wslFeature = "Microsoft-Windows-Subsystem-Linux"
$wslState = (Get-WindowsOptionalFeature -Online -FeatureName $wslFeature).State
if ($wslState -ne "Enabled") { $featuresToEnable += $wslFeature }
# Virtual Machine Platform
$vmpFeature = "VirtualMachinePlatform"
$vmpState = (Get-WindowsOptionalFeature -Online -FeatureName $vmpFeature).State
if ($vmpState -ne "Enabled") { $featuresToEnable += $vmpFeature }
# Hyper-V (optional, only on Pro/Enterprise editions; ignore failures if not present)
$hypervFeature = "Microsoft-Hyper-V-All"
$hypervState = (Get-WindowsOptionalFeature -Online -FeatureName $hypervFeature -ErrorAction SilentlyContinue)?.State
if ($hypervState -and $hypervState -ne "Enabled") { $featuresToEnable += $hypervFeature }

if ($featuresToEnable.Count -gt 0) {
    Write-Host "Enabling Windows features required for WSL2: $($featuresToEnable -join ', ')...&#8203;:contentReference[oaicite:9]{index=9}"
    foreach ($feat in $featuresToEnable) {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -All -ErrorAction Stop | Out-Null
            Write-Host "Feature '$feat' has been enabled."
        } catch {
            Write-Error "Failed to enable feature $feat: $_"
        }
    }
    $global:rebootRequired = $true
    Write-Host "`n[!] One or more features were enabled. A system restart is required before continuing." -ForegroundColor Yellow
    Write-Host "Please save any work, then restart your computer and run this script again to complete the setup."
    Write-Host "Press Enter to exit and reboot..."
    [Console]::ReadLine() | Out-Null
    Stop-Transcript
    # Optionally, we could trigger an automatic reboot:
    # Restart-Computer -Force
    exit 0
} else {
    Write-Host "All required Windows features for WSL are already enabled."
}

# (If script continues past this point, it means no reboot was needed, i.e., features were already enabled)
# Step 3: Set WSL 2 as default and install Ubuntu
Write-Host "`nConfiguring WSL 2 as the default version..."
try {
    wsl --set-default-version 2
    Write-Host "Default WSL version set to 2."
} catch {
    Write-Warning "Unable to set WSL default version to 2 (possibly an older Windows version). $_"
    # Not critical; proceed with installation which will likely default to WSL1 if 2 not supported.
}

# Check if Ubuntu is already installed under WSL
$ubuntuInstalled = & wsl -l -q | Select-String -Pattern "^Ubuntu" 
if ($ubuntuInstalled) {
    Write-Host "Ubuntu is already installed in WSL. Skipping WSL installation."
} else {
    Write-Host "Installing Ubuntu WSL distribution (this may take a few minutes)&#8203;:contentReference[oaicite:10]{index=10}..."
    try {
        # Use wsl --install to automatically install Ubuntu
        # This command may reboot the system automatically on some OS versions, but we'll assume it won't here.
        wsl --install -d Ubuntu | Write-Host
        Write-Host "`nUbuntu installation command executed."
        Write-Host "Please create a UNIX username and password if prompted in the Ubuntu installation window."
    } catch {
        Write-Error "WSL distribution installation failed: $_"
        Write-Host "If the automated install fails, you may need to install Ubuntu from the Microsoft Store manually."
        Stop-Transcript
        exit 1
    }
}

# Wait a moment to ensure Ubuntu is set up (the user might need to complete initial setup)
Start-Sleep -Seconds 5

# (Optional) Step 4: Update Ubuntu packages 
Write-Host "`nUpdating Ubuntu packages (apt-get update && upgrade) to ensure latest patches..."
try {
    # Run apt update/upgrade in Ubuntu (as root)
    wsl -d Ubuntu -u root -- bash -c "apt-get update && apt-get upgrade -y"
    Write-Host "Ubuntu packages updated successfully."
} catch {
    Write-Warning "Ubuntu update/upgrade encountered an error (this can be done manually later): $_"
}

Write-Host "Ubuntu setup completed."  # Confirm completion of WSL setup

# Step 5: Configure Firewall rules for Pi Node ports
Write-Host "`nConfiguring Windows Firewall to allow Pi Node network ports (31400-31409)..."
$ruleName = "Pi Node Ports"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existingRule) {
    Write-Host "Firewall rule '$ruleName' already exists. Skipping creation."
} else {
    try {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Profile Any `
            -Action Allow -Protocol TCP -LocalPort 31400-31409 -ErrorAction Stop
        Write-Host "Firewall rule '$ruleName' added successfully."
    } catch {
        Write-Error "Failed to add Firewall rule for Pi Node ports: $_"
        Write-Host "Please ensure ports 31400-31409 are allowed in your firewall settings&#8203;:contentReference[oaicite:11]{index=11}."
    }
}

# Step 6: Download and install Pi Node software
Write-Host "`nDownloading Pi Node software installer..."
$piNodeUrl = "https://node.minepi.com/download"   # Official Pi Node download URL
$piNodeInstaller = "$env:TEMP\PiNodeInstaller.exe"
$maxRetries = 3
$downloadSuccess = $false
for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    try {
        Write-Host "Attempt $attempt of $maxRetries: Downloading Pi Node from $piNodeUrl ..."
        Invoke-WebRequest -Uri $piNodeUrl -OutFile $piNodeInstaller -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $downloadSuccess = $true
        Write-Host "Pi Node installer downloaded to $piNodeInstaller"
        break
    } catch {
        Write-Warning "Download attempt $attempt failed: $($_.Exception.Message)"
        if ($attempt -lt $maxRetries) {
            Write-Host "Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}
if (-not $downloadSuccess) {
    Write-Error "Failed to download Pi Node installer after $maxRetries attempts. Please check your internet connection and try again."
    Stop-Transcript
    exit 1
}

# Run the Pi Node installer silently (if supported) or interactively if not
Write-Host "Installing Pi Node software..."
try {
    $installArgs = "/S"  # Silent install argument (common for many installers; Pi Node installer will use it if supported)
    $process = Start-Process -FilePath $piNodeInstaller -ArgumentList $installArgs -PassThru -Wait
    # Check exit code if available
    if ($process.ExitCode -ne 0) {
        Write-Warning "Pi Node installer exited with code $($process.ExitCode). If the installation did not complete, please run the installer manually."
    }
    Write-Host "Pi Node installation complete."
} catch {
    Write-Error "Failed to execute Pi Node installer: $_"
    Write-Host "You may need to run the installer manually. Check the log for details."
}

# Step 7: Set up a scheduled task for Pi Node auto-start at user logon (with restart on failure)
Write-Host "`nConfiguring Pi Node auto-start and auto-restart task..."
$taskName = "Start Pi Node"
# Define the action to launch Pi Node (adjust path if needed)
$piNodeExePath = "C:\Program Files\PiNode\PiNode.exe"  # Default install path (update if different)
if (-not (Test-Path $piNodeExePath)) {
    # Pi Node might install for the user in AppData if not found in Program Files. Try an alternative known path or prompt.
    $piNodeExePath = "$env:LOCALAPPDATA\Programs\Pi Network\Pi Node\Pi Node.exe"
}
$taskAction = New-ScheduledTaskAction -Execute $piNodeExePath
# Trigger at logon of current user
$currentUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName  # Domain\User format
if (-not $currentUser) { $currentUser = "$env:COMPUTERNAME\$env:USERNAME" }  # fallback to COMPUTERNAME\Username
$taskTrigger = New-ScheduledTaskTrigger -AtLogon
# Task settings: allow to restart on failure up to 3 times, with 5 minute interval
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -RestartInterval (New-TimeSpan -Minutes 5) -RestartCount 3

# Register the scheduled task if it doesn't exist
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (!$existingTask) {
    try {
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger `
            -Settings $taskSettings -Description "Automatically starts Pi Node on user logon and restarts if it crashes." `
            -User $currentUser -RunLevel Limited
        Write-Host "Pi Node auto-start task '$taskName' created."
    } catch {
        Write-Warning "Failed to create Pi Node startup task (perhaps due to permissions or invalid user). $_"
        Write-Host "You may need to set Pi Node to start manually or create a task manually in Task Scheduler."
    }
} else {
    Write-Host "Pi Node startup task already exists. No changes made."
}

# Step 8: Set up system resource monitoring task (CPU, RAM, IP) with optional email alerts
Write-Host "`nSetting up system resource monitoring, IP tracking, and logging..."
$monitorScriptPath = "$env:USERPROFILE\PiNodeMonitor.ps1"
$monitorLog = "$env:USERPROFILE\PiNodeMonitor.log"
# Email alert configuration (user can enable and set these if desired)
$enableEmailAlerts = $false
# If enabling email alerts, configure these variables:
$emailTo   = "your_email@example.com"
$emailFrom = "pinode_monitor@example.com"
$smtpServer = "smtp.yourmailserver.com"
$smtpPort   = 587
# For credentials, you might use an app password or an internal relay. Get-Credential could be used for interactive, but here we use a placeholder secure string.
$smtpUser   = "smtp_username"
$smtpPass   = "password" 
$securePass = ConvertTo-SecureString $smtpPass -AsPlainText -Force
$smtpCred   = New-Object System.Management.Automation.PSCredential($smtpUser, $securePass)

# Build the monitoring script content
$monitorScriptContent = @"
`$LogFile = '$monitorLog'
`$lastIP = ""
while (`$true) {
    try {
        `$cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
        `$ram = (Get-Counter '\Memory\Available MBytes').CounterSamples.CookedValue
    } catch {
        # If performance counters fail, skip this iteration
        `$cpu = 0; `$ram = 0
    }
    # Get external IP (using ipify service)
    try {
        `$currentIP = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing).Content
    } catch {
        `$currentIP = "Unavailable"
    }
    "`$(Get-Date) - CPU: `$([math]::Round(`$cpu,2))% - RAM: `$([math]::Round(`$ram,2)) MB - IP: `$currentIP" | Out-File -FilePath `$LogFile -Append

    if (`$cpu -gt 80) {
        Write-Host "Warning: High CPU usage (`$([math]::Round(`$cpu,2))%)"
        if ($enableEmailAlerts) {
            Send-MailMessage -To '$emailTo' -From '$emailFrom' -Subject "Pi Node Alert: High CPU Usage" -Body "High CPU usage detected: `$([math]::Round(`$cpu,2))% at `$(Get-Date)`." -SmtpServer '$smtpServer' -Port $smtpPort -UseSsl -Credential `$smtpCred
        }
    }
    if (`$ram -lt 500) {
        Write-Host "Warning: Low available RAM (`$([math]::Round(`$ram,2)) MB)"
        if ($enableEmailAlerts) {
            Send-MailMessage -To '$emailTo' -From '$emailFrom' -Subject "Pi Node Alert: Low RAM" -Body "Low available RAM: `$([math]::Round(`$ram,2)) MB at `$(Get-Date)`." -SmtpServer '$smtpServer' -Port $smtpPort -UseSsl -Credential `$smtpCred
        }
    }
    if (`$currentIP -ne `$lastIP -and `$currentIP -ne "Unavailable") {
        Write-Host "IP Address changed to: `$currentIP"
        if ($enableEmailAlerts) {
            Send-MailMessage -To '$emailTo' -From '$emailFrom' -Subject "Pi Node Alert: IP Changed" -Body "External IP changed to `$currentIP at `$(Get-Date)`." -SmtpServer '$smtpServer' -Port $smtpPort -UseSsl -Credential `$smtpCred
        }
        `$lastIP = `$currentIP
    }
    Start-Sleep -Seconds 60
}
"@

# Save the monitoring script to file
try {
    $monitorScriptContent | Out-File -FilePath $monitorScriptPath -Encoding UTF8 -Force
    Write-Host "Monitoring script saved to $monitorScriptPath"
} catch {
    Write-Warning "Failed to write monitoring script to file: $_"
}

# Create a scheduled task to run the monitoring script at startup (as SYSTEM)
$monitorTaskName = "Pi Node Monitor"
$existingMonTask = Get-ScheduledTask -TaskName $monitorTaskName -ErrorAction SilentlyContinue
if (!$existingMonTask) {
    Write-Host "Creating scheduled task for system monitoring..."
    try {
        $monAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monitorScriptPath`""
        $monTrigger = New-ScheduledTaskTrigger -AtStartup
        # Run as LocalSystem
        $monPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $monitorTaskName -Action $monAction -Trigger $monTrigger -Principal $monPrincipal `
            -Description "Monitors CPU, RAM, and external IP changes for Pi Node, logging to $monitorLog"
        Write-Host "Pi Node monitoring task '$monitorTaskName' created (runs at startup)."
    } catch {
        Write-Warning "Failed to register monitoring task: $_"
        Write-Host "You may need to run the monitoring script manually or with your own scheduled task if desired."
    }
} else {
    Write-Host "Pi Node monitoring task already exists. No changes made."
}

# Step 9: Completion message and next steps
Write-Host "`n=== Setup complete! ===" -ForegroundColor Green
Write-Host "Pi Node setup automation has finished. Please restart your computer before launching the Pi Node application." -ForegroundColor Yellow
Write-Host "After reboot, you can find the Pi Node app in the Start Menu (it may also auto-start at login)."
Write-Host "Log in to the Pi Node app with your credentials to complete the node configuration."
Write-Host "`nThank you for using the Pi Node Setup script. Press Enter to exit."
[Console]::ReadLine() | Out-Null

# End transcript logging
Try { Stop-Transcript | Out-Null } Catch {}
