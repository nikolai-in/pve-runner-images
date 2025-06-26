packer {
  required_plugins {
    proxmox = {
      version = "> 1.2.3"
      source  = "github.com/nikolai-in/proxmox"
    }
    windows-update = {
      version = "> 0.16.10"
      source  = "github.com/rgl/windows-update"
    }
  }
}

// Proxmox related variables
variable "proxmox_url" {
  type        = string
  description = "Proxmox Server URL"
}

variable "proxmox_insecure" {
  type        = bool
  description = "Allow insecure connections to Proxmox"
  default     = false
}

variable "proxmox_user" {
  type        = string
  description = "Proxmox username"
  sensitive   = true
}

variable "proxmox_password" {
  type        = string
  description = "Proxmox password"
  sensitive   = true
}

variable "node" {
  type        = string
  description = "Proxmox cluster node"
}

// Proxmox storage related variables
variable "iso_storage" {
  type        = string
  description = "Proxmox storage location for iso files"
  default     = "local"
}

variable "disk_storage" {
  type        = string
  description = "Disk storage location"
  default     = "local-lvm"
}

variable "efi_storage" {
  type        = string
  description = "Location of EFI storage on proxmox host"
  default     = "local-lvm"
}

variable "cloud_init_storage" {
  type        = string
  description = "Location of cloud-init files/iso/yaml config"
  default     = "local-lvm"
}

// VM hardware related variables
variable "memory" {
  type        = number
  description = "Amount of RAM in MB"
  default     = 8192
}

variable "ballooning_minimum" {
  type        = number
  description = "Minimum amount of RAM in MB for ballooning"
  default     = 2048
}

variable "cores" {
  type        = number
  description = "Amount of CPU cores"
  default     = 2
}

variable "socket" {
  type        = number
  description = "Amount of CPU sockets"
  default     = 1
}

variable "disk_size_gb" {
  type        = string
  description = "The size of the disk, including a unit suffix, such as 10G to indicate 10 gigabytes"
  default     = "64G"
}

variable "disk_extend_gb" {
  type        = string
  description = "The size of the extended runner disk, including a unit suffix, such as 10G to indicate 10 gigabytes"
  default     = "256G"
}

variable "bridge" {
  type        = string
  description = "Network bridge name"
  default     = "vmbr0"
}

// Windows related variables

variable "windows_iso" {
  type        = string
  description = "Windows ISO file name"
  default     = "en-us_windows_server_2025_eval_x64fre.iso"
}

variable "image_index" {
  type        = string
  description = "Image index in the Windows ISO file"
  default     = "2"
}

variable "license_key" {
  type        = string
  description = "Windows license key, leave empty for evaluation version"
  default     = ""
  validation {
    condition     = var.license_key == "" || can(regex("^([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}$", var.license_key))
    error_message = "The license_key must be either empty for evaluation version or in the format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
  }
}

variable "virtio_win_iso" {
  type        = string
  description = "Virtio-win ISO file"
  default     = "virtio-win.iso"
}

variable "cdrom_drive" {
  type        = string
  description = "CD-ROM Drive letter for extra iso"
  default     = "D:"
}

variable "virtio_cdrom_drive" {
  type        = string
  description = "CD-ROM Drive letter for virtio-win iso"
  default     = "E:"
}

variable "timezone" {
  type        = string
  description = "Windows timezone"
  default     = "UTC"
}

variable "base_template_name" {
  type        = string
  description = "Name for the base template in Proxmox"
  default     = "win25-base"
}

variable "runner_template_name" {
  type        = string
  description = "Name for the runner template in Proxmox"
  default     = "win25-runner"
}

// Build scripts related variables
variable "agent_tools_directory" {
  type    = string
  default = "C:\\hostedtoolcache\\windows"
}

variable "helper_script_folder" {
  type    = string
  default = "C:\\Program Files\\WindowsPowerShell\\Modules\\"
}

variable "image_folder" {
  type    = string
  default = "C:\\image"
}

variable "image_os" {
  type    = string
  default = "win25"
}

variable "image_version" {
  type    = string
  default = "dev"
}

