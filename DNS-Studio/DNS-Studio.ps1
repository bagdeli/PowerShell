#requires -Version 5.1
<#
 DNS Studio v1.1 - Windows 11 / Windows PowerShell 5.1
 The data file is stored alongside the INSTALLED script in Program Files.
 No passwords or Wi-Fi credentials are accessed or stored.
 The optional background watcher runs as the same logged-on user, elevated,
 from the protected installation directory (never from a user-writable ZIP).
#>
[CmdletBinding()]
param([switch]$Agent)

$ErrorActionPreference = 'Stop'
$script:SourcePath = $PSCommandPath
$script:InstallDir = Join-Path $env:ProgramFiles 'DNS Studio'
$script:InstallPath = Join-Path $script:InstallDir 'DNS-Studio.ps1'
$script:DataPath = Join-Path $script:InstallDir 'dns-profiles.json'
$script:BackupPath = Join-Path $script:InstallDir 'dns-profiles.backup.json'
$script:LogPath = Join-Path $script:InstallDir 'dns-studio.log'
$script:TaskName = 'DNS Studio - Network Watcher'
$script:PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Restart-AsAdmin {
    $argsText = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:SourcePath
    if ($Agent) { $argsText += ' -Agent' }
    Start-Process -FilePath $script:PsExe -ArgumentList $argsText -Verb RunAs | Out-Null
}
function Create-DesktopShortcut {
    try {
        $desktop = [Environment]::GetFolderPath('DesktopDirectory')
        if (-not (Test-Path -LiteralPath $desktop)) { return }
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $desktop 'DNS Studio.lnk'))
        $link.TargetPath = $script:PsExe
        $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:InstallPath
        $link.WorkingDirectory = $script:InstallDir
        $link.IconLocation = "$env:SystemRoot\System32\imageres.dll,109"
        $link.Description = 'DNS Studio - switch DNS by connected Wi-Fi/Ethernet network'
        $link.Save()
    } catch { }
}
if (-not (Test-Administrator)) {
    if ($Agent) { exit 2 }
    try { Restart-AsAdmin } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('برای تغییر DNS، دسترسی Administrator لازم است.', 'DNS Studio') | Out-Null
    }
    exit
}
if (-not $Agent -and -not [string]::Equals([IO.Path]::GetFullPath($script:SourcePath), [IO.Path]::GetFullPath($script:InstallPath), [StringComparison]::OrdinalIgnoreCase)) {
    try {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Copy-Item -LiteralPath $script:SourcePath -Destination $script:InstallPath -Force
        # If an existing portable data file was brought along, import it only on first installation.
        $portableData = Join-Path (Split-Path -Parent $script:SourcePath) 'dns-profiles.json'
        if (-not (Test-Path -LiteralPath $script:DataPath) -and (Test-Path -LiteralPath $portableData)) {
            Copy-Item -LiteralPath $portableData -Destination $script:DataPath
        }
        Create-DesktopShortcut
        Start-Process -FilePath $script:PsExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:InstallPath) | Out-Null
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("نصب انجام نشد:`r`n$($_.Exception.Message)", 'DNS Studio') | Out-Null
    }
    exit
}
if ($Agent -and -not [string]::Equals([IO.Path]::GetFullPath($script:SourcePath), [IO.Path]::GetFullPath($script:InstallPath), [StringComparison]::OrdinalIgnoreCase)) { exit 3 }

# Native Windows WLAN API: locale-independent Wi-Fi adapter/SSID/profile detection.
# Unlike parsing 'netsh wlan' text, this also works on non-English Windows installs.
try {
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class WifiInfo {
    public Guid Guid;
    public string Ssid;
    public string Profile;
}
public static class NativeNetworks {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct WLAN_INTERFACE_INFO {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)]
        public string strInterfaceDescription;
        public int isState;
    }
    [DllImport("wlanapi.dll")]
    private static extern int WlanOpenHandle(uint dwClientVersion, IntPtr pReserved,
        out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
    [DllImport("wlanapi.dll")]
    private static extern int WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
    [DllImport("wlanapi.dll")]
    private static extern int WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);
    [DllImport("wlanapi.dll")]
    private static extern int WlanQueryInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid,
        int OpCode, IntPtr pReserved, out uint pdwDataSize, out IntPtr ppData, out int pWlanOpcodeValueType);
    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr pMemory);

    public static List<WifiInfo> GetConnectedWifi() {
        var result = new List<WifiInfo>();
        uint version;
        IntPtr handle = IntPtr.Zero, list = IntPtr.Zero;
        if (WlanOpenHandle(2, IntPtr.Zero, out version, out handle) != 0) return result;
        try {
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out list) != 0 || list == IntPtr.Zero) return result;
            int count = Marshal.ReadInt32(list, 0);
            int size = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));
            for (int i = 0; i < count && i < 64; i++) {
                var p = IntPtr.Add(list, 8 + i * size);
                var info = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(p, typeof(WLAN_INTERFACE_INFO));
                if (info.isState != 1) continue;  // wlan_interface_state_connected
                Guid id = info.InterfaceGuid;
                uint cb; int opType; IntPtr connection = IntPtr.Zero;
                if (WlanQueryInterface(handle, ref id, 7, IntPtr.Zero, out cb, out connection, out opType) != 0)
                    continue; // 7 = wlan_intf_opcode_current_connection
                try {
                    if (connection == IntPtr.Zero || cb < 556 || Marshal.ReadInt32(connection,0) != 1) continue;
                    // WLAN_CONNECTION_ATTRIBUTES: two DWORDs, then wchar_t profile[256], then DOT11_SSID.
                    string profile = Marshal.PtrToStringUni(IntPtr.Add(connection,8),256).TrimEnd('\0');
                    int n = Marshal.ReadInt32(connection,520);
                    if (n <= 0 || n > 32) continue;
                    byte[] ssid = new byte[n];
                    Marshal.Copy(IntPtr.Add(connection,524), ssid,0,n);
                    string name;
                    try { name = new UTF8Encoding(false,true).GetString(ssid); }
                    catch (DecoderFallbackException) { name = Encoding.Default.GetString(ssid); }
                    result.Add(new WifiInfo { Guid=id, Ssid=name, Profile=string.IsNullOrEmpty(profile) ? name : profile });
                } finally { if (connection != IntPtr.Zero) WlanFreeMemory(connection); }
            }
        } finally {
            if (list != IntPtr.Zero) WlanFreeMemory(list);
            WlanCloseHandle(handle, IntPtr.Zero);
        }
        return result;
    }
}

