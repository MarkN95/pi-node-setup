# Pi Node Setup Assistant 🚀

This PowerShell script automates the setup of a Pi Network node on a Windows machine. It ensures:
- Virtualization is enabled
- WSL2 and Ubuntu installation
- Firewall & network settings
- Pi Node auto-start & monitoring

## Features:
✅ Auto-checks & installs dependencies  
✅ Automatic Pi Node startup & monitoring  
✅ Network & firewall configuration  

## Installation:
1. **Download** the script from this repository.
2. **Run PowerShell as Administrator**.
3. **Execute the script**:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\pi-node-setup.ps1

