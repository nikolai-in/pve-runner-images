build {
  name = "base"

  sources = [
    "source.proxmox-iso.base",
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
    script = "${path.root}/../scripts/build/Install-CloudBase.ps1"
  }

  provisioner "file" {
    source      = "${path.root}/../assets/base/config/"
    destination = "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/conf"
  }

  provisioner "powershell" {
    inline = [
      "Set-Service cloudbase-init -StartupType Manual",
      "Stop-Service cloudbase-init -Force -Confirm:$false"
    ]
  }
}
