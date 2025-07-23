# Example Packer variable file for Windows builds
# Copy this to variables.pkrvars.hcl and customize for your environment

# Proxmox connection settings
proxmox_url      = "https://your-proxmox-server:8006/api2/json"
proxmox_user     = "your-user@pam"
proxmox_password = "your-password"
node             = "your-node-name"

# Storage configuration
iso_storage        = "local"
disk_storage       = "local-lvm"
efi_storage        = "local-lvm"
cloud_init_storage = "local-lvm"

# VM hardware settings
memory = 8192
cores  = 4
socket = 1

# Network settings
bridge = "vnet0"

# Windows settings
install_user     = "runner"
install_password = "YourSecurePassword123!"
timezone         = "UTC"

# Image settings
image_os      = "win25" # Options: win19, win22, win25
image_version = "dev"
disk_size_gb  = "256G"

# License keys (optional - leave empty for evaluation versions)
license_keys = {
  win19 = "" # "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
  win22 = "" # "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
  win25 = "" # "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
}

# ISO files (ensure these exist in your Proxmox ISO storage)
virtio_win_iso = "virtio-win.iso"
