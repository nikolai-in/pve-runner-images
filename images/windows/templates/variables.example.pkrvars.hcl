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

# VM IDs for templates (optional - set to 0 for auto-assignment)
# VMIDs must be unique cluster-wide and in range 100-999999999
vm_ids = {
  win19_base   = 0 # 1019  # Example: assign specific VM ID
  win19_runner = 0 # 2019  # Example: assign specific VM ID
  win22_base   = 0 # 1022  # Example: assign specific VM ID
  win22_runner = 0 # 2022  # Example: assign specific VM ID
  win25_base   = 0 # 1025  # Example: assign specific VM ID
  win25_runner = 0 # 2025  # Example: assign specific VM ID
}

# ISO files (ensure these exist in your Proxmox ISO storage)
virtio_win_iso = "virtio-win.iso"
