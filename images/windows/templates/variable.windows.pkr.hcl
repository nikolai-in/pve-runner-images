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
  default     = "256G"
}

variable "bridge" {
  type        = string
  description = "Network bridge name"
  default     = "vmbr0"
}

// Windows related variables

variable "license_keys" {
  type = object({
    win19 = string
    win22 = string
    win25 = string
  })
  description = "Windows license keys for different versions. Leave empty for evaluation versions."
  default = {
    win19 = ""
    win22 = ""
    win25 = ""
  }
  validation {
    condition = alltrue([
      for version, key in var.license_keys :
      key == "" || can(regex("^([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}$", key))
    ])
    error_message = "Each license key must be either empty for evaluation version or in the format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
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
variable "vm_ids" {
  type = object({
    win19_base   = number
    win19_runner = number
    win22_base   = number
    win22_runner = number
    win25_base   = number
    win25_runner = number
  })
  description = "VM IDs for templates. Set to 0 for auto-assignment by Proxmox. VMIDs must be unique cluster-wide and in range 100-999999999."
  default = {
    win19_base   = 0
    win19_runner = 0
    win22_base   = 0
    win22_runner = 0
    win25_base   = 0
    win25_runner = 0
  }
  validation {
    condition = alltrue([
      for vm_id in values(var.vm_ids) :
      vm_id == 0 || (vm_id >= 100 && vm_id <= 999999999)
    ])
    error_message = "VM IDs must be between 100 and 999999999, or 0 for auto-assignment."
  }
}

variable "image_os" {
  type    = string
  default = "win25"
  validation {
    condition     = contains(["win19", "win22", "win25"], var.image_os)
    error_message = "The image_os value must be one of: win19, win22, win25."
  }
}
variable "image_version" {
  type    = string
  default = "dev"
}
variable "imagedata_file" {
  type    = string
  default = "C:\\imagedata.json"
}
variable "install_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "install_user" {
  type        = string
  default     = "Administrator"
  description = "Username for logging into Windows during and after image build. Use 'Administrator' for the built-in admin account."
}
variable "temp_dir" {
  type    = string
  default = "D:\\temp"
}
