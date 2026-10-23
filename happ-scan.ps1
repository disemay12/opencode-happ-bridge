# happ-scan.ps1 - полный дамп РЕГИОНОВ памяти процесса (без обрезки окнами), где встречается needle
# -Probe: только показать регионы/размеры, ничего не писать
# -Dump : записать регионы в файл (заголовки ===REGION base=0x... size=...=== + сырые байты)
[CmdletBinding()]
param(
    [string]$Exe = 'Happ',
    [string]$Needle = 'remarks',
    [string]$OutFile = 'C:\Temp\opencode\happ-regions.bin',
    [switch]$Probe,
    [int]$MaxRegionMB = 512,
    [int]$PidOverride = 0
)

$ErrorActionPreference = 'Stop'

$cs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.IO;
using System.Collections.Generic;

public class RegionScan {
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public ulong RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int VirtualQueryEx(IntPtr h, IntPtr addr, out MEMORY_BASIC_INFORMATION mbi, int len);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out int read);
    [DllImport("kernel32.dll")] public static extern int CloseHandle(IntPtr h);

    static int IndexOf(byte[] hay, byte[] needle, int start, int end) {
        int n = needle.Length;
        byte first = needle[0];
        for (int i = start; i + n <= end; i++) {
            if (hay[i] != first) continue;
            int j = 1;
            while (j < n && hay[i + j] == needle[j]) j++;
            if (j == n) return i;
        }
        return -1;
    }

    public static int Run(int pid, string needle, string outFile, bool probe, int maxRegionMB) {
        IntPtr h = OpenProcess(0x0410, false, pid);
        if (h == IntPtr.Zero) { Console.WriteLine("OpenProcess failed err=" + Marshal.GetLastWin32Error()); return 1; }
        byte[] nb = Encoding.UTF8.GetBytes(needle);
        ulong addr = 0;
        const ulong MAXADDR = 0x7FFFFFFEFFFF;
        long hitsRegions = 0, totalBytes = 0;
        FileStream fs = null;
        try {
            if (!probe) fs = new FileStream(outFile, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
            while (addr < MAXADDR) {
                MEMORY_BASIC_INFORMATION mbi;
                if (VirtualQueryEx(h, (IntPtr)addr, out mbi, Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION))) == 0) break;
                ulong size = mbi.RegionSize;
                bool readable = (mbi.State & 0x1000) != 0 && (mbi.Protect & 0x7F) != 0 && (mbi.Protect & 0x100) == 0;
                if (readable && size > 0 && size <= (ulong)maxRegionMB * 1024UL * 1024UL) {
                    int sz = (int)size;
                    byte[] buf = new byte[sz];
                    int read;
                    if (ReadProcessMemory(h, mbi.BaseAddress, buf, sz, out read) && read > 0) {
                        if (IndexOf(buf, nb, 0, read) >= 0) {
                            hitsRegions++;
                            totalBytes += read;
                            if (probe) {
                                Console.WriteLine("region base=0x" + ((ulong)(long)mbi.BaseAddress).ToString("X") + " size=" + read + " protect=0x" + mbi.Protect.ToString("X"));
                            } else {
                                byte[] hdr = Encoding.ASCII.GetBytes("===REGION base=0x" + ((ulong)(long)mbi.BaseAddress).ToString("X") + " size=" + read + "===\n");
                                fs.Write(hdr, 0, hdr.Length);
                                fs.Write(buf, 0, read);
                                byte[] hdr2 = Encoding.ASCII.GetBytes("\n===ENDREGION===\n");
                                fs.Write(hdr2, 0, hdr2.Length);
                            }
                        }
                    }
                }
                addr = (ulong)(long)mbi.BaseAddress + size;
                if (size == 0) addr += 0x1000;
            }
        } finally {
            if (fs != null) fs.Close();
            CloseHandle(h);
        }
        Console.WriteLine("regions with needle=" + hitsRegions + " bytes=" + totalBytes + (probe ? "" : (" out=" + outFile)));
        return 0;
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

$pidTarget = $PidOverride
if ($pidTarget -eq 0) {
    $pidTarget = (Get-CimInstance Win32_Process -Filter "Name='${Exe}.exe'" | Select-Object -First 1).ProcessId
}
if (-not $pidTarget) { Write-Host "process ${Exe}.exe not found"; exit 1 }
Write-Host "scanning ${Exe}.exe pid $pidTarget needle='$Needle' ..."
[RegionScan]::Run($pidTarget, $Needle, $OutFile, [bool]$Probe, $MaxRegionMB) | Out-Null
exit 0