variable "imagedata_file" {
  type    = string
  default = "C:\\imagedata.json"
}

variable "temp_dir" {
  type    = string
  default = "C:\\temp"
}

variable "install_password" {
  type      = string
  default   = "GetsugaTenshou"
  sensitive = true
}

variable "install_user" {
  type    = string
  default = "Administrator"
}

source "proxmox-iso" "base" {

  // PROXMOX CONNECTION CONFIGURATION
  proxmox_url              = var.proxmox_url
  insecure_skip_tls_verify = var.proxmox_insecure
  username                 = var.proxmox_user
  password                 = var.proxmox_password
  node                     = var.node

  // BIOS & MACHINE CONFIGURATION
  bios    = "ovmf"
  machine = "q35"

  efi_config {
    efi_storage_pool  = var.efi_storage
    pre_enrolled_keys = true
    efi_type          = "4m"
  }

  // BOOT MEDIA CONFIGURATION
  boot_iso {
    iso_file         = "${var.iso_storage}:iso/${var.windows_iso}"
    iso_storage_pool = var.iso_storage
    unmount          = true
  }

  additional_iso_files {
    iso_file         = "${var.iso_storage}:iso/${var.virtio_win_iso}"
    iso_storage_pool = var.iso_storage
    unmount          = true
    type             = "sata"
    index            = 1
  }

  additional_iso_files {
    cd_files = ["../scripts/build/Configure-RemotingForAnsible.ps1"]
    cd_content = {
      "autounattend.xml" = templatefile("../assets/base-image/unattend.pkrtpl", {
        user               = var.install_user,
        password           = var.install_password,
        cdrom_drive        = var.cdrom_drive,
        license_key        = var.license_key,
        timezone           = var.timezone,
        index              = var.image_index
        virtio_cdrom_drive = var.virtio_cdrom_drive
      })
    }
    cd_label         = "Unattend"
    iso_storage_pool = var.iso_storage
    unmount          = true
    type             = "sata"
    index            = 0
  }

  // VM TEMPLATE CONFIGURATION
  template_name        = var.base_template_name
  vm_name              = "win-instance-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  template_description = "Windows 2025 Base Image\nCreated on: ${formatdate("EEE, DD MMM YYYY hh:mm:ss ZZZ", timestamp())}"
  os                   = "win11"

  // HARDWARE CONFIGURATION
  memory          = var.memory
  cores           = var.cores
  sockets         = var.socket
  cpu_type        = "host"
  scsi_controller = "virtio-scsi-pci"
  serials         = ["socket"]

  // NETWORK CONFIGURATION
  network_adapters {
    model  = "virtio"
    bridge = var.bridge
  }

  // STORAGE CONFIGURATION
  disks {
    storage_pool = var.disk_storage
    type         = "scsi"
    disk_size    = var.disk_size_gb
    cache_mode   = "writeback"
    format       = "raw"
  }

  // WINRM COMMUNICATION CONFIGURATION
  communicator   = "winrm"
  winrm_username = var.install_user
  winrm_password = var.install_password
  winrm_timeout  = "1h"
  winrm_port     = "5986"
  winrm_use_ssl  = true
  winrm_insecure = true

  // BOOT CONFIGURATION
  boot         = "order=scsi0"
  boot_wait    = "3s"
  boot_command = ["<enter><enter>", "\\efi\\boot\\bootx64.efi<enter><wait>", "<enter>"]
}

build {
  name = "base"

  sources = [
    "source.proxmox-iso.base"
  ]

  provisioner "windows-restart" {
  }

  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  provisioner "powershell" {
    script = "../scripts/build/Install-CloudBase.ps1"
  }

  provisioner "file" {
    source      = "../assets/base-image/config/"
    destination = "C://Program Files//Cloudbase Solutions//Cloudbase-Init//conf"
  }

  provisioner "powershell" {
    inline = [
      "Set-Service cloudbase-init -StartupType Manual",
      "Stop-Service cloudbase-init -Force -Confirm:$false"
    ]
  }
}

