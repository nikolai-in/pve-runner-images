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

  image_properties_map = {
    "win19" = {
      windows_iso     = "en-us_windows_server_2019_eval_x64fre.iso"
      image_index     = "4"
      disk_size       = coalesce(var.disk_size_gb, "256G")
      base_template   = "win19-base"
      runner_template = "win19-runner"
      license_key     = var.license_keys.win19
      driver_paths = [
        for driver in local.driver_names : "${driver}\\${local.windows_driver_versions["win19"]}\\amd64"
      ]
    },
    "win22" = {
      windows_iso     = "en-us_windows_server_2022_eval_x64fre.iso"
      image_index     = "4"
      disk_size       = coalesce(var.disk_size_gb, "256G")
      base_template   = "win22-base"
      runner_template = "win22-runner"
      license_key     = var.license_keys.win22
      driver_paths = [
        for driver in local.driver_names : "${driver}\\${local.windows_driver_versions["win22"]}\\amd64"
      ]
    },
    "win25" = {
      windows_iso     = "en-us_windows_server_2025_eval_x64fre.iso"
      image_index     = "4"
      disk_size       = coalesce(var.disk_size_gb, "150G")
      base_template   = "win25-base"
      runner_template = "win25-runner"
      license_key     = var.license_keys.win25
      driver_paths = [
        for driver in local.driver_names : "${driver}\\${local.windows_driver_versions["win25"]}\\amd64"
      ]
    }
  }

  image_properties = local.image_properties_map[var.image_os]
}