[StructLayout(LayoutKind.Sequential)]
public struct DnsSettingsV1 {
    public uint Version;
    public ulong Flags;
    public IntPtr Domain;
    public IntPtr NameServer;
    public IntPtr SearchList;
    public uint RegistrationEnabled;
    public uint RegisterAdapterName;
    public uint EnableLLMNR;
    public uint QueryAdapterName;
    public IntPtr ProfileNameServer;
}
public static class NativeDns {
    [DllImport("iphlpapi.dll", EntryPoint="GetInterfaceDnsSettings")]
    private static extern uint GetDns(Guid id, ref DnsSettingsV1 settings);
    [DllImport("iphlpapi.dll", EntryPoint="FreeInterfaceDnsSettings")]
    private static extern void FreeDns(ref DnsSettingsV1 settings);
    [DllImport("iphlpapi.dll", EntryPoint="SetInterfaceDnsSettings")]
    private static extern uint SetDns(Guid id, ref DnsSettingsV1 settings);
    public static string[] ReadIpv4Static(Guid id) {
        var s = new DnsSettingsV1(); s.Version=1;
        uint code = GetDns(id, ref s);
        if (code != 0) throw new System.ComponentModel.Win32Exception((int)code);
        try {
            return new string[] {
                s.NameServer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(s.NameServer),
                s.ProfileNameServer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(s.ProfileNameServer)
            };
        } finally { FreeDns(ref s); }
    }
    public static void SetProfile(Guid id, bool ipv6, string servers) {
        var s = new DnsSettingsV1(); s.Version=1;
        s.Flags = (ulong)(0x200 | (ipv6 ? 1 : 0)); // DNS_SETTING_PROFILE_NAMESERVER [+ IPV6]
        s.ProfileNameServer = Marshal.StringToHGlobalUni(servers ?? "");
        try {
            uint code = SetDns(id,ref s);
            if (code != 0) throw new System.ComponentModel.Win32Exception((int)code);
        } finally { Marshal.FreeHGlobal(s.ProfileNameServer); }
    }
}
'@
Add-Type -TypeDefinition $nativeSource -Language CSharp
} catch {
    try {
        [IO.File]::AppendAllText($script:LogPath, "Native API initialization: " + $_.Exception.ToString() + [Environment]::NewLine)
        if (-not $Agent) {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show("خطا هنگام شروع برنامه:`r`n" + $_.Exception.Message + "`r`nگزارش: " + $script:LogPath, 'DNS Studio') | Out-Null
        }
    } catch { }
    exit 5
}

function Write-Log([string]$message) {
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1048576) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value (('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$message))
    } catch { }
}
function New-EmptyStore {
    return @{ version=1; profiles=[System.Collections.ArrayList]::new(); networks=[System.Collections.ArrayList]::new(); lastManaged=@{}; autoEnabled=$false }
}
function Load-Store {
    $script:db = New-EmptyStore
    if (-not (Test-Path -LiteralPath $script:DataPath)) { return }
    $raw = [IO.File]::ReadAllText($script:DataPath, [Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$obj.version -ne 1) { throw 'فرمت فایل اطلاعات پشتیبانی نمی‌شود.' }
    foreach ($p in @($obj.profiles)) { if ($null -ne $p) { [void]$script:db.profiles.Add($p) } }
    foreach ($n in @($obj.networks)) { if ($null -ne $n) { [void]$script:db.networks.Add($n) } }
    if ($null -ne $obj.lastManaged) {
        foreach ($prop in $obj.lastManaged.PSObject.Properties) { $script:db.lastManaged[$prop.Name] = [string]$prop.Value }
    }
    $script:db.autoEnabled = [bool]$obj.autoEnabled
}
function Save-Store {
    $serial = ConvertTo-Json -InputObject $script:db -Depth 12
    $tmp = Join-Path $script:InstallDir ('dns-profiles.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tmp, $serial, (New-Object Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $script:DataPath) {
            [IO.File]::Replace($tmp, $script:DataPath, $script:BackupPath, $true)
        } else { [IO.File]::Move($tmp, $script:DataPath) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}
function Get-Record([string]$key) {
    return @($script:db.networks | Where-Object { $_.key -ceq $key } | Select-Object -First 1)[0]
}
function Get-Profile([string]$id) {
    return @($script:db.profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1)[0]
}
function Get-ConnectedNetworks {
    # Do not filter to -Physical: on some Windows drivers that switch drops the
    # connected Wi-Fi device entirely. Get-NetAdapter (all visible) is the base.
    # WLAN API identifies SSID; NLA is the fallback if WLAN API cannot report it.
    $warnings = New-Object System.Collections.ArrayList
    $wireless = @{}
    try {
        foreach ($w in @([NativeNetworks]::GetConnectedWifi())) {
            $wireless[$w.Guid.ToString('D').ToLowerInvariant()] = $w
        }
    } catch { [void]$warnings.Add('WLAN API: ' + $_.Exception.Message) }

    $profiles = @{}
    try {
        foreach ($p in @(Get-NetConnectionProfile -ErrorAction Stop)) {
            $profiles[[int]$p.InterfaceIndex] = $p
        }
    } catch { [void]$warnings.Add('Network Connection Profiles: ' + $_.Exception.Message) }

    $physical = @{}
    try {
        foreach ($p in @(Get-NetAdapter -Physical -ErrorAction Stop)) {
            try { $physical[([guid]$p.InterfaceGuid).ToString('D').ToLowerInvariant()] = $true } catch { }
        }
    } catch { [void]$warnings.Add('Physical adapter lookup: ' + $_.Exception.Message) }

    $adapters = @()
    try { $adapters = @(Get-NetAdapter -ErrorAction Stop) }
    catch { [void]$warnings.Add('Get-NetAdapter: ' + $_.Exception.Message) }

    # Windows includes CIM even if the NetAdapter PowerShell module is broken.
    if ($adapters.Count -eq 0) {
        try {
            foreach ($c in @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop |
                Where-Object { $_.NetConnectionStatus -eq 2 -and $_.GUID -and $_.InterfaceIndex })) {
                $alias = if ($c.NetConnectionID) { [string]$c.NetConnectionID } else { [string]$c.Name }
                $adapters += [pscustomobject]@{
                    Name = $alias; InterfaceDescription = [string]$c.Name
                    InterfaceGuid = [string]$c.GUID; ifIndex = [int]$c.InterfaceIndex
                    Status = 'Up'; NdisPhysicalMedium = ''; PhysicalMediaType = ''
                    HardwareInterface = [bool]$c.PhysicalAdapter
                }
            }
        } catch { [void]$warnings.Add('CIM fallback: ' + $_.Exception.Message) }
    }

    $up = @($adapters | Where-Object { [string]$_.Status -in @('Up','Connected') })
    $found = New-Object System.Collections.ArrayList
    foreach ($a in $up) {
        try {
            $guid = ([guid]$a.InterfaceGuid).ToString('D').ToLowerInvariant()
            $index = [int]$a.ifIndex
            if (-not $guid -or $index -le 0) { continue }
            $hasWlan = $wireless.ContainsKey($guid)
            $identityText = (@([string]$a.Name,[string]$a.InterfaceDescription,
                [string]$a.NdisPhysicalMedium,[string]$a.PhysicalMediaType) -join ' ')
            $isWifi = $hasWlan -or ($identityText -match '(?i)802[._ ]?11|native802_11|wireless|wi[- ]?fi|wlan')
            $isVirtual = $identityText -match '(?i)vEthernet|Hyper-V|VirtualBox|VMware|Wi-Fi Direct|WAN Miniport|loopback|Tailscale|WireGuard|ZeroTier|VPN|TAP-Windows|bluetooth'
            $isHardware = $physical.ContainsKey($guid) -or ([string]$a.HardwareInterface -eq 'True')
            if ($isVirtual -and -not $hasWlan -and -not $isHardware) { continue }
            if (-not $isWifi -and -not $isHardware -and
                -not $profiles.ContainsKey($index)) { continue }

            $net = if ($profiles.ContainsKey($index)) { $profiles[$index] } else { $null }
            $profileName = if ($null -ne $net) { [string]$net.Name } else { '' }
            $adapterName = [string]$a.Name
            if ($isWifi) {
                $source = 'WLAN API'
                if ($hasWlan) {
                    $w = $wireless[$guid]
                    $ssid = [string]$w.Ssid
                    $savedName = [string]$w.Profile
                } else {
                    # NLA's Name usually is the SSID. Show the fallback explicitly.
                    $ssid = $profileName
                    $savedName = $ssid
                    $source = 'Windows connection profile'
                }
                if ($ssid) {
                    $key = 'wifi|{0}|{1}|{2}' -f $guid,$savedName,$ssid
                    $label = 'Wi-Fi: {0}   [{1}]' -f $ssid,$adapterName
                    if (-not $hasWlan) { $label += '   (جایگزین)' }
                    $canApply = $true
                } else {
                    $key = 'wifi|{0}|unidentified' -f $guid
                    $label = 'Wi-Fi: نام شبکه شناسایی نشد   [{0}]' -f $adapterName
                    $canApply = $false
                    [void]$warnings.Add("Missing Wi-Fi SSID / NLA profile on adapter '$adapterName'")
                }
                [void]$found.Add([pscustomobject]@{
                    Key=$key; Label=$label; Kind='Wi-Fi'; Name=$ssid
                    Adapter=$adapterName; Guid=$guid; Index=$index
                    CanApply=$canApply; Source=$source
                })
            } else {
                # NLA name + gateway + NIC is the best practical Ethernet key.
                $gateway = ''
                try {
                    $route = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop |
                        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' } |
                        Sort-Object RouteMetric | Select-Object -First 1)
                    if ($route.Count -gt 0) { $gateway = [string]$route[0].NextHop }
                } catch { [void]$warnings.Add("Gateway lookup for '$adapterName': " + $_.Exception.Message) }
                $name = if ($profileName) { $profileName } elseif ($gateway) { $gateway } else { $adapterName }
                $key = 'ethernet|{0}|{1}|{2}' -f $guid,$profileName,$gateway
                $canApply = [bool]($profileName -or $gateway)
                $label = 'Ethernet: {0}   [{1}]' -f $name,$adapterName
                if (-not $canApply) { $label += '   (شبکه نامشخص)' }
                [void]$found.Add([pscustomobject]@{
                    Key=$key; Label=$label; Kind='Ethernet'; Name=$name
                    Adapter=$adapterName; Guid=$guid; Index=$index
                    CanApply=$canApply; Source='Windows connection profile / gateway'
                })
            }
        } catch { [void]$warnings.Add("Adapter '$($a.Name)': " + $_.Exception.Message) }
    }
    $script:LastScan = [pscustomobject]@{
        AdapterCount = $adapters.Count; ActiveCount = $up.Count
        PhysicalCount = $physical.Count; NlaCount = $profiles.Count
        NativeWifiCount = $wireless.Count; ResultCount = $found.Count
        Warnings = @($warnings.ToArray())
    }
    if ($found.Count -eq 0 -and -not $Agent) {
        Write-Log ('Discovery returned no networks. AdapterCount={0}, Up={1}, Physical={2}, WLAN={3}, NLA={4}; {5}' -f
            $adapters.Count,$up.Count,$physical.Count,$wireless.Count,$profiles.Count,($warnings -join ' | '))
    }
    return @($found | Sort-Object @{Expression={ if ($_.Kind -eq 'Wi-Fi') {0} else {1} }},Label)
}