source "proxmox-clone" "runner" {
  // PROXMOX CONNECTION CONFIGURATION
  proxmox_url              = var.proxmox_url
  insecure_skip_tls_verify = true
  username                 = var.proxmox_user
  password                 = var.proxmox_password
  node                     = var.node

  // CLONE CONFIGURATION
  clone_vm                = var.base_template_name
  full_clone              = false
  vm_name                 = "win-instance-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  template_name           = var.runner_template_name
  template_description    = "Windows VM cloned from base template\nCreated on: ${formatdate("EEE, DD MMM YYYY hh:mm:ss ZZZ", timestamp())}"
  os                      = "win11"
  cloud_init              = true
  cloud_init_storage_pool = var.cloud_init_storage

  // HARDWARE CONFIGURATION
  memory          = var.memory
  cores           = var.cores
  sockets         = var.socket
  cpu_type        = "host"
  scsi_controller = "virtio-scsi-pci"


  // NETWORK CONFIGURATION
  network_adapters {
    model  = "virtio"
    bridge = var.bridge
  }


  // COMMUNICATION CONFIGURATION
  communicator   = "winrm"
  winrm_username = var.install_user
  winrm_password = var.install_password
  winrm_timeout  = "30m"
  winrm_port     = "5986"
  winrm_use_ssl  = true
  winrm_insecure = true

  disk {
    size  = var.disk_extend_gb # set this to your desired larger size
    type  = "scsi"             # or "virtio", "sata", "ide"
    index = "0"                # this can be set if you want to control the device index
  }

}

