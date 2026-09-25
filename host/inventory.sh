#!/usr/bin/env bash
# Read-only hardware and storage inventory for planning the homelab rebuild.
# Run as root on the spare PC. Works on Unraid, Debian, or a live USB.
# Nothing on the machine is changed. The report is saved to
# /boot/homelab-inventory.txt on Unraid (the flash drive), or
# ./homelab-inventory.txt elsewhere. Pass a path to save it somewhere else.

set -u

if [ -f /etc/unraid-version ] && [ -d /boot/config ]; then
  out=/boot/homelab-inventory.txt
else
  out=./homelab-inventory.txt
fi
out="${1:-$out}"

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }

# Whole physical disks only: no loop, cdrom, zram, md or nbd devices.
physical_disks() {
  lsblk -dn -e 7,11 -o NAME,TYPE 2>/dev/null |
    awk '$2 == "disk" && $1 !~ /^(zram|md|nbd)/ { print $1 }'
}

report() {
  section "System"
  date
  [ -f /etc/unraid-version ] && cat /etc/unraid-version
  [ -f /etc/os-release ] && grep -E '^PRETTY_NAME=' /etc/os-release
  echo "kernel $(uname -r)"
  if have dmidecode; then
    echo "board: $(dmidecode -s baseboard-manufacturer 2>/dev/null) $(dmidecode -s baseboard-product-name 2>/dev/null)"
  fi

  section "CPU"
  if have lscpu; then
    lscpu | grep -E '^(Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|CPU max MHz)'
  else
    grep -m1 'model name' /proc/cpuinfo
  fi

  section "Memory"
  free -h
  if have dmidecode; then
    dmidecode -t memory 2>/dev/null |
      grep -E 'Maximum Capacity|Number Of Devices|^[[:space:]]+(Size|Type|Speed):'
  fi

  section "GPU (hardware transcoding)"
  if have lspci; then
    lspci -nn | grep -Ei 'vga|3d controller|display' || echo "no GPU found by lspci"
  else
    echo "lspci not installed"
  fi
  if [ -d /dev/dri ]; then
    ls -l /dev/dri
  else
    echo "/dev/dri missing: no GPU driver loaded (normal on Unraid until i915 is loaded; the lspci line above is what matters)"
  fi

  section "Network links"
  for nic in /sys/class/net/*; do
    name=${nic##*/}
    case $name in lo|docker*|veth*|br*|virbr*|vnet*|shim*|bond*|wg*|vhost*|ifb*|tun*) continue ;; esac
    echo "$name: $(cat "$nic/speed" 2>/dev/null || echo '?') Mb/s"
  done

  section "Disks"
  lsblk -d -e 7,11 -o NAME,SIZE,ROTA,TRAN,MODEL,SERIAL 2>/dev/null ||
    lsblk -d -e 7,11 -o NAME,SIZE,ROTA,MODEL

  section "Partitions and filesystems"
  lsblk -e 7,11 -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT

  section "Disk health (SMART)"
  if have smartctl; then
    for dev in $(physical_disks); do
      echo "--- /dev/$dev"
      smartctl -H -i "/dev/$dev" 2>/dev/null |
        grep -E 'Device Model|Model Number|User Capacity|Total NVM Capacity|Rotation Rate|overall-health|SMART Health Status'
      smartctl -A "/dev/$dev" 2>/dev/null |
        grep -E 'Power_On_Hours|Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Percentage Used|Media and Data Integrity Errors|Power On Hours'
    done
  else
    echo "smartctl not installed"
  fi

  section "Unraid array layout"
  if [ -f /var/local/emhttp/disks.ini ]; then
    # Print only the slots that have a disk assigned.
    awk -F= '
      /^\[/ { if (dev != "") print block; block = $0; dev = ""; next }
      $1 == "device" { d = $2; gsub(/"/, "", d); dev = d }
      $1 ~ /^(type|device|id|size|fsType|fsSize|fsUsed|fsFree|status|luksState)$/ { block = block "\n  " $0 }
      END { if (dev != "") print block }
    ' /var/local/emhttp/disks.ini
  else
    echo "not Unraid, or the array isn't started"
  fi

  section "Space used"
  df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || df -h

  if [ -d /mnt/user ]; then
    section "Unraid share sizes"
    du -sh /mnt/user/*/ 2>/dev/null
  fi

  section "Docker containers"
  if have docker && docker info >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
  else
    echo "Docker not running"
  fi

  section "Virtual machines"
  if have virsh; then
    virsh list --all 2>/dev/null || echo "libvirt not running"
  else
    echo "no libvirt"
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Not running as root: disk health and board details will be missing." >&2
fi
echo "Collecting inventory (share sizes can take a minute)..." >&2
report 2>&1 | tee "$out"
echo >&2
echo "Saved to $out" >&2
