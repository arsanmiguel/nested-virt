# Lab firewall holes for nested-virt proof scripts (ICMP + WinRM from 10/8).
$ErrorActionPreference = 'SilentlyContinue'
netsh advfirewall firewall add rule name="NestedVirt-ICMP-In" protocol=icmpv4:8,any dir=in action=allow remoteip=10.0.0.0/8
netsh advfirewall firewall add rule name="NestedVirt-WinRM-In" protocol=tcp dir=in localport=5985 action=allow remoteip=10.0.0.0/8
netsh advfirewall firewall add rule name="NestedVirt-RDP-In" protocol=tcp dir=in localport=3389 action=allow remoteip=10.0.0.0/8
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
Set-Service WinRM -StartupType Automatic
