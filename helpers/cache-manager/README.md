# Runner cache manager

This is a convenience script for downloading software ahead of the image build process, thus shortening the build time and warning about software unavailability (e.g. your network is blocking or has been blocked by file host).

## Usage

```bash
uv run cache-manager.py --help
```

Or whatever you want that supports [inline metadata](https://packaging.python.org/en/latest/specifications/inline-script-metadata/#inline-script-metadata).

## Why python?

1. I hate powershell.
2. I don't want to learn powershell.
3. Bash scripting is not my cup of tea for complex tasks.

## How does it work?

Currently WIP
Firstly it checks for a tool sources file composed from latest software reports JSONs from [runner images releases](https://github.com/actions/runner-images/releases). If the file is not present, it will download JSONs and scaffold a sources file which you can edit. If sources file is present you can run the script with `update` flag to update it according to latest software reports. When you are content with sources file, you can run the script with `download` flag to download all software listed in the sources file. The script will also check if the software is already downloaded and skip it if it is. After running the download command it will print a summary of downloaded software and their versions. You can generate a detailed report on sources or downloaded files in markdown format with `report` flag.

<!--
  /\__/\
 ( '~'  )
-->
