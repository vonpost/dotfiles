{ microvm, pkgs, config, lib, ... }: {
# systemd.network = {
#   netdevs."10-microvm".netdevConfig = {
#     Kind = "bridge";
#     Name = "microvm";
#   };
#   networks."10-microvm" = {
#     matchConfig.Name = "microvm";
#     networkConfig = {
#       DHCPServer = true;
#       IPv6SendRA = true;
#     };
#     addresses = [ {
#       addressConfig.Address = "10.0.0.1/24";
#     } {
#       addressConfig.Address = "fd12:3456:789a::1/64";
#     } ];
#     ipv6Prefixes = [ {
#       ipv6PrefixConfig.Prefix = "fd12:3456:789a::/64";
#     } ];
#   };

#   networks."11-microvm" = {
#     matchConfig.Name = "vm-*";
#     # Attach to the bridge that was configured above
#     networkConfig.Bridge = "microvm";
#   };
# };


  microvm.vms = {
    wgvm = {
      config = {
        imports = [ ./wg_vpn_vm.nix ];
        networking.hostName = "wgvm";
        microvm.interfaces = [
          {
            type = "tap";
            id = "vm-wg";
            mac = "02:00:00:00:00:02";
          }
        ];

        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
                         {
          source = "/root/wgkeys";
          mountPoint = "/wgkeys";
          tag = "wgkeys";
          proto = "virtiofs";
        }];


        services.openssh.enable = true;
        users.users.root.openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDDEZ9icK0NH4zNG+pY4PXWJHrcp18ADSXoYKIYPGYvDSYYRL5Y5QfiscTPAZec+U8cipR48BEWZ8j3c4xTb3ZrnqtJTN5WdnqAVAcez+RvUx4mzYxDxRtfHbdTiwLEJpcMRHbVOvQZWiQIdxiKTF8RQj1Ol3NPe4IFGbRCvOGvUin9PByRKgLqrG5a8EUHPetWmZbtgtQGuyNE6X4f2uvFVWEKXJWSAdQI/U0QQECRzBEptCcJ43S9yPymqIEOfb2/jB2DfwK0zeXuMQ9iB80vvg1CFV0Wf6EuWJU+I6qdXkOSDezeiFU3fdZu62HqIuGW+G0eaZ/C96L5+7VAgSbtopXwl4hnIe4X4npkTKOOcAqfKI+xOodR6Sknv6LStEOguIpbQSHPs3Jf7vsv0v+c9L0pD+l5MbJS0OomnMMp2nOwrcOHuIMPFAyQV+QwYZG/hRwrB1k4RgLp16GyWjaS+/mhiSbzDRmsn10sM5n/rtDgT5Fr3Z1KunrLCT2exRc= daniel.j.collin@gmail.com"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDPrfcUxvSt9pW9/0gp0hJTf4+Mh6u8VSQnLa2N9EHl3vwM1fIUK/LHFzlVtZJbfnEaquguRnk9pxSw7KK+05zt6IdRR1PYF4C7oLTaA75/rm/9sxBvM9KAqcyxfH/63nCxV26CUJK8v6xO+6tBXFPYoKDsbwOenNgAPSxV/gLwPzHta/D8AOFP4d6h4bJqA4fCKn1YSKLG9vEVsfD28U7f4P7WjFyoZsoEX+Ske+LXYI0JHjBum2jMBf9mN+GoX17KsL8xk5kbKsVFt0KMuCQ4apXD6+8sziQ4Uf4SgL0OhiqvmBeSHddfRjOJ6+15OvzZYyYYdpYgXr2h0hpo5gGUKe3PPC81CvvHfObS0yl7l3JIsfb+krK5gPP471wGthft5+b+uuSdpnok7o1Q1L4bOdGyLhNl3PkGh2m6h0Lqb1MJRClUwkZ9DDkY0L7qabANlJRV7jrmCMCsxyLtHCoIEBS+tapaNtHB0LiJowzqJ5VuXP7DkpQmikuy5G8ETHftlQyXDYxZrzIixGo1Je/Y4M3YyLtW0GFKN16/MkD2bOX/ynis7zRwGtLoy59cLYOMRi6OEc8aQq+mC+FTk9bHdKEOMbhjNnlCznxSChyA8pbp1L7iuh9+DeQ0k+NiJsJfX6ytG3WLA+gS7e/U4XmvXbBuv5WQWosti3mlMeRz5w== dcol@kth.se"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCqP5gmRy2ZkjMw9yg+swbkNWiIH3gPdiXXQOv3TtKac9UPdmrhM4j7e+siExIygVHrk0d4aZSg89SXClmLHG0/+h8jEx9ovkpv3PlWz/nQl11+LAdqy5C14l8+DfYPdH9qlkZ5vbFEna153Ma08vuHsxZxcCd9TAKTZJeBG4A5lvaZnPNB8CNkMKVoWfIm7dViyOsd2tgz5TYeT4gzsO7cSgj7/8dxfAV0bwnPNwETjDN0fN9jUOUKBvOVkoOVPBU083xj5FqHq8l9Ol8FzaVJGH3+8WrXQNHonWtxAKthHBOBroOgj093OeCya8Wh4A/qDCeDsgoZAMTvxci1T6jJ root@MOTHER"
        ];

      microvm.writableStoreOverlay = "/nix/.rw-store";

      };
    };

    my-microvm = {
      # The package set to use for the microvm. This also determines the microvm's architecture.
      # Defaults to the host system's package set if not given.
      # pkgs = import nixpkgs { system = "x86_64-linux"; };

      # (Optional) A set of special arguments to be passed to the MicroVM's NixOS modules.
      #specialArgs = {};

      # The configuration for the MicroVM.
      # Multiple definitions will be merged as expected.
      config = {
        imports = [./desktop_template.nix ./kde.nix];
        microvm.qemu.extraArgs = [
          "-device" "ich9-intel-hda"
          "-audiodev" "none,id=foo"
        ];

        microvm.qemu.bios.enable = false;
        # microvm.qemu.bios.path = "${pkgs.seabios}/Csm16.bin";
        # microvm.qemu.bios.path = "/run/libvirt/nix-ovmf/OVMF.fd";
# boot.blacklistedKernelModules = lib.mkForce [ "rfkill" "intel_pstate" ];
boot.kernelModules = ["drm"];

        networking.hostName = "my-microvm";
        networking.firewall.enable = false;
        # It is highly recommended to share the host's nix-store
        # with the VMs to prevent building huge images.
        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
                          {
          source = "/theta";
          mountPoint = "/theta";
          tag = "theta";
          proto = "virtiofs";
        }

                          {
          source = "/aleph";
          mountPoint = "/aleph";
          tag = "aleph";
          proto = "virtiofs";
        }

                         ];

        services.openssh.enable = true;
        users.users.root.openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDDEZ9icK0NH4zNG+pY4PXWJHrcp18ADSXoYKIYPGYvDSYYRL5Y5QfiscTPAZec+U8cipR48BEWZ8j3c4xTb3ZrnqtJTN5WdnqAVAcez+RvUx4mzYxDxRtfHbdTiwLEJpcMRHbVOvQZWiQIdxiKTF8RQj1Ol3NPe4IFGbRCvOGvUin9PByRKgLqrG5a8EUHPetWmZbtgtQGuyNE6X4f2uvFVWEKXJWSAdQI/U0QQECRzBEptCcJ43S9yPymqIEOfb2/jB2DfwK0zeXuMQ9iB80vvg1CFV0Wf6EuWJU+I6qdXkOSDezeiFU3fdZu62HqIuGW+G0eaZ/C96L5+7VAgSbtopXwl4hnIe4X4npkTKOOcAqfKI+xOodR6Sknv6LStEOguIpbQSHPs3Jf7vsv0v+c9L0pD+l5MbJS0OomnMMp2nOwrcOHuIMPFAyQV+QwYZG/hRwrB1k4RgLp16GyWjaS+/mhiSbzDRmsn10sM5n/rtDgT5Fr3Z1KunrLCT2exRc= daniel.j.collin@gmail.com"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDPrfcUxvSt9pW9/0gp0hJTf4+Mh6u8VSQnLa2N9EHl3vwM1fIUK/LHFzlVtZJbfnEaquguRnk9pxSw7KK+05zt6IdRR1PYF4C7oLTaA75/rm/9sxBvM9KAqcyxfH/63nCxV26CUJK8v6xO+6tBXFPYoKDsbwOenNgAPSxV/gLwPzHta/D8AOFP4d6h4bJqA4fCKn1YSKLG9vEVsfD28U7f4P7WjFyoZsoEX+Ske+LXYI0JHjBum2jMBf9mN+GoX17KsL8xk5kbKsVFt0KMuCQ4apXD6+8sziQ4Uf4SgL0OhiqvmBeSHddfRjOJ6+15OvzZYyYYdpYgXr2h0hpo5gGUKe3PPC81CvvHfObS0yl7l3JIsfb+krK5gPP471wGthft5+b+uuSdpnok7o1Q1L4bOdGyLhNl3PkGh2m6h0Lqb1MJRClUwkZ9DDkY0L7qabANlJRV7jrmCMCsxyLtHCoIEBS+tapaNtHB0LiJowzqJ5VuXP7DkpQmikuy5G8ETHftlQyXDYxZrzIixGo1Je/Y4M3YyLtW0GFKN16/MkD2bOX/ynis7zRwGtLoy59cLYOMRi6OEc8aQq+mC+FTk9bHdKEOMbhjNnlCznxSChyA8pbp1L7iuh9+DeQ0k+NiJsJfX6ytG3WLA+gS7e/U4XmvXbBuv5WQWosti3mlMeRz5w== dcol@kth.se"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCqP5gmRy2ZkjMw9yg+swbkNWiIH3gPdiXXQOv3TtKac9UPdmrhM4j7e+siExIygVHrk0d4aZSg89SXClmLHG0/+h8jEx9ovkpv3PlWz/nQl11+LAdqy5C14l8+DfYPdH9qlkZ5vbFEna153Ma08vuHsxZxcCd9TAKTZJeBG4A5lvaZnPNB8CNkMKVoWfIm7dViyOsd2tgz5TYeT4gzsO7cSgj7/8dxfAV0bwnPNwETjDN0fN9jUOUKBvOVkoOVPBU083xj5FqHq8l9Ol8FzaVJGH3+8WrXQNHonWtxAKthHBOBroOgj093OeCya8Wh4A/qDCeDsgoZAMTvxci1T6jJ root@MOTHER"
        ];
        microvm.interfaces = [
          {
            type = "tap";
            id = "vm-gaming";
            mac = "02:00:00:00:00:01";
          }
        ];

        microvm.vcpu = 2;
        microvm.mem = 2000;
        microvm.devices = [
          {
            bus = "pci";
            path = "0000:09:00.0";
          }
          {
            bus = "pci";
            path = "0000:09:00.1";
          }
        ];

        # This is necessary to import the host's nix-store database
        microvm.writableStoreOverlay = "/nix/.rw-store";
        microvm.volumes = [
          {
          image = "/aleph/microvm_volumes/gaming-nix-store-overlay.img";
          mountPoint = "/nix/.rw-store";
          size = 2048;
          }

          {
          image = "/aleph/microvm_volumes/gaming-persist.img";
          mountPoint = "/persist";
          size = 204800;
          }
        ];


        # Any other configuration for your MicroVM
        #...
      };
    };
  };
}
