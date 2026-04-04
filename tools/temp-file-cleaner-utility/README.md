# Temp File Cleaner Utility

A modern Windows cleanup utility with a simple GUI, scan mode, and safe cleanup presets.

This tool is designed to be easy to use, transparent, and safe to share with others.

## Features

* Clean, simple GUI
* Scan mode to preview results before deleting anything
* Multiple cleanup presets:

  * Safe
  * Standard
  * Aggressive
* Summary dashboard:

  * Files and folders processed
  * Items deleted
  * Locked and skipped items
  * Estimated space reclaimed
* Detailed log output
* Exportable summary reports

## Cleanup Presets

### Safe

* System temp files
* User temp files
* Recycle Bin

Best for routine cleanup with minimal risk.

### Standard

* Everything in Safe
* Browser caches
* Printer spool temp

Recommended default.

### Aggressive

Includes everything in Standard plus:

* Prefetch
* Windows Event Logs
* Shadow Copies / Restore Points

Use with caution:

* Event logs may be needed for troubleshooting
* Shadow copies can be valuable rollback points

## How to Run

1. Open the tool folder
2. Double-click `Run Temp File Cleaner Utility.bat`
3. Accept the administrator prompt if prompted

## Typical Workflow

1. Click **Scan**
2. Review the summary
3. Click **Run Cleanup**
4. Confirm your selection
5. Review the completion summary

## Notes

* Some files may be locked by the system and cannot be removed
* Skipped or locked items are normal
* Some paths may not exist on every system

## Credit

This utility was inspired by legacy cleanup concepts popularized by Hiren’s utility collection, but it is a separate modern PowerShell GUI implementation.

## Disclaimer

Use at your own risk. Review selections carefully before running cleanup, especially when using aggressive options.
