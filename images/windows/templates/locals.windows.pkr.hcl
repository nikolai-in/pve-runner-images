locals {
  image_properties_map = {
    "win19" = {
      windows_iso   = "en-us_windows_server_2019_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "256G")
      template_name = "win19-runner"
      license_key   = var.license_key != "" ? var.license_key : ""
    },
    "win22" = {
      windows_iso   = "en-us_windows_server_2022_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "256G")
      template_name = "win22-runner"
      license_key   = var.license_key != "" ? var.license_key : ""

    },
    "win25" = {
      windows_iso   = "en-us_windows_server_2025_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "150G")
      template_name = "win25-runner"
      license_key   = var.license_key != "" ? var.license_key : ""
    }
  }

  image_properties = local.image_properties_map[var.image_os]
}
