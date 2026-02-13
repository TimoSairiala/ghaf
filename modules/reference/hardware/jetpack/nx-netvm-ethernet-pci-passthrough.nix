# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.orin.nx;
  ethPciDevice = "0007:01:00.0";
  ethPciBridge = "0007:00:00.0";
  bindNetvmIommuGroup = ''
    ${pkgs.bash}/bin/bash -euo pipefail -c "
    TARGET_DEV=${ethPciDevice};
    TIMEOUT=60;

    ELAPSED=0;
    while [ ! -e /sys/bus/pci/devices/$TARGET_DEV/iommu_group ]; do
      if [ $ELAPSED -ge $TIMEOUT ]; then
        echo \"Timeout reached: IOMMU group for $TARGET_DEV did not appear after $TIMEOUT seconds.\";
        exit 1;
      fi;
      echo \"Waiting for IOMMU group for $TARGET_DEV... $ELAPSED/$TIMEOUT seconds\";
      sleep 1;
      ELAPSED=$((ELAPSED + 1));
    done;

    GROUP=$(readlink -f /sys/bus/pci/devices/$TARGET_DEV/iommu_group);
    if [ -z \"$GROUP\" ] || [ ! -d \"$GROUP/devices\" ]; then
      echo \"IOMMU group path not found for $TARGET_DEV.\";
      exit 1;
    fi;

    echo \"Binding all devices in IOMMU group: $GROUP\";
    ${pkgs.kmod}/bin/modprobe vfio-pci;

    for DEVPATH in \"$GROUP\"/devices/*; do
      DEV=$(basename \"$DEVPATH\");
      echo \"Binding $DEV to vfio-pci\";
      echo vfio-pci > /sys/bus/pci/devices/$DEV/driver_override;
      if [ -e /sys/bus/pci/devices/$DEV/driver/unbind ]; then
        echo $DEV > /sys/bus/pci/devices/$DEV/driver/unbind;
      fi;
      echo $DEV > /sys/bus/pci/drivers/vfio-pci/bind;
    done;
    "
  '';
in
{
  options.ghaf.hardware.nvidia.orin.nx.enableNetvmEthernetPCIPassthrough =
    lib.mkEnableOption "Ethernet card PCI passthrough to NetVM";
  config = lib.mkIf cfg.enableNetvmEthernetPCIPassthrough {
    # Orin NX Ethernet card PCI Passthrough
    ghaf.hardware.nvidia.orin.enablePCIPassthroughCommon = true;

    # Bind bridge+NIC early to prevent pcieport from claiming the root port
    boot.initrd.kernelModules = [
      "vfio_pci"
      "vfio_iommu_type1"
      "vfio"
    ];
    boot.initrd.systemd.storePaths = [
      pkgs.bash
      pkgs.coreutils
      pkgs.kmod
    ];
    boot.initrd.systemd.services.netvm-vfio-bind-initrd = {
      description = "Bind NetVM PCI devices to vfio-pci (initrd)";
      wantedBy = [ "initrd.target" ];
      before = [
        "sysroot.mount"
        "initrd-root-fs.target"
      ];
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -euo pipefail -c "
          DEVICES='${ethPciBridge} ${ethPciDevice}';
          TIMEOUT=60;
          log() { echo \"initrd-vfio: $1\" > /dev/kmsg; }
          for DEV in $DEVICES; do
            ELAPSED=0;
            while [ ! -e /sys/bus/pci/devices/$DEV ]; do
              if [ $ELAPSED -ge $TIMEOUT ]; then
                log \"timeout waiting for PCI device $DEV\";
                exit 1;
              fi;
              ${pkgs.coreutils}/bin/sleep 1;
              ELAPSED=$((ELAPSED + 1));
            done;
            CUR_DRV=$(readlink -f /sys/bus/pci/devices/$DEV/driver 2>/dev/null || true);
            log \"$DEV current driver: $CUR_DRV\";
            echo vfio-pci > /sys/bus/pci/devices/$DEV/driver_override;
            log \"$DEV driver_override set to vfio-pci\";
          done;
          ${pkgs.kmod}/bin/modprobe vfio-pci;
          for DEV in $DEVICES; do
            if [ -e /sys/bus/pci/devices/$DEV/driver/unbind ]; then
              echo $DEV > /sys/bus/pci/devices/$DEV/driver/unbind || log \"$DEV unbind failed\";
            fi;
            echo $DEV > /sys/bus/pci/drivers/vfio-pci/bind || log \"$DEV bind to vfio-pci failed\";
            CUR_DRV=$(readlink -f /sys/bus/pci/devices/$DEV/driver 2>/dev/null || true);
            log \"$DEV driver after bind: $CUR_DRV\";
          done;
          "
        '';
      };
    };

    # Bind the full IOMMU group to vfio-pci before NetVM starts
    systemd.services."netvm-vfio-bind" = {
      description = "Bind NetVM IOMMU group devices to vfio-pci";
      before = [ "microvm@net-vm.service" ];
      wantedBy = [ "microvm@net-vm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bindNetvmIommuGroup;
      };
    };

    ghaf.virtualization.microvm.netvm.extraModules = [
      {
        microvm.devices = [
          {
            bus = "pci";
            path = ethPciBridge;
          }
          {
            bus = "pci";
            path = ethPciDevice;
          }
        ];
      }
    ];

    hardware.deviceTree.overlays = [
      {
        name = "nx-ethernet-pci-passthough-overlay";
        dtsFile = ./nx-ethernet-pci-passthough-overlay.dts;
      }
    ];

    boot.kernelPatches = lib.mkIf (config.ghaf.hardware.nvidia.orin.kernelVersion == "upstream-6-6") [
      {
        name = "vfio-true";
        patch = ./0001-ARM-SMMU-drivers-return-always-true-for-IOMMU_CAP_CA.patch;
      }
    ];

    boot.kernelParams = [
      "vfio-pci.ids=10ec:8168"
      "vfio_iommu_type1.allow_unsafe_interrupts=1"
    ];
  };
}
