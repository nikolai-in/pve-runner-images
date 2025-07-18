locals {
  # Driver names that we want to include for Windows installation
  driver_names = [
    "Balloon",
    "NetKVM",
    "vioscsi",
    "viostor"
  ]

  # Windows version to driver path mapping
  windows_driver_versions = {
    "win19" = "2k19"
    "win22" = "2k22"
    "win25" = "2k25"
  }

  # Generate driver paths for the selected Windows version
  driver_paths = [
    for driver in local.driver_names : "${driver}\\${local.windows_driver_versions[var.image_os]}\\amd64"
  ]

  image_properties_map = {
    "win19" = {
      windows_iso   = "en-us_windows_server_2019_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "256G")
      template_name = "win19-runner"
      driver_paths  = local.driver_paths
    },
    "win22" = {
      windows_iso   = "en-us_windows_server_2022_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "256G")
      template_name = "win22-runner"
      driver_paths  = local.driver_paths
    },
    "win25" = {
      windows_iso   = "en-us_windows_server_2025_eval_x64fre.iso"
      image_index   = "4"
      disk_size     = coalesce(var.disk_size_gb, "150G")
      template_name = "win25-runner"
      driver_paths  = local.driver_paths
    }
  }

  image_properties = local.image_properties_map[var.image_os]
}