function Get-NetworkDiagnostics {
    # No saved passwords, SSID keys, or router admin secrets are ever queried.
    $report = New-Object System.Text.StringBuilder
    [void]$report.AppendLine('DNS Studio 1.1 - Network discovery report')
    [void]$report.AppendLine(('Time: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$report.AppendLine('Contains network names, adapter identifiers and local gateway data; review before sharing.')
    if ($script:LastScan) {
        [void]$report.AppendLine(('Last scan: Adapters={0}, Up={1}, Physical={2}, WLAN={3}, NLA={4}, Results={5}' -f
            $script:LastScan.AdapterCount,$script:LastScan.ActiveCount,$script:LastScan.PhysicalCount,
            $script:LastScan.NativeWifiCount,$script:LastScan.NlaCount,$script:LastScan.ResultCount))
        foreach ($message in @($script:LastScan.Warnings)) { [void]$report.AppendLine('Warning: ' + $message) }
    }
    [void]$report.AppendLine('--- Get-NetAdapter ---')
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
            [void]$report.AppendLine(('Name={0} | Status={1} | IfIndex={2} | GUID={3} | Physical={4} | Ndis={5} | Media={6} | Description={7}' -f
                $a.Name,$a.Status,$a.ifIndex,$a.InterfaceGuid,$a.HardwareInterface,
                $a.NdisPhysicalMedium,$a.PhysicalMediaType,$a.InterfaceDescription))
        }
    } catch { [void]$report.AppendLine('ERROR: ' + $_.Exception.Message) }
    [void]$report.AppendLine('--- Get-NetConnectionProfile ---')
    try {
        foreach ($p in @(Get-NetConnectionProfile -ErrorAction Stop)) {
            [void]$report.AppendLine(('Name={0} | InterfaceAlias={1} | IfIndex={2} | IPv4={3} | IPv6={4}' -f
                $p.Name,$p.InterfaceAlias,$p.InterfaceIndex,$p.IPv4Connectivity,$p.IPv6Connectivity))
        }
    } catch { [void]$report.AppendLine('ERROR: ' + $_.Exception.Message) }
    [void]$report.AppendLine('--- WLAN API ---')
    try {
        foreach ($w in @([NativeNetworks]::GetConnectedWifi())) {
            [void]$report.AppendLine(('SSID={0} | Profile={1} | GUID={2}' -f $w.Ssid,$w.Profile,$w.Guid))
        }
    } catch { [void]$report.AppendLine('ERROR: ' + $_.Exception.Message) }
    return $report.ToString()
}
function Get-StaticDnsMode([object]$network,[int]$family) {
    $guid = [guid]$network.Guid
    if ($family -eq 4) {
        try {
            $raw = [NativeDns]::ReadIpv4Static($guid)
            if (($raw[0] + $raw[1]).Trim()) { return 'Static' }
        } catch { Write-Log "Read Windows profile DNS: $($_.Exception.Message)" }
    }
    $branch = if ($family -eq 4) { 'Tcpip' } else { 'Tcpip6' }
    $regKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters\Interfaces\{{{1}}}' -f $branch, $network.Guid
    try {
        $values = Get-ItemProperty -LiteralPath $regKey -ErrorAction Stop
        if ( ([string]$values.NameServer).Trim() -or ([string]$values.ProfileNameServer).Trim() ) { return 'Static' }
    } catch { }
    return 'Auto'
}
function Read-Dns([object]$network) {
    $four = @(Get-DnsClientServerAddress -InterfaceIndex $network.Index -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
    $six = @(Get-DnsClientServerAddress -InterfaceIndex $network.Index -AddressFamily IPv6 -ErrorAction Stop | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
    return [pscustomobject]@{
        mode4 = (Get-StaticDnsMode $network 4)
        ipv4 = @($four)
        mode6 = (Get-StaticDnsMode $network 6)
        ipv6 = @($six)
    }
}
function New-Preset([string]$name,[string]$mode4,[string[]]$ipv4,[string]$mode6,[string[]]$ipv6) {
    return [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N'); name = $name
        mode4 = $mode4; ipv4 = @($ipv4)
        mode6 = $mode6; ipv6 = @($ipv6)
        created = (Get-Date).ToUniversalTime().ToString('o')
    }
}
function Confirm-IpList([string]$inputText,[int]$family) {
    $ips = @($inputText -split '[,;\s]+' | Where-Object { $_.Trim() })
    if ($ips.Count -lt 1 -or $ips.Count -gt 6) { throw 'برای حالت دستی بین ۱ تا ۶ آدرس DNS وارد کنید.' }
    $validated = [System.Collections.ArrayList]::new()
    foreach ($item in $ips) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($item,[ref]$ip)) { throw "آدرس DNS معتبر نیست: $item" }
        if (($family -eq 4 -and $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) -or
            ($family -eq 6 -and $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6)) { throw "نوع IP اشتباه است: $item" }
        if ($ip.IsIPv6Multicast -or [string]$ip -eq '0.0.0.0' -or [string]$ip -eq '::') { throw "آدرس DNS قابل استفاده نیست: $item" }
        if (-not $validated.Contains($ip.ToString())) { [void]$validated.Add($ip.ToString()) }
    }
    return @($validated.ToArray())
}
function Run-Netsh([string[]]$arguments) {
    $output = & "$env:SystemRoot\System32\netsh.exe" @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "خطا هنگام اعمال DNS با netsh (کد $LASTEXITCODE): $output" }
}
function Set-FamilyDns([object]$network,[int]$family,[string]$mode,[string[]]$servers) {
    if ($mode -eq 'Keep') { return }
    if ($mode -notin @('Static','Auto')) { throw 'حالت DNS ناشناخته است.' }
    $protocol = if ($family -eq 4) { 'ipv4' } else { 'ipv6' }
    $index = [string]$network.Index
    $didNative = $false
    if ($network.Kind -eq 'Wi-Fi') {
        try {
            $value = if ($mode -eq 'Static') { @($servers) -join ',' } else { '' }
            [NativeDns]::SetProfile([guid]$network.Guid,($family -eq 6),$value)
            $didNative = $true
        } catch { Write-Log "Native profile DNS was unavailable; falling back to netsh: $($_.Exception.Message)" }
    }
    # Native profile-level setting is preferred for Wi-Fi. Check effective DNS when static.
    if ($didNative -and $mode -eq 'Static') {
        Start-Sleep -Milliseconds 250
        try {
            $effective = @(Get-DnsClientServerAddress -InterfaceIndex $network.Index -AddressFamily "IPv$family" | ForEach-Object { $_.ServerAddresses })
            $expected = @($servers)
            if (($effective -join ',') -ne ($expected -join ',')) { $didNative = $false }
        } catch { $didNative = $false }
    }
    if ($didNative -and $mode -eq 'Auto') {
        # A stale adapter-wide NameServer can override the Wi-Fi profile setting.
        # If native profile reset is not effective, use the documented family-specific fallback.
        try { if ((Get-StaticDnsMode $network $family) -eq 'Static') { $didNative = $false } }
        catch { $didNative = $false }
    }
    if ($didNative) { return }
    if ($mode -eq 'Auto') {
        Run-Netsh -arguments @('interface',$protocol,'set','dnsservers',("name=$index"),'source=dhcp')
    } else {
        Run-Netsh -arguments @('interface',$protocol,'set','dnsservers',("name=$index"),'source=static',("address=$($servers[0])"),'validate=no')
        for ($i=1; $i -lt $servers.Count; $i++) {
            Run-Netsh -arguments @('interface',$protocol,'add','dnsservers',("name=$index"),("address=$($servers[$i])"),("index=$($i+1)"),'validate=no')
        }
    }
}
function Set-DnsConfig([object]$network,[object]$config) {
    Set-FamilyDns $network 4 ([string]$config.mode4) @($config.ipv4)
    Set-FamilyDns $network 6 ([string]$config.mode6) @($config.ipv6)
}
function Test-ConfigMatches([object]$network,[object]$profile) {
    $now = Read-Dns $network
    if ($profile.mode4 -eq 'Static' -and ((@($now.ipv4) -join ',') -ne (@($profile.ipv4) -join ','))) { return $false }
    if ($profile.mode6 -eq 'Static' -and ((@($now.ipv6) -join ',') -ne (@($profile.ipv6) -join ','))) { return $false }
    if ($profile.mode4 -eq 'Auto' -and $now.mode4 -eq 'Static') { return $false }
    if ($profile.mode6 -eq 'Auto' -and $now.mode6 -eq 'Static') { return $false }
    return $true
}
function Bind-Preset([object]$network,[object]$profile) {
    if ($network.CanApply -eq $false) { throw 'نام یا هویت این شبکه تأیید نشد؛ اعمال DNS برای جلوگیری از اشتباه متوقف شد.' }
    $record = Get-Record $network.Key
    if ($null -eq $record) {
        $record = [pscustomobject]@{
            key=$network.Key; name=$network.Name; kind=$network.Kind
            adapterGuid=$network.Guid; bindingId=$null; original=$null
        }
        [void]$script:db.networks.Add($record)
    }
    if ($null -eq $record.original) {
        $record.original = Read-Dns $network
        Save-Store # Durable backup BEFORE changing any network settings.
    }
    $before = Read-Dns $network
    try {
        Set-DnsConfig $network $profile
        if (-not (Test-ConfigMatches $network $profile)) { throw 'تنظیمات نهایی DNS با پروفایل انتخاب‌شده مطابقت ندارد.' }
    } catch {
        $originalError = $_.Exception.Message
        try { Set-DnsConfig $network $before } catch { Write-Log "Rollback failure: $($_.Exception.Message)" }
        throw $originalError
    }
    $record.bindingId = $profile.id
    $script:db.lastManaged[$network.Guid] = $network.Key
    Save-Store
}
function Restore-Original([object]$network) {
    $record = Get-Record $network.Key
    if ($null -eq $record -or $null -eq $record.original) { throw 'برای این شبکه هنوز نسخهٔ پشتیبان اولیه وجود ندارد.' }
    Set-DnsConfig $network $record.original
    $record.bindingId = $null
    $script:db.lastManaged.Remove($network.Guid)
    Save-Store
}
function Enable-Watcher {
    Import-Module ScheduledTasks -ErrorAction Stop
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Agent' -f $script:InstallPath
    $action = New-ScheduledTaskAction -Execute $script:PsExe -Argument $actionArgs -WorkingDirectory $script:InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    try {
        $script:db.autoEnabled = $true
        Save-Store
        Start-ScheduledTask -TaskName $script:TaskName
    } catch {
        $script:db.autoEnabled = $false
        try { Save-Store } catch { }
        try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        throw
    }
}
function Disable-Watcher {
    Import-Module ScheduledTasks -ErrorAction Stop
    $script:db.autoEnabled = $false
    Save-Store
    try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue } catch { }
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
}
function Agent-Loop {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.Replace('-','_')
    $mutex = New-Object Threading.Mutex($false, ('Local\DNSStudio_' + $sid))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { return }
        Write-Log 'Watcher started.'
        while ($true) {
            try {
                Load-Store
                if (-not $script:db.autoEnabled) { break }
                foreach ($network in @(Get-ConnectedNetworks)) {
                    if ($network.CanApply -eq $false) { continue }
                    $record = Get-Record $network.Key
                    $bound = $null
                    if ($null -ne $record -and $record.bindingId) { $bound = Get-Profile $record.bindingId }
                    if ($null -ne $bound) {
                        if (-not (Test-ConfigMatches $network $bound)) {
                            # The SSID may change while DNS is queried; recheck before writing.
                            $check = @(Get-ConnectedNetworks | Where-Object { $_.Key -ceq $network.Key })
                            if ($check.Count -ne 1) { continue }
                            Set-DnsConfig $check[0] $bound
                            Write-Log "Auto applied '$($bound.name)' to '$($network.Name)'."
                        }
                        if ($script:db.lastManaged[$network.Guid] -cne $network.Key) {
                            $script:db.lastManaged[$network.Guid] = $network.Key
                            Save-Store
                        }
                    } elseif ($script:db.lastManaged.ContainsKey($network.Guid) -and
                              $script:db.lastManaged[$network.Guid] -cne $network.Key) {
                        # A previously managed adapter moved to an unassigned network.
                        # Release inherited DNS to automatic only on THAT adapter.
                        $autoConfig = [pscustomobject]@{mode4='Auto';ipv4=@();mode6='Auto';ipv6=@()}
                        $check = @(Get-ConnectedNetworks | Where-Object { $_.Key -ceq $network.Key })
                        if ($check.Count -ne 1) { continue }
                        Set-DnsConfig $check[0] $autoConfig
                        [void]$script:db.lastManaged.Remove($network.Guid)
                        Save-Store
                        Write-Log "Unassigned network '$($network.Name)' switched to automatic DNS."
                    }
                }
            } catch { Write-Log "Watcher cycle: $($_.Exception.Message)" }
            Start-Sleep -Seconds 10
        }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try { Load-Store } catch {
    if ($Agent) { Write-Log "Cannot read data: $($_.Exception.Message)"; exit 4 }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("فایل اطلاعات قابل خواندن نیست و برای جلوگیری از حذف آن، برنامه متوقف شد:`r`n$($_.Exception.Message)`r`n`r`n$script:DataPath", 'DNS Studio') | Out-Null
    exit 4
}
if ($Agent) { Agent-Loop; exit }

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$font = New-Object System.Drawing.Font('Tahoma',10)
$smallFont = New-Object System.Drawing.Font('Tahoma',9)
$titleFont = New-Object System.Drawing.Font('Tahoma',17,[Drawing.FontStyle]::Bold)

function New-Label([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[object]$fontToUse=$font) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text=$text; $label.SetBounds($x,$y,$w,$h); $label.Font=$fontToUse
    $label.TextAlign='MiddleRight'; $label.AutoEllipsis=$true
    return $label
}
function New-Button([string]$text,[int]$x,[int]$y,[int]$w,[int]$h) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text=$text; $button.SetBounds($x,$y,$w,$h); $button.Font=$font
    $button.UseVisualStyleBackColor=$true
    return $button
}
function Show-Error([string]$message) {
    [System.Windows.Forms.MessageBox]::Show($message,'DNS Studio - خطا','OK','Error') | Out-Null
}
function Show-Info([string]$message) {
    [System.Windows.Forms.MessageBox]::Show($message,'DNS Studio','OK','Information') | Out-Null
}
function Ask-YesNo([string]$message) {
    return ([System.Windows.Forms.MessageBox]::Show($message,'DNS Studio','YesNo','Question') -eq 'Yes')
}
function Show-NameDialog([string]$title,[string]$initial='') {
    $f=New-Object System.Windows.Forms.Form
    $f.Text=$title; $f.Font=$font; $f.Size=New-Object Drawing.Size(480,205)
    $f.StartPosition='CenterParent'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false
    $f.RightToLeft='Yes'; $f.RightToLeftLayout=$true
    $label=New-Label 'نام دلخواه برای ذخیره:' 35 18 405 30
    $input=New-Object System.Windows.Forms.TextBox
    $input.SetBounds(35,55,405,29); $input.Text=$initial; $input.Font=$font
    $ok=New-Button 'ذخیره' 250 104 190 36; $ok.DialogResult='OK'
    $cancel=New-Button 'انصراف' 35 104 190 36; $cancel.DialogResult='Cancel'
    $f.Controls.AddRange(@($label,$input,$ok,$cancel)); $f.AcceptButton=$ok; $f.CancelButton=$cancel
    $result=$f.ShowDialog($form)
    $name=$input.Text.Trim(); $f.Dispose()
    if ($result -ne 'OK') { return $null }
    if (-not $name -or $name.Length -gt 70) { Show-Error 'نام باید بین ۱ تا ۷۰ نویسه باشد.'; return $null }
    return $name
}
function Show-PresetEditor([object]$existing=$null) {
    $f=New-Object System.Windows.Forms.Form
    $f.Text= $(if($null -eq $existing){'پروفایل جدید DNS'}else{'ویرایش پروفایل DNS'})
    $f.Font=$font; $f.ClientSize=New-Object Drawing.Size(640,440)
    $f.StartPosition='CenterParent'; $f.FormBorderStyle='FixedDialog'
    $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.RightToLeft='Yes'; $f.RightToLeftLayout=$true
    $f.Controls.Add((New-Label 'نام پروفایل' 35 17 570 27))
    $txtName=New-Object System.Windows.Forms.TextBox
    $txtName.SetBounds(35,47,570,28); $txtName.Font=$font
    $f.Controls.Add($txtName)
    $f.Controls.Add((New-Label 'IPv4' 35 91 570 27))
    $mode4 = New-Object System.Windows.Forms.ComboBox
    $mode4.SetBounds(395,119,210,29); $mode4.Font=$font; $mode4.DropDownStyle='DropDownList'
    [void]$mode4.Items.Add('دستی'); [void]$mode4.Items.Add('خودکار (DHCP)'); [void]$mode4.Items.Add('بدون تغییر')
    $txt4 = New-Object System.Windows.Forms.TextBox
    $txt4.SetBounds(35,119,347,29); $txt4.Font=$font; $txt4.RightToLeft='No'
    $f.Controls.AddRange(@($mode4,$txt4))
    $f.Controls.Add((New-Label 'آدرس‌ها را با ویرگول جدا کنید (مثلاً 1.1.1.1, 1.0.0.1)' 35 152 570 25 $smallFont))
    $f.Controls.Add((New-Label 'IPv6 (اختیاری)' 35 195 570 27))
    $mode6 = New-Object System.Windows.Forms.ComboBox
    $mode6.SetBounds(395,224,210,29); $mode6.Font=$font; $mode6.DropDownStyle='DropDownList'
    [void]$mode6.Items.Add('بدون تغییر'); [void]$mode6.Items.Add('دستی'); [void]$mode6.Items.Add('خودکار (DHCP)')
    $txt6 = New-Object System.Windows.Forms.TextBox
    $txt6.SetBounds(35,224,347,29); $txt6.Font=$font; $txt6.RightToLeft='No'
    $f.Controls.AddRange(@($mode6,$txt6))
    $f.Controls.Add((New-Label 'مثلاً 2606:4700:4700::1111, 2606:4700:4700::1001' 35 257 570 25 $smallFont))
    $f.Controls.Add((New-Label 'تنظیم «بدون تغییر» خانوادهٔ IP مربوطه را دست‌نخورده نگه می‌دارد.' 35 295 570 28 $smallFont))
    $btnSave=New-Button 'ذخیره پروفایل' 334 355 271 44
    $btnCancel=New-Button 'انصراف' 35 355 270 44; $btnCancel.DialogResult='Cancel'
    $f.Controls.AddRange(@($btnSave,$btnCancel))
    $f.CancelButton=$btnCancel
    $mode4.SelectedIndex=0; $mode6.SelectedIndex=0
    if ($null -ne $existing) {
        $txtName.Text=[string]$existing.name
        $txt4.Text=(@($existing.ipv4) -join ', ')
        $txt6.Text=(@($existing.ipv6) -join ', ')
        $mode4.SelectedIndex= $(switch ($existing.mode4) {'Static'{0};'Auto'{1};default{2}})
        $mode6.SelectedIndex= $(switch ($existing.mode6) {'Keep'{0};'Static'{1};default{2}})
    }
    $mode4.Add_SelectedIndexChanged({ $txt4.Enabled = ($mode4.SelectedIndex -eq 0) })
    $mode6.Add_SelectedIndexChanged({ $txt6.Enabled = ($mode6.SelectedIndex -eq 1) })
    $txt4.Enabled=($mode4.SelectedIndex -eq 0); $txt6.Enabled=($mode6.SelectedIndex -eq 1)
    $script:editorResult = $null
    $btnSave.Add_Click({
        try {
            $name=$txtName.Text.Trim()
            if (-not $name -or $name.Length -gt 70) { throw 'نام پروفایل باید بین ۱ تا ۷۰ نویسه باشد.' }
            $m4 = @('Static','Auto','Keep')[$mode4.SelectedIndex]
            $m6 = @('Keep','Static','Auto')[$mode6.SelectedIndex]
            if ($m4 -eq 'Keep' -and $m6 -eq 'Keep') { throw 'حداقل یکی از IPv4 یا IPv6 باید تنظیم شود.' }
            $ip4= @(); $ip6=@()
            if ($m4 -eq 'Static') { $ip4 = @(Confirm-IpList $txt4.Text 4) }
            if ($m6 -eq 'Static') { $ip6 = @(Confirm-IpList $txt6.Text 6) }
            $script:editorResult = [pscustomobject]@{name=$name;mode4=$m4;ipv4=@($ip4);mode6=$m6;ipv6=@($ip6)}
            $f.DialogResult='OK'; $f.Close()
        } catch { Show-Error $_.Exception.Message }
    })
    $r=$f.ShowDialog($form); $f.Dispose()
    if ($r -eq 'OK') { return $script:editorResult }
    return $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text='DNS Studio | مدیریت DNS شبکه‌ها'
$form.ClientSize=New-Object System.Drawing.Size(920,700)
$form.Font=$font; $form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
$form.RightToLeft='Yes'; $form.RightToLeftLayout=$true
$form.BackColor=[Drawing.Color]::FromArgb(246,248,251)
$form.Controls.Add((New-Label 'DNS Studio    |    مدیریت آسان DNS برای هر شبکه' 35 15 850 47 $titleFont))
$form.Controls.Add((New-Label 'شبکهٔ فعال را انتخاب کنید، پروفایل را انتخاب کنید، سپس دوبار کلیک کنید یا «اعمال» را بزنید.' 35 60 850 29 $smallFont))
$form.Controls.Add((New-Label 'انتخاب شبکهٔ متصل' 165 101 716 30))
$btnDiagnose = New-Button 'کپی گزارش تشخیص' 35 100 132 29
$form.Controls.Add($btnDiagnose)
$netCombo = New-Object System.Windows.Forms.ComboBox
$netCombo.SetBounds(180,138,705,36); $netCombo.DropDownStyle='DropDownList'; $netCombo.Font=$font
$netCombo.DisplayMember='Label'; $netCombo.RightToLeft='Yes'
$btnRefresh = New-Button 'بازخوانی شبکه‌ها' 35 137 132 36
$form.Controls.AddRange(@($netCombo,$btnRefresh))
$lblNow = New-Label 'DNS فعلی: ...' 35 183 850 68 $smallFont
$lblNow.BackColor=[Drawing.Color]::White
$lblNow.BorderStyle='FixedSingle'
$form.Controls.Add($lblNow)
$form.Controls.Add((New-Label 'پروفایل‌های ذخیره‌شده (دوبار کلیک برای اعمال)' 35 266 850 31))
$list = New-Object System.Windows.Forms.ListBox
$list.SetBounds(35,304,850,177); $list.Font=$font; $list.RightToLeft='Yes'
$list.DisplayMember='display'; $list.HorizontalScrollbar=$true
$form.Controls.Add($list)
$btnApply = New-Button '✓  اعمال DNS انتخاب‌شده' 630 495 255 48
$btnApply.BackColor=[Drawing.Color]::FromArgb(19,112,212); $btnApply.ForeColor=[Drawing.Color]::White
$btnApply.UseVisualStyleBackColor=$false
$btnCapture = New-Button 'ذخیره DNS فعلی' 425 495 192 48
$btnNew = New-Button '+ پروفایل جدید' 220 495 192 48
$btnRestore = New-Button 'بازگردانی اولیه' 35 495 172 48
$form.Controls.AddRange(@($btnApply,$btnCapture,$btnNew,$btnRestore))
$btnEdit=New-Button 'ویرایش پروفایل' 655 557 230 35
$btnDelete=New-Button 'حذف پروفایل' 422 557 220 35
$btnOpen=New-Button 'بازکردن پوشهٔ اطلاعات' 185 557 224 35
$form.Controls.AddRange(@($btnEdit,$btnDelete,$btnOpen))
$auto = New-Object System.Windows.Forms.CheckBox
$auto.Text='سوییچ خودکار هنگام تغییر شبکه و پس از ورود به ویندوز (توصیه‌شده)'
$auto.SetBounds(35,603,850,32); $auto.Font=$font; $auto.RightToLeft='Yes'
$auto.Checked=[bool]$script:db.autoEnabled
$form.Controls.Add($auto)
$lblFoot=New-Label 'فقط DNS تغییر می‌کند؛ IP، Gateway و رمز Wi-Fi تغییر نمی‌کنند. DoH در این نسخه مدیریت نمی‌شود.' 35 642 850 22 $smallFont
$lblFoot.ForeColor=[Drawing.Color]::FromArgb(91,96,107)
$form.Controls.Add($lblFoot)
$lblStatus=New-Label 'آماده' 35 665 850 25 $smallFont
$lblStatus.ForeColor=[Drawing.Color]::FromArgb(25,105,170)
$form.Controls.Add($lblStatus)

function Current-Network { return $netCombo.SelectedItem }
function Selected-Preset { if ($null -ne $list.SelectedItem) { return Get-Profile $list.SelectedItem.id }; return $null }
function Refresh-Current {
    $n=Current-Network
    $allowed = ($null -ne $n -and $n.CanApply -ne $false)
    $btnApply.Enabled=$allowed; $btnCapture.Enabled=$allowed; $btnRestore.Enabled=$allowed
    if ($null -eq $n) { $lblNow.Text='شبکهٔ فعالی شناسایی نشد. اتصال Wi-Fi یا Ethernet را بررسی کنید. برای جزئیات «کپی گزارش تشخیص» را بزنید.'; return }
    if (-not $allowed) {
        $lblNow.Text='کارت شبکه پیدا شد، ولی نام اتصال مشخص نیست. تغییر DNS برای جلوگیری از اعمال روی شبکهٔ اشتباه غیرفعال است.'
        $lblStatus.Text='از دکمهٔ «کپی گزارش تشخیص» استفاده کنید.'
        return
    }
    try {
        $s=Read-Dns $n
        $desc4=if($s.mode4 -eq 'Auto'){'خودکار'}else{'دستی'}
        $desc6=if($s.mode6 -eq 'Auto'){'خودکار'}else{'دستی'}
        $shown4=if(@($s.ipv4).Count){@($s.ipv4) -join ', '}else{'—'}
        $shown6=if(@($s.ipv6).Count){@($s.ipv6) -join ', '}else{'—'}
        $lblNow.Text='DNS فعلی IPv4: {0} | {1}     /     IPv6: {2} | {3}' -f $desc4,$shown4,$desc6,$shown6
        $record = Get-Record $n.Key
        $p=if($record -and $record.bindingId){Get-Profile $record.bindingId}else{$null}
        $lblStatus.Text=if($p){'پروفایل این شبکه: '+$p.name}else{'برای این شبکه هنوز پروفایل فعالی ثبت نشده است.'}
    } catch { $lblNow.Text='خطا در خواندن DNS فعلی: '+$_.Exception.Message }
}
function Refresh-Profiles([string]$selectedId='') {
    $n=Current-Network; $binding=''
    if ($null -ne $n) { $rec=Get-Record $n.Key; if($rec){$binding=[string]$rec.bindingId} }
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($p in @($script:db.profiles)) {
            $prefix=if($p.id -eq $binding){'● '}else{'   '}
            $d4= switch ($p.mode4) {'Auto' {'DHCP'} 'Keep' {'—'} default {(@($p.ipv4) -join '، ')}}
            $d6= switch ($p.mode6) {'Auto' {'DHCP'} 'Keep' {'—'} default {(@($p.ipv6) -join '، ')}}
            [void]$list.Items.Add([pscustomobject]@{id=$p.id;display=('{0}{1}   |   IPv4: {2}   |   IPv6: {3}' -f $prefix,$p.name,$d4,$d6)})
        }
        if ($selectedId) { for($i=0;$i -lt $list.Items.Count;$i++){if($list.Items[$i].id -eq $selectedId){$list.SelectedIndex=$i;break}} }
    } finally { $list.EndUpdate() }
}
function Refresh-Networks {
    $previous=if($netCombo.SelectedItem){$netCombo.SelectedItem.Key}else{''}
    try {
        $networks=@(Get-ConnectedNetworks)
        $netCombo.Items.Clear()
        foreach($n in $networks){[void]$netCombo.Items.Add($n)}
        if($netCombo.Items.Count -gt 0){
            $netCombo.SelectedIndex=0
            for($i=0;$i -lt $netCombo.Items.Count;$i++) { if($netCombo.Items[$i].Key -ceq $previous){$netCombo.SelectedIndex=$i;break} }
        }
        Refresh-Current;Refresh-Profiles
        if ($netCombo.Items.Count -eq 0 -and $script:LastScan) {
            $scan=$script:LastScan
            $lblNow.Text=('شبکهٔ قابل انتخاب پیدا نشد. کارت‌ها: {0} | متصل: {1} | WLAN: {2} | NLA: {3} | برای جزئیات «کپی گزارش تشخیص» را بزنید.' -f
                $scan.AdapterCount,$scan.ActiveCount,$scan.NativeWifiCount,$scan.NlaCount)
            $lblStatus.Text='تشخیص شبکه ناموفق بود؛ گزارش را کپی کنید و برای بررسی بفرستید.'
        }
    } catch {
        Write-Log ('Refresh-Networks: '+$_.Exception.ToString())
        Show-Error ('شناسایی شبکه‌ها انجام نشد: '+$_.Exception.Message)
    }
}
function Apply-FromUi {
    $n=Current-Network; $p=Selected-Preset
    if($null -eq $n){Show-Error 'ابتدا یک شبکهٔ متصل انتخاب کنید.';return}
    if($n.CanApply -eq $false){Show-Error 'نام شبکه قابل شناسایی نیست؛ تغییر DNS متوقف شد.';return}
    if($null -eq $p){Show-Error 'ابتدا یک پروفایل DNS انتخاب کنید.';return}
    try {
        # Reconfirm physical network identity right before write to avoid stale combo state.
        $live=@(Get-ConnectedNetworks | Where-Object {$_.Key -ceq $n.Key})
        if($live.Count -ne 1){throw 'اتصال شبکه تغییر کرده است. لطفاً بازخوانی کنید.'}
        $form.Cursor='WaitCursor'; $form.Refresh()
        Bind-Preset $live[0] $p
        $form.Cursor='Default'
        Refresh-Current;Refresh-Profiles $p.id
        $lblStatus.Text='✓ پروفایل «'+$p.name+'» روی شبکهٔ «'+$n.Name+'» اعمال و ذخیره شد.'
        if(-not $script:db.autoEnabled){
            if(Ask-YesNo 'DNS اعمال شد. برای جلوگیری از باقی‌ماندن DNS روی Wi-Fiهای دیگر، پایش و سوییچ خودکار فعال شود؟'){
                try {
                    Enable-Watcher
                    $script:adjustingAuto=$true; $auto.Checked=$true; $script:adjustingAuto=$false
                } catch { Show-Error ('فعال‌سازی پایشگر ناموفق بود: '+$_.Exception.Message) }
            }
        }
    } catch { $form.Cursor='Default';Show-Error $_.Exception.Message }
}
$btnRefresh.Add_Click({Refresh-Networks})
$btnDiagnose.Add_Click({
    try {
        $report=Get-NetworkDiagnostics
        [System.Windows.Forms.Clipboard]::SetText($report)
        $lblStatus.Text='✓ گزارش شبکه در Clipboard کپی شد.'
        Show-Info 'گزارش تشخیص در Clipboard کپی شد. آن را در Notepad بچسبانید و در صورت نیاز برای بررسی ارسال کنید؛ گزارش شامل نام شبکه و مشخصات کارت است.'
    } catch { Show-Error ('ایجاد گزارش ناموفق بود: '+$_.Exception.Message) }
})
$netCombo.Add_SelectedIndexChanged({Refresh-Current;Refresh-Profiles})
$btnApply.Add_Click({Apply-FromUi})
$list.Add_DoubleClick({Apply-FromUi})
$btnCapture.Add_Click({
    $n=Current-Network
    if(-not $n){Show-Error 'ابتدا شبکهٔ متصل را انتخاب کنید.';return}
    $name=Show-NameDialog 'ذخیره DNS موجود' ('DNS اولیه - '+$n.Name)
    if($null -eq $name){return}
    try {
        $live=@(Get-ConnectedNetworks|Where-Object{$_.Key -ceq $n.Key})
        if($live.Count -ne 1){throw 'اتصال شبکه تغییر کرده است. لطفاً بازخوانی کنید.'}
        $s=Read-Dns $live[0]
        $p=New-Preset $name $s.mode4 @($s.ipv4) $s.mode6 @($s.ipv6)
        # When auto, store empty list rather than router-supplied dynamic IPs as hardcoded DNS.
        if($p.mode4 -eq 'Auto'){$p.ipv4=@()}; if($p.mode6 -eq 'Auto'){$p.ipv6=@()}
        [void]$script:db.profiles.Add($p)
        $record=Get-Record $n.Key
        if(-not $record){
            $record=[pscustomobject]@{key=$n.Key;name=$n.Name;kind=$n.Kind;adapterGuid=$n.Guid;bindingId=$null;original=$s}
            [void]$script:db.networks.Add($record)
        } elseif(-not $record.original){$record.original=$s}
        Save-Store
        Refresh-Profiles $p.id
        $lblStatus.Text='✓ DNS فعلی با نام «'+$p.name+'» ذخیره شد.'
    } catch {Show-Error $_.Exception.Message}
})
$btnNew.Add_Click({
    $data=Show-PresetEditor
    if($null -eq $data){return}
    try {
        $p=New-Preset $data.name $data.mode4 @($data.ipv4) $data.mode6 @($data.ipv6)
        [void]$script:db.profiles.Add($p);Save-Store
        Refresh-Profiles $p.id
        $lblStatus.Text='✓ پروفایل جدید ذخیره شد. برای اعمال، دوبار روی آن کلیک کنید.'
    } catch {Show-Error $_.Exception.Message}
})
$btnEdit.Add_Click({
    $p=Selected-Preset
    if(-not $p){Show-Error 'برای ویرایش یک پروفایل را انتخاب کنید.';return}
    $data=Show-PresetEditor $p
    if($null -eq $data){return}
    try {
        $p.name=$data.name;$p.mode4=$data.mode4;$p.ipv4=@($data.ipv4)
        $p.mode6=$data.mode6;$p.ipv6=@($data.ipv6)
        Save-Store;Refresh-Profiles $p.id
        $lblStatus.Text='✓ پروفایل ویرایش شد. در صورت نیاز دوباره آن را اعمال کنید.'
    } catch {Show-Error $_.Exception.Message}
})
$btnDelete.Add_Click({
    $p=Selected-Preset
    if(-not $p){Show-Error 'یک پروفایل را انتخاب کنید.';return}
    if(-not (Ask-YesNo ('پروفایل «'+$p.name+'» حذف شود؟' + [Environment]::NewLine + 'تنظیم DNS فعال دست‌نخورده می‌ماند.'))){return}
    try {
        [void]$script:db.profiles.Remove($p)
        foreach($rec in $script:db.networks){if($rec.bindingId -eq $p.id){$rec.bindingId=$null}}
        Save-Store;Refresh-Profiles;Refresh-Current
    } catch {Show-Error $_.Exception.Message}
})
$btnRestore.Add_Click({
    $n=Current-Network
    if(-not $n){Show-Error 'یک شبکهٔ متصل انتخاب کنید.';return}
    if(-not (Ask-YesNo ('DNS اولیهٔ شبکهٔ «'+$n.Name+'» بازگردانی شود؟'))){return}
    try {
        $live=@(Get-ConnectedNetworks|Where-Object{$_.Key -ceq $n.Key})
        if($live.Count -ne 1){throw 'اتصال شبکه تغییر کرده است. دوباره بازخوانی کنید.'}
        Restore-Original $live[0]
        Refresh-Current;Refresh-Profiles
        $lblStatus.Text='✓ DNS پشتیبان اولیه برای شبکهٔ «'+$n.Name+'» بازگردانی شد.'
    } catch {Show-Error $_.Exception.Message}
})
$btnOpen.Add_Click({Start-Process -FilePath explorer.exe -ArgumentList ('"'+$script:InstallDir+'"')})
$auto.Add_CheckedChanged({
    if($script:adjustingAuto){return}
    try {
        if($auto.Checked){
            if(-not (Ask-YesNo 'با فعال‌سازی، پایشگر در زمان ورود شما به ویندوز اجرا می‌شود و هر ۱۰ ثانیه شبکه را بررسی می‌کند. در شبکه‌های بدون پروفایل، اگر از شبکهٔ مدیریت‌شده آمده باشید DNS خودکار می‌شود. ادامه می‌دهید؟')){
                $script:adjustingAuto=$true;$auto.Checked=$false;$script:adjustingAuto=$false;return
            }
            Enable-Watcher;$lblStatus.Text='✓ سوییچ خودکار فعال شد.'
        } else {
            Disable-Watcher;$lblStatus.Text='پایش خودکار خاموش شد. تا زمانی که روشن نباشد، تغییرات شبکه خودکار اعمال نمی‌شوند.'
        }
    } catch {
        Show-Error ('تغییر پایشگر ممکن نشد: '+$_.Exception.Message)
        $script:adjustingAuto=$true;$auto.Checked=[bool]$script:db.autoEnabled;$script:adjustingAuto=$false
    }
})

# Keep GUI fresh if the watcher changes DNS while the window is open.
$refreshTimer=New-Object System.Windows.Forms.Timer
$refreshTimer.Interval=12000
$refreshTimer.Add_Tick({
    if (-not $form.IsDisposed) {
        try {
            $sel = Current-Network
            $live = @(Get-ConnectedNetworks)
            if ($null -eq $sel -or @($live | Where-Object { $_.Key -ceq $sel.Key }).Count -ne 1) { Refresh-Networks }
            else { Refresh-Current }
        } catch { }
    }
})
$refreshTimer.Start()
$form.Add_FormClosing({$refreshTimer.Stop();$refreshTimer.Dispose()})
try {
    Refresh-Networks
    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    Show-Error ('خطای پیش‌بینی‌نشده: '+$_.Exception.Message)
    Write-Log ('GUI: '+$_.Exception.ToString())
} finally { if(-not $form.IsDisposed){$form.Dispose()} }
}
catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('برنامه نتوانست اجرا شود:' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + 'گزارش: ' + $script:LogPath, 'DNS Studio') | Out-Null
        Write-Log ('Fatal GUI initialization: ' + $_.Exception.ToString())
    } catch { }
    exit 6
}