build {
  name = "runner"

  sources = [
    "source.proxmox-clone.runner"
  ]

  // Create required directories for image build process
  provisioner "powershell" {
    inline = [
      "New-Item -Path ${var.image_folder} -ItemType Directory -Force",
      "New-Item -Path ${var.temp_dir} -ItemType Directory -Force"
    ]
  }

  // Copy build assets, scripts, and toolsets to the VM
  provisioner "file" {
    destination = "${var.image_folder}\\"
    sources = [
      "${path.root}/../assets",
      "${path.root}/../scripts",
      "${path.root}/../toolsets"
    ]
  }

  // Copy software report generation scripts
  provisioner "file" {
    destination = "${var.image_folder}\\scripts\\docs-gen\\"
    source      = "${path.root}/../../../helpers/software-report-base"
  }

  // Reorganize copied files into proper directory structure for the build process
  provisioner "powershell" {
    inline = [
      "Move-Item '${var.image_folder}\\assets\\post-gen' 'C:\\post-generation'",
      "Remove-Item -Recurse '${var.image_folder}\\assets'",
      "Move-Item '${var.image_folder}\\scripts\\docs-gen' '${var.image_folder}\\SoftwareReport'",
      "Move-Item '${var.image_folder}\\scripts\\helpers' '${var.helper_script_folder}\\ImageHelpers'",
      "New-Item -Type Directory -Path '${var.helper_script_folder}\\TestsHelpers\\'",
      "Move-Item '${var.image_folder}\\scripts\\tests\\Helpers.psm1' '${var.helper_script_folder}\\TestsHelpers\\TestsHelpers.psm1'",
      "Move-Item '${var.image_folder}\\scripts\\tests' '${var.image_folder}\\tests'",
      "Remove-Item -Recurse '${var.image_folder}\\scripts'",
      "Move-Item '${var.image_folder}\\toolsets\\toolset-2025.json' '${var.image_folder}\\toolset.json'",
      "Remove-Item -Recurse '${var.image_folder}\\toolsets'"
    ]
  }

  // Configure Windows user account and WinRM authentication for build process
  provisioner "windows-shell" {
    inline = [
      "net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes /active:yes /Y",
      "net localgroup Administrators ${var.install_user} /add",
      "winrm set winrm/config/service/auth @{Basic=\"true\"}",
      "winrm get winrm/config/service/auth"
    ]
  }

  // Verify user was added to Administrators group successfully
  provisioner "powershell" {
    inline = ["if (-not ((net localgroup Administrators) -contains '${var.install_user}')) { exit 1 }"]
  }

  // Install core system components and configure base settings
  // Tests: PowerShellModules.Tests.ps1 (verify PowerShell modules), WindowsFeatures.Tests.ps1 (verify Windows features)
  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "AGENT_TOOLSDIRECTORY=${var.agent_tools_directory}", "IMAGEDATA_FILE=${var.imagedata_file}", "IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    execution_policy = "unrestricted"
    scripts = [
      "${path.root}/../scripts/build/Configure-WindowsDefender.ps1",
      "${path.root}/../scripts/build/Configure-PowerShell.ps1",
      "${path.root}/../scripts/build/Install-PowerShellModules.ps1",
      "${path.root}/../scripts/build/Install-WSL2.ps1",
      "${path.root}/../scripts/build/Install-WindowsFeatures.ps1",
      "${path.root}/../scripts/build/Install-Chocolatey.ps1",
      "${path.root}/../scripts/build/Configure-BaseImage.ps1",
      "${path.root}/../scripts/build/Configure-ImageDataFile.ps1",
      "${path.root}/../scripts/build/Configure-SystemEnvironment.ps1",
      "${path.root}/../scripts/build/Configure-DotnetSecureChannel.ps1"
    ]
  }

  // Wait for Windows container feature to be fully enabled before proceeding
  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {while ( (Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue).State -ne 'Enabled' ) { Start-Sleep 30; Write-Output 'InProgress' }}\""
    restart_timeout       = "10m"
  }

  // Disable WLAN service (not needed in VM environment)
  provisioner "powershell" {
    inline = ["Set-Service -Name wlansvc -StartupType Manual", "if ($(Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc}"]
  }

  // Install container tools and development platform components
  // Tests: Docker.Tests.ps1 (verify Docker engine, compose, credential helper), PowerShellCore.Tests.ps1 (verify PowerShell Core)
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-Docker.ps1",
      "${path.root}/../scripts/build/Install-DockerWinCred.ps1",
      "${path.root}/../scripts/build/Install-DockerCompose.ps1",
      "${path.root}/../scripts/build/Install-PowershellCore.ps1",
      "${path.root}/../scripts/build/Install-WebPlatformInstaller.ps1",
      "${path.root}/../scripts/build/Install-Runner.ps1"
    ]
  }

  // Restart after Visual Studio installation (may require reboot for components)
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  // Install Visual Studio IDE and Kubernetes development tools
  // Tests: VisualStudio.Tests.ps1 (verify VS installation, components, workloads), Kubernetes.Tests.ps1 (verify kubectl, helm, minikube)
  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-VisualStudio.ps1",
      "${path.root}/../scripts/build/Install-KubernetesTools.ps1"
    ]
    valid_exit_codes = [0, 3010]
  }

  // Restart after Visual Studio extensions and additional components
  provisioner "windows-restart" {
    check_registry  = true
    restart_timeout = "10m"
  }

  // Install development tools, cloud CLI tools, and package managers
  // Tests: Wix.Tests.ps1 (WiX Toolset), Vsix.Tests.ps1 (VS extensions), AzureCli.Tests.ps1 (Azure CLI), 
  //        ChocolateyPackages.Tests.ps1 (Chocolatey packages), JavaTools.Tests.ps1 (Java, Maven, Gradle), Kotlin.Tests.ps1 (Kotlin)
  provisioner "powershell" {
    pause_before     = "2m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-Wix.ps1",
      "${path.root}/../scripts/build/Install-VSExtensions.ps1",
      "${path.root}/../scripts/build/Install-AzureCli.ps1",
      "${path.root}/../scripts/build/Install-AzureDevOpsCli.ps1",
      "${path.root}/../scripts/build/Install-ChocolateyPackages.ps1",
      "${path.root}/../scripts/build/Install-JavaTools.ps1",
      "${path.root}/../scripts/build/Install-Kotlin.ps1",
      "${path.root}/../scripts/build/Install-OpenSSL.ps1"
    ]
  }

  // Install Service Fabric SDK with different execution policy
  // Tests: ServiceFabricSDK.Tests.ps1 (verify Service Fabric SDK installation and tools)
  provisioner "powershell" {
    execution_policy = "remotesigned"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = ["${path.root}/../scripts/build/Install-ServiceFabricSDK.ps1"]
  }

  // Restart after Service Fabric SDK installation
  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  // Install programming languages, development frameworks, and web browsers
  // Tests: Ruby.Tests.ps1 (Ruby, gems), Node.Tests.ps1 (Node.js, npm, yarn), AndroidSDK.Tests.ps1 (Android SDK), 
  //        PowerShellAzModules.Tests.ps1 (Azure PowerShell modules), PipxPackages.Tests.ps1 (Python pipx packages),
  //        Git.Tests.ps1 (Git, Git LFS), PHP.Tests.ps1 (PHP, Composer), Rust.Tests.ps1 (Rust, Cargo),
  //        Browsers.Tests.ps1 (Chrome, Firefox), Selenium.Tests.ps1 (WebDriver), Apache.Tests.ps1 (Apache), Nginx.Tests.ps1 (Nginx),
  //        MSYS2.Tests.ps1 (MSYS2 environment), WinAppDriver.Tests.ps1 (Windows Application Driver), R.Tests.ps1 (R language),
  //        AWS.Tests.ps1 (AWS CLI/tools), DotnetSDK.Tests.ps1 (.NET SDK), Haskell.Tests.ps1 (Haskell, Stack),
  //        Miniconda.Tests.ps1 (Conda), Tools.Tests.ps1 (various development tools), MongoDB.Tests.ps1 (MongoDB)
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-ActionsCache.ps1",
      "${path.root}/../scripts/build/Install-Ruby.ps1",
      "${path.root}/../scripts/build/Install-PyPy.ps1",
      "${path.root}/../scripts/build/Install-Toolset.ps1",
      "${path.root}/../scripts/build/Configure-Toolset.ps1",
      "${path.root}/../scripts/build/Install-NodeJS.ps1",
      "${path.root}/../scripts/build/Install-AndroidSDK.ps1",
      "${path.root}/../scripts/build/Install-PowershellAzModules.ps1",
      "${path.root}/../scripts/build/Install-Pipx.ps1",
      "${path.root}/../scripts/build/Install-Git.ps1",
      "${path.root}/../scripts/build/Install-GitHub-CLI.ps1",
      "${path.root}/../scripts/build/Install-PHP.ps1",
      "${path.root}/../scripts/build/Install-Rust.ps1",
      "${path.root}/../scripts/build/Install-Sbt.ps1",
      "${path.root}/../scripts/build/Install-Chrome.ps1",
      "${path.root}/../scripts/build/Install-EdgeDriver.ps1",
      "${path.root}/../scripts/build/Install-Firefox.ps1",
      "${path.root}/../scripts/build/Install-Selenium.ps1",
      "${path.root}/../scripts/build/Install-IEWebDriver.ps1",
      "${path.root}/../scripts/build/Install-Apache.ps1",
      "${path.root}/../scripts/build/Install-Nginx.ps1",
      "${path.root}/../scripts/build/Install-Msys2.ps1",
      "${path.root}/../scripts/build/Install-WinAppDriver.ps1",
      "${path.root}/../scripts/build/Install-R.ps1",
      "${path.root}/../scripts/build/Install-AWSTools.ps1",
      "${path.root}/../scripts/build/Install-DACFx.ps1",
      "${path.root}/../scripts/build/Install-MysqlCli.ps1",
      "${path.root}/../scripts/build/Install-SQLPowerShellTools.ps1",
      "${path.root}/../scripts/build/Install-SQLOLEDBDriver.ps1",
      "${path.root}/../scripts/build/Install-DotnetSDK.ps1",
      "${path.root}/../scripts/build/Install-Mingw64.ps1",
      "${path.root}/../scripts/build/Install-Haskell.ps1",
      "${path.root}/../scripts/build/Install-Stack.ps1",
      "${path.root}/../scripts/build/Install-Miniconda.ps1",
      "${path.root}/../scripts/build/Install-AzureCosmosDbEmulator.ps1",
      "${path.root}/../scripts/build/Install-Zstd.ps1",
      "${path.root}/../scripts/build/Install-Vcpkg.ps1",
      "${path.root}/../scripts/build/Install-Bazel.ps1",
      "${path.root}/../scripts/build/Install-RootCA.ps1",
      "${path.root}/../scripts/build/Install-MongoDB.ps1",
      "${path.root}/../scripts/build/Install-CodeQLBundle.ps1",
      "${path.root}/../scripts/build/Configure-Diagnostics.ps1"
    ]
  }

  // Install database systems, Windows updates, and system configuration with elevated privileges
  // Tests: PostgreSQL.Tests.ps1 (PostgreSQL installation), Shell.Tests.ps1 (shell configuration), 
  //        LLVM.Tests.ps1 (LLVM toolchain)
  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-PostgreSQL.ps1",
      "${path.root}/../scripts/build/Install-WindowsUpdates.ps1",
      "${path.root}/../scripts/build/Configure-DynamicPort.ps1",
      "${path.root}/../scripts/build/Configure-GDIProcessHandleQuota.ps1",
      "${path.root}/../scripts/build/Configure-Shell.ps1",
      "${path.root}/../scripts/build/Configure-DeveloperMode.ps1",
      "${path.root}/../scripts/build/Install-LLVM.ps1"
    ]
  }

  // Final restart to ensure all Windows updates and system changes take effect
  // Wait for TiWorker.exe (Windows Module Installer) to finish before proceeding
  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {if ((-not (Get-Process TiWorker.exe -ErrorAction SilentlyContinue)) -and (-not [System.Environment]::HasShutdownStarted) ) { Write-Output 'Restart complete' }}\""
    restart_timeout       = "30m"
  }

  // Final cleanup, run comprehensive test suite, and validate all installations
  // Tests: RunAll-Tests.ps1 (executes all *.Tests.ps1 files to validate entire image installation)
  //        This includes validation of all previously installed components, tools, SDKs, and configurations
  provisioner "powershell" {
    pause_before     = "2m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-WindowsUpdatesAfterReboot.ps1",
      "${path.root}/../scripts/build/Invoke-Cleanup.ps1",
      "${path.root}/../scripts/tests/RunAll-Tests.ps1"
    ]
  }

  // Validate test results exist before proceeding
  // Ensures that the comprehensive test suite executed successfully and produced results
  provisioner "powershell" {
    inline = ["if (-not (Test-Path ${var.image_folder}\\tests\\testResults.xml)) { throw '${var.image_folder}\\tests\\testResults.xml not found' }"]
  }

  // Generate comprehensive software report documenting all installed components
  // Creates markdown and JSON reports listing all software, tools, and versions installed in the image
  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_FOLDER=${var.image_folder}"]
    inline           = ["pwsh -File '${var.image_folder}\\SoftwareReport\\Generate-SoftwareReport.ps1'"]
  }

  // Validate software reports were generated successfully
  // Ensures both markdown and JSON software reports exist before proceeding
  provisioner "powershell" {
    inline = ["if (-not (Test-Path C:\\software-report.md)) { throw 'C:\\software-report.md not found' }", "if (-not (Test-Path C:\\software-report.json)) { throw 'C:\\software-report.json not found' }"]
  }

  // Download software reports from VM to host for documentation
  // Retrieves the generated software documentation files for external use
  provisioner "file" {
    destination = "${path.root}/../Windows2025-Readme.md"
    direction   = "download"
    source      = "C:\\software-report.md"
  }

  provisioner "file" {
    destination = "${path.root}/../software-report.json"
    direction   = "download"
    source      = "C:\\software-report.json"
  }

  // Final system configuration and user setup before image finalization
  // Performs final optimizations and user account configuration
  provisioner "powershell" {
    environment_vars = ["INSTALL_USER=${var.install_user}"]
    scripts = [
      "${path.root}/../scripts/build/Install-NativeImages.ps1",
      "${path.root}/../scripts/build/Configure-System.ps1",
      "${path.root}/../scripts/build/Configure-User.ps1"
    ]
    skip_clean = true
  }

  // Final restart and Windows sysprep to generalize the image
  // Prepares the Windows installation for deployment by removing unique identifiers
  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  provisioner "powershell" {
    inline = [
      "Set-Location -Path \"C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\"",
      "C:\\Windows\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /unattend:unattend.xml"
    ]
  }

}
