// OpenCode-Happ.exe - единый лаунчер: запуск OpenCode через мост + горячее переключение
// узлов Happ/апстримов + статус/egress. Всё меню и логика внутри одного exe.
//
// Сборка (Windows, .NET Framework 4.x):
//   csc /target:exe /platform:anycpu /optimize+ /codepage:65001 ^
//       /r:System.Management.dll /r:System.Web.Extensions.dll ^
//       /out:OpenCode-Happ.exe src\OpenCodeHapp.cs
//
// CLI: --menu (по умолчанию), --list, --use N, --status, --launch, --restart,
//      --refresh, --ensure, --stop-bridge, --stop-companion, --upstream NAME
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    private static readonly string CfgPath = Path.Combine(Root, "bridge.settings.json");
    private static readonly string PortStatePath = Path.Combine(Root, "bridge.port.json");
    private static readonly string IdxPath = Path.Combine(Root, "nodes-index.json");
    private static readonly string PoolPath = Path.Combine(Root, "nodes-pool.json");
    private const string XrayPath = @"C:\Program Files\FlyFrogLLC\Happ\core\xray.exe";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly List<StreamWriter> LogWriters = new List<StreamWriter>();
    private static readonly List<Process> Logged = new List<Process>();

    private static StreamWriter OpenLog(string path)
    {
        FileStream fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        StreamWriter sw = new StreamWriter(fs, new UTF8Encoding(false));
        sw.AutoFlush = true;
        return sw;
    }

    // ---------------------------------------------------------------- модели
    private sealed class BridgeCfg
    {
        public string Host;
        public int Port;
        public string Active;
        public Dictionary<string, string> Upstreams = new Dictionary<string, string>();
    }

    private sealed class NodeInfo
    {
        public int N;
        public int Port;
        public string Country;
        public string Proto;
        public string Net;
        public string Addr;
        public int Port0;
        public string Egress;
    }

    // ---------------------------------------------------------------- утилиты
    private static bool TestPort(string host, int port, int timeoutMs)
    {
        TcpClient c = new TcpClient();
        try
        {
            IAsyncResult ar = c.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) return false;
            c.EndConnect(ar);
            return true;
        }
        catch { return false; }
        finally { try { c.Close(); } catch { } }
    }

    private static string HttpGet(string url, string proxy, int timeoutMs)
    {
        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
        req.Timeout = timeoutMs;
        req.ReadWriteTimeout = timeoutMs;
        req.UserAgent = "OpenCode-Happ/1.0";
        if (proxy != null) req.Proxy = new WebProxy(proxy);
        using (WebResponse resp = req.GetResponse())
        using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
            return sr.ReadToEnd();
    }

    private static string EgressThroughBridge(BridgeCfg c)
    {
        try
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.ipify.org");
            req.Proxy = new WebProxy("http://" + c.Host + ":" + c.Port);
            req.Timeout = 25000;
            req.ReadWriteTimeout = 25000;
            req.KeepAlive = false; // иначе .NET переиспользует туннель к старому узлу
            req.UserAgent = "OpenCode-Happ/1.0";
            using (WebResponse resp = req.GetResponse())
            using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return sr.ReadToEnd().Trim();
        }
        catch { return null; }
    }

    private static List<int> FindPids(string exeName, string needle)
    {
        List<int> list = new List<int>();
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = '" + exeName + "'"))
            using (ManagementObjectCollection rows = s.Get())
            {
                foreach (ManagementObject mo in rows)
                {
                    string cmd = Convert.ToString(mo["CommandLine"]);
                    if (cmd != null && cmd.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
                        list.Add(Convert.ToInt32(mo["ProcessId"]));
                }
            }
        }
        catch { }
        return list;
    }

    private static string ParentName(int pid)
    {
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(
                "SELECT Name FROM Win32_Process WHERE ProcessId = " + pid))
            using (ManagementObjectCollection rows = s.Get())
                foreach (ManagementObject mo in rows) return Convert.ToString(mo["Name"]);
        }
        catch { }
        return null;
    }

    private static int ParentPid(int pid)
    {
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(
                "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId = " + pid))
            using (ManagementObjectCollection rows = s.Get())
                foreach (ManagementObject mo in rows) return Convert.ToInt32(mo["ParentProcessId"]);
        }
        catch { }
        return 0;
    }

    private static bool InsideOpenCode()
    {
        int cur = Process.GetCurrentProcess().Id;
        for (int i = 0; i < 15; i++)
        {
            string name = ParentName(cur);
            if (name == null) return false;
            if (string.Equals(name, "OpenCode.exe", StringComparison.OrdinalIgnoreCase)) return true;
            cur = ParentPid(cur);
            if (cur == 0) return false;
        }
        return false;
    }

    private static Process StartHidden(string exe, string args, string outLog, string errLog)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.WorkingDirectory = Root;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        Process p = new Process();
        p.StartInfo = psi;
        StreamWriter so = OpenLog(outLog);
        StreamWriter se = OpenLog(errLog);
        lock (LogWriters) { LogWriters.Add(so); LogWriters.Add(se); }
        p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
        { if (e.Data != null) { lock (so) { so.WriteLine(e.Data); } } };
        p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
        { if (e.Data != null) { lock (se) { se.WriteLine(e.Data); } } };
        try { p.Start(); }
        catch { try { so.Close(); } catch { } try { se.Close(); } catch { } throw; }
        p.EnableRaisingEvents = true;
        p.Exited += delegate
        {
            try { so.Close(); } catch { }
            try { se.Close(); } catch { }
            lock (Logged) { Logged.Remove(p); }
        };
        lock (Logged) { Logged.Add(p); }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        return p;
    }

    private static string NodeExe()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(';'))
        {
            if (dir.Trim().Length == 0) continue;
            string cand = Path.Combine(dir.Trim(), "node.exe");
            if (File.Exists(cand)) return cand;
        }
        string[] known = new string[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"nodejs\node.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\nodejs\node.exe")
        };
        foreach (string k in known) if (File.Exists(k)) return k;
        return null;
    }

    private static string FindOpenCode()
    {
        string cand = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Programs\@opencodedesktop\OpenCode.exe");
        if (File.Exists(cand)) return cand;
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(';'))
        {
            if (dir.Trim().Length == 0) continue;
            string c2 = Path.Combine(dir.Trim(), "OpenCode.exe");
            if (File.Exists(c2)) return c2;
        }
        return null;
    }

    private static string OpenCodeCliExe()
    {
        try
        {
            string baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "ai.opencode.desktop", "cli");
            if (!Directory.Exists(baseDir)) return null;
            foreach (string dir in Directory.GetDirectories(baseDir).OrderByDescending(d => Path.GetFileName(d)))
            {
                string exe = Path.Combine(dir, "opencode-cli.exe");
                if (File.Exists(exe)) return exe;
            }
        }
        catch { }
        return null;
    }

    private static string RunCapture(string exe, string args)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        using (Process p = Process.Start(psi))
        {
            if (p == null) return "";
            StringBuilder stdout = new StringBuilder();
            StringBuilder stderr = new StringBuilder();
            p.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) stdout.AppendLine(e.Data);
            };
            p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) stderr.AppendLine(e.Data);
            };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            if (!p.WaitForExit(15000))
            {
                try { p.Kill(); } catch { }
            }
            // No-timeout wait flushes the asynchronous output handlers.
            p.WaitForExit();
            return stdout.ToString();
        }
    }

    // The desktop spawns `opencode-cli serve --service` with its own proxy env;
    // a stale port there is what breaks OpenCode after the bridge moves.
    private static void SyncServiceProxy(string url)
    {
        string cli = OpenCodeCliExe();
        if (cli == null) return;
        try
        {
            string cur = RunCapture(cli, "service get");
            int hits = (cur ?? "").Split(new string[] { url }, StringSplitOptions.None).Length - 1;
            if (hits >= 2) return;
            RunCapture(cli, "service set env HTTPS_PROXY " + url);
            RunCapture(cli, "service set env HTTP_PROXY " + url);
            Console.WriteLine("service proxy env -> " + url);
        }
        catch (Exception ex) { Console.WriteLine("service proxy env update skipped: " + ex.Message); }
    }

    // ---------------------------------------------------------------- конфиг
    private static BridgeCfg LoadCfg()
    {
        if (!File.Exists(CfgPath)) throw new Exception("нет файла " + CfgPath + " — положите exe в папку opencode-happ-bridge");
        string raw = File.ReadAllText(CfgPath, Encoding.UTF8).TrimStart('\uFEFF');
        Dictionary<string, object> d = (Dictionary<string, object>)Json.DeserializeObject(raw);
        Dictionary<string, object> listen = (Dictionary<string, object>)d["listen"];
        BridgeCfg c = new BridgeCfg();
        c.Host = Convert.ToString(listen["host"]);
        c.Port = ResolveBridgePort(c.Host, Convert.ToInt32(listen["port"]));
        c.Active = Convert.ToString(d["active"]);
        Dictionary<string, object> ups = (Dictionary<string, object>)d["upstreams"];
        foreach (KeyValuePair<string, object> kv in ups) c.Upstreams[kv.Key] = Convert.ToString(kv.Value);
        return c;
    }

    // bridge.js publishes its real endpoint in bridge.port.json — the preferred
    // port in bridge.settings.json is only a hint (it may be busy or moved).
    private static int ResolveBridgePort(string host, int preferred)
    {
        try
        {
            if (File.Exists(PortStatePath))
            {
                string raw = File.ReadAllText(PortStatePath, Encoding.UTF8).TrimStart('\uFEFF');
                Dictionary<string, object> s = (Dictionary<string, object>)Json.DeserializeObject(raw);
                if (s != null && s.ContainsKey("port"))
                {
                    string h = s.ContainsKey("host") ? Convert.ToString(s["host"]) : host;
                    if (h == "0.0.0.0" || h == "::" || h == "[::]") h = "127.0.0.1";
                    int port = Convert.ToInt32(s["port"]);
                    if (port > 0 && port <= 65535 && TestPort(h, port, 400)) return port;
                }
            }
        }
        catch { }

        // old bridge run without a state file: probe listeners inside the fallback window
        int last = Math.Min(65535, preferred + 100);
        List<int> candidates = new List<int>();
        try
        {
            foreach (IPEndPoint ep in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners())
                if (ep.Port >= preferred && ep.Port <= last && !candidates.Contains(ep.Port)) candidates.Add(ep.Port);
        }
        catch { }
        foreach (int port in candidates)
        {
            try
            {
                string st = HttpGet("http://127.0.0.1:" + port + "/__bridge/status", null, 1200);
                if (st != null && st.IndexOf("opencode-happ-bridge", StringComparison.OrdinalIgnoreCase) >= 0) return port;
            }
            catch { }
        }
        return preferred;
    }

    private static void WriteCfg(string text)
    {
        string tmp = CfgPath + ".new";
        File.WriteAllText(tmp, text, new UTF8Encoding(false));
        Exception last = null;
        for (int i = 0; i < 15; i++)
        {
            try { File.Replace(tmp, CfgPath, null); last = null; break; }
            catch (Exception ex) { last = ex; Thread.Sleep(150); }
        }
        if (last != null) throw new Exception("не удалось записать bridge.settings.json: " + last.Message);
    }

    private static void SaveUpstream(string name, string value)
    {
        string raw = File.ReadAllText(CfgPath, Encoding.UTF8).TrimStart('\uFEFF');
        Dictionary<string, object> d = (Dictionary<string, object>)Json.DeserializeObject(raw);
        Dictionary<string, object> ups = (Dictionary<string, object>)d["upstreams"];
        ups[name] = value;
        d["upstreams"] = ups;
        WriteCfg(Json.Serialize(d));
    }

    private static void SetActive(BridgeCfg c, string name)
    {
        string text = File.ReadAllText(CfgPath, Encoding.UTF8);
        string quotedName = Json.Serialize(name);
        string updated = Regex.Replace(text, "(\"active\"\\s*:\\s*)\"[^\"]*\"",
            delegate(Match m) { return m.Groups[1].Value + quotedName; });
        if (updated == text) throw new Exception("в bridge.settings.json не найдено поле active");
        WriteCfg(updated);
        for (int i = 0; i < 20; i++)
        {
            Thread.Sleep(150);
            Dictionary<string, object> st = BridgeStatus(c);
            if (st != null && Convert.ToString(st["active"]) == name) return;
        }
    }

    private static bool IsProxyUrl(string value)
    {
        Uri uri;
        return Uri.TryCreate(value, UriKind.Absolute, out uri) &&
            (uri.Scheme == "http" || uri.Scheme == "socks5" || uri.Scheme == "socks");
    }

    // A CONNECT tunnel keeps the node it was dialed through for its whole life,
    // so after a switch the client would keep egressing from the old IP until it
    // closes the tunnel by itself. Cut them so the next request re-dials.
    private static void ResetTunnels(BridgeCfg c)
    {
        try
        {
            string s = HttpGet("http://" + c.Host + ":" + c.Port + "/__bridge/reset", null, 2500);
            Dictionary<string, object> d = (Dictionary<string, object>)Json.DeserializeObject(s);
            Console.WriteLine("туннели закрыты: " + d["reset"] + " (клиент переподключится через " + d["active"] + ")");
        }
        catch { }
    }

    private static Dictionary<string, object> BridgeStatus(BridgeCfg c)
    {        try
        {
            string s = HttpGet("http://" + c.Host + ":" + c.Port + "/__bridge/status", null, 2500);
            return (Dictionary<string, object>)Json.DeserializeObject(s);
        }
        catch { return null; }
    }

    private static List<NodeInfo> LoadNodes()
    {
        List<NodeInfo> list = new List<NodeInfo>();
        if (!File.Exists(IdxPath)) return list;
        try
        {
            string raw = File.ReadAllText(IdxPath, Encoding.UTF8).TrimStart('\uFEFF');
            Dictionary<string, object> d = (Dictionary<string, object>)Json.DeserializeObject(raw);
            object[] arr = (object[])d["nodes"];
            foreach (object o in arr)
            {
                Dictionary<string, object> m = (Dictionary<string, object>)o;
                NodeInfo n = new NodeInfo();
                n.N = Convert.ToInt32(m["n"]);
                n.Port = Convert.ToInt32(m["port"]);
                n.Country = m.ContainsKey("country") ? Convert.ToString(m["country"]) : "?";
                n.Proto = Convert.ToString(m["proto"]);
                n.Net = Convert.ToString(m["net"]);
                n.Addr = Convert.ToString(m["addr"]);
                n.Port0 = Convert.ToInt32(m["port0"]);
                n.Egress = m.ContainsKey("egressIp") ? Convert.ToString(m["egressIp"]) : "";
                list.Add(n);
            }
        }
        catch { }
        return list;
    }

    private static Dictionary<string, string> NodeCountries(List<NodeInfo> nodes)
    {
        Dictionary<string, string> map = new Dictionary<string, string>();
        foreach (NodeInfo n in nodes)
            if (!string.IsNullOrEmpty(n.Country) && n.Country != "?")
                map["happ-node-" + n.N] = n.Country;
        return map;
    }

    // ---------------------------------------------------------------- сервисы
    private static void EnsureBridge(BridgeCfg c)
    {
        if (TestPort(c.Host, c.Port, 500)) return;
        string node = NodeExe();
        if (node == null) throw new Exception("node.exe не найден (нужен для моста)");
        Console.WriteLine("мост не запущен — стартую node bridge.js ...");
        StartHidden(node, "bridge.js", Path.Combine(Root, "bridge.log"), Path.Combine(Root, "bridge.err.log"));
        DateTime dl = DateTime.Now.AddSeconds(15);
        while (DateTime.Now < dl)
        {
            int port = ResolveBridgePort(c.Host, c.Port);
            if (TestPort(c.Host, port, 300))
            {
                if (port != c.Port)
                    Console.WriteLine("мост поднят на порту " + port + " (порт " + c.Port + " занят — автопоиск сработал)");
                else
                    Console.WriteLine("мост поднят: " + c.Host + ":" + c.Port);
                c.Port = port;
                return;
            }
            Thread.Sleep(250);
        }
        throw new Exception("мост не поднялся, см. bridge.err.log");
    }

    private static void EnsureCompanion()
    {
        if (TestPort("127.0.0.1", 10901, 400) || CompanionPid() != 0) return;
        if (!File.Exists(XrayPath)) throw new Exception("не найден " + XrayPath);
        string cfg = Path.Combine(Root, "companion-xray.json");
        if (!File.Exists(cfg)) throw new Exception("нет companion-xray.json (сначала обновите пул узлов)");
        Console.WriteLine("компаньон-xray не запущен — стартую ...");
        StartHidden(XrayPath, "-c \"" + cfg + "\"",
            Path.Combine(Root, "companion-xray.out.log"), Path.Combine(Root, "companion-xray.err.log"));
        DateTime dl = DateTime.Now.AddSeconds(8);
        while (DateTime.Now < dl)
        {
            if (TestPort("127.0.0.1", 10901, 400)) { Console.WriteLine("компаньон-xray работает"); return; }
            Thread.Sleep(300);
        }
        throw new Exception("компаньон-xray не поднялся, см. companion-xray.err.log");
    }

    private static int CompanionPid()
    {
        List<int> pids = FindPids("xray.exe", "companion-xray.json");
        return pids.Count > 0 ? pids[0] : 0;
    }

    private static string Short(string s, int max)
    {
        if (s == null) return "";
        return s.Length <= max ? s : s.Substring(0, max - 1) + "…";
    }

    // ---------------------------------------------------------------- сканер памяти Happ (нативно)
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public UIntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern int VirtualQueryEx(IntPtr h, IntPtr addr, out MEMORY_BASIC_INFORMATION mbi, int len);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out int read);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern int CloseHandle(IntPtr h);

    private static int IndexOfBytes(byte[] hay, byte[] needle, int start, int end)
    {
        int n = needle.Length;
        byte first = needle[0];
        for (int i = start; i + n <= end; i++)
        {
            if (hay[i] != first) continue;
            int j = 1;
            while (j < n && hay[i + j] == needle[j]) j++;
            if (j == n) return i;
        }
        return -1;
    }

    private static int ScanRegions(int pid, string needle, string outFile, int maxRegionMb)
    {
        IntPtr h = OpenProcess(0x0410, false, pid);
        if (h == IntPtr.Zero) throw new Exception("OpenProcess failed (нужны права на чтение памяти)");
        byte[] nb = Encoding.UTF8.GetBytes(needle);
        ulong addr = 0;
        const ulong MaxAddr = 0x7FFFFFFEFFFF;
        const int ChunkSize = 8 * 1024 * 1024;
        int regions = 0;
        FileStream fs = new FileStream(outFile, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
        try
        {
            while (addr < MaxAddr)
            {
                MEMORY_BASIC_INFORMATION mbi;
                if (VirtualQueryEx(h, (IntPtr)(long)addr, out mbi, System.Runtime.InteropServices.Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION))) == 0) break;
                ulong size = mbi.RegionSize.ToUInt64();
                bool readable = (mbi.State & 0x1000) != 0 && (mbi.Protect & 0x7F) != 0 && (mbi.Protect & 0x100) == 0;
                if (readable && size > 0 && size <= (ulong)maxRegionMb * 1024UL * 1024UL)
                {
                    long baseAddr = (long)mbi.BaseAddress;
                    bool found = false;
                    byte[] carry = new byte[0];
                    ulong offset = 0;

                    // Search in chunks: a 512 MB heap region must not become one
                    // managed allocation. Keep needle.Length - 1 bytes so a match
                    // across a chunk boundary is still found.
                    while (offset < size)
                    {
                        int want = (int)Math.Min((ulong)ChunkSize, size - offset);
                        byte[] chunk = new byte[want];
                        int read;
                        if (!ReadProcessMemory(h, (IntPtr)(baseAddr + (long)offset), chunk, want, out read) || read <= 0) break;

                        int scanLen = carry.Length + read;
                        byte[] scan;
                        if (carry.Length > 0)
                        {
                            scan = new byte[scanLen];
                            Buffer.BlockCopy(carry, 0, scan, 0, carry.Length);
                            Buffer.BlockCopy(chunk, 0, scan, carry.Length, read);
                        }
                        else
                        {
                            scan = chunk;
                        }
                        if (IndexOfBytes(scan, nb, 0, scanLen) >= 0) { found = true; break; }

                        int keep = Math.Min(nb.Length - 1, scanLen);
                        if (keep > 0)
                        {
                            byte[] nextCarry = new byte[keep];
                            Buffer.BlockCopy(scan, scanLen - keep, nextCarry, 0, keep);
                            carry = nextCarry;
                        }
                        else carry = new byte[0];

                        offset += (ulong)read;
                        if (read < want) break;
                    }

                    if (found)
                    {
                        byte[] hdr = Encoding.ASCII.GetBytes("===REGION base=0x" + ((ulong)baseAddr).ToString("X") + " size=" + size + "===\n");
                        fs.Write(hdr, 0, hdr.Length);
                        ulong written = 0;
                        while (written < size)
                        {
                            int want = (int)Math.Min((ulong)ChunkSize, size - written);
                            byte[] chunk = new byte[want];
                            int read;
                            if (!ReadProcessMemory(h, (IntPtr)(baseAddr + (long)written), chunk, want, out read) || read <= 0) break;
                            fs.Write(chunk, 0, read);
                            written += (ulong)read;
                            if (read < want) break;
                        }
                        byte[] tail = Encoding.ASCII.GetBytes("\n===ENDREGION===\n");
                        fs.Write(tail, 0, tail.Length);
                        regions++;
                    }
                }
                addr = (ulong)(long)mbi.BaseAddress + size;
                if (size == 0) addr += 0x1000;
            }
        }
        finally { fs.Close(); CloseHandle(h); }
        return regions;
    }

    private static int RunNode(string args)
    {
        string node = NodeExe();
        if (node == null) throw new Exception("node.exe не найден (нужен для пайплайна узлов)");
        ProcessStartInfo psi = new ProcessStartInfo(node, args);
        psi.WorkingDirectory = Root;
        psi.UseShellExecute = false;
        Process p = Process.Start(psi);
        p.WaitForExit();
        return p.ExitCode;
    }

    private static void RestartCompanion()
    {
        StopCompanion();
        Thread.Sleep(300);
        EnsureCompanion();
    }

    private static int RefreshPoolNative()
    {
        Process[] happ = Process.GetProcessesByName("Happ");
        if (happ.Length == 0) { Console.WriteLine("Happ.exe не запущен — нечего сканировать"); return 1; }
        string dir = @"C:\Temp\opencode";
        try { Directory.CreateDirectory(dir); } catch { dir = Path.GetTempPath(); }
        string dump = Path.Combine(dir, "happ-outbounds.bin");

        Console.WriteLine("скан памяти Happ.exe (pid " + happ[0].Id + ") ...");
        int regions = ScanRegions(happ[0].Id, "\"outbounds\"", dump, 512);
        Console.WriteLine("регионов с конфигами: " + regions + " -> " + dump);
        if (regions == 0) { Console.WriteLine("ничего не найдено — прогрейте узлы в Happ и повторите"); return 1; }

        Console.WriteLine("разбор пула (nodes-pipeline.js) ...");
        if (RunNode("nodes-pipeline.js \"" + dump + "\"") != 0) { Console.WriteLine("пайплайн завершился с ошибкой"); return 1; }

        Console.WriteLine("перезапуск компаньона-xray ...");
        RestartCompanion();

        Console.WriteLine("гео-проверка узлов (nodes-geo.js) ...");
        RunNode("nodes-geo.js");

        Console.WriteLine("отсев мёртвых узлов ...");
        RunNode("nodes-pipeline.js \"" + dump + "\"");
        RestartCompanion();

        Console.WriteLine();
        ListNodes(true);
        return 0;
    }

    // ---------------------------------------------------------------- действия
    private static void PrintHeader()
    {
        BridgeCfg c = LoadCfg();
        bool up = TestPort(c.Host, c.Port, 300);
        Dictionary<string, object> st = up ? BridgeStatus(c) : null;
        string active = st != null ? Convert.ToString(st["active"]) : c.Active;
        string upstream = st != null ? Convert.ToString(st["upstream"]) : "(мост остановлен)";
        List<NodeInfo> nodes = LoadNodes();
        int cpid = CompanionPid();
        Process[] oc = Process.GetProcessesByName("OpenCode");

        Console.WriteLine();
        Console.WriteLine("================= OpenCode + Happ =================");
        Console.WriteLine("  Мост:      " + (up ? "работает " + c.Host + ":" + c.Port : "остановлен"));
        Console.WriteLine("  Апстрим:   " + active + "  (" + upstream + ")");
        Console.WriteLine("  Узлы:      " + nodes.Count + (cpid != 0 ? "  (компаньон-xray pid " + cpid + ")" : "  (компаньон-xray не запущен)"));
        Console.WriteLine("  OpenCode:  " + (oc.Length > 0 ? "запущен (pid " + oc[0].Id + (oc.Length > 1 ? " +" + (oc.Length - 1) : "") + ")" : "не запущен"));
        Console.WriteLine("==================================================");
    }

    private static void ListNodes(bool withEgressNote)
    {
        BridgeCfg c = LoadCfg();
        Dictionary<string, object> st = TestPort(c.Host, c.Port, 300) ? BridgeStatus(c) : null;
        string active = st != null ? Convert.ToString(st["active"]) : c.Active;
        List<NodeInfo> nodes = LoadNodes();

        Console.WriteLine("Узлы подписки Happ (компаньон-xray):");
        if (nodes.Count == 0)
        {
            Console.WriteLine("  список пуст — пункт [5] «Обновить пул узлов»");
            return;
        }
        foreach (NodeInfo n in nodes)
        {
            string mark = active == "happ-node-" + n.N ? "  <- активен" : "";
            string eg = string.IsNullOrEmpty(n.Egress) ? "" : "  выход " + n.Egress;
            Console.WriteLine(string.Format("  [{0}] порт {1}  {2,-12} {3}/{4}  {5}:{6}{7}{8}",
                n.N, n.Port, n.Country, n.Proto, n.Net, n.Addr, n.Port0, eg, mark));
        }
        if (withEgressNote)
        {
            Console.WriteLine();
            Console.WriteLine("Мост: " + active);
            string ip = TestPort(c.Host, c.Port, 300) ? EgressThroughBridge(c) : null;
            Console.WriteLine("Выходной IP через мост: " + (ip != null ? ip : "(нет ответа)"));
        }
    }

    private static void UseNode(int idx, bool verify)
    {
        BridgeCfg c = LoadCfg();
        List<NodeInfo> nodes = LoadNodes();
        NodeInfo node = nodes.FirstOrDefault(x => x.N == idx);
        if (node == null)
        {
            Console.WriteLine("узел #" + idx + " не найден (1.." + nodes.Count + ")");
            return;
        }
        EnsureBridge(c);
        EnsureCompanion();
        string before = verify ? EgressThroughBridge(c) : null;
        Console.WriteLine(string.Format("переключаю: {0} -> happ-node-{1}  [{2}/{3}] {4}:{5} ...",
            before ?? "?", node.N, node.Proto, node.Net, node.Addr, node.Port0));
        SetActive(c, "happ-node-" + idx);
        ResetTunnels(c);
        Dictionary<string, object> st = BridgeStatus(c);
        if (st != null) Console.WriteLine("подтверждено: active=" + st["active"] + "  upstream=" + st["upstream"]);
        if (!verify) return;
        Thread.Sleep(400);
        string after = EgressThroughBridge(c);
        if (after == null) { Console.WriteLine("ОШИБКА: после переключения мост не отвечает"); return; }
        Console.WriteLine("выходной IP теперь: " + after);
        if (before != null && after != before) Console.WriteLine("  (" + before + " -> " + after + " — переключение реальное)");
        else if (before == after) Console.WriteLine("  ! IP не изменился: возможно, узлы выходят с одного IP или узел не принял соединение");
    }

    private static void ListUpstreams()
    {
        BridgeCfg c = LoadCfg();
        Dictionary<string, string> countries = NodeCountries(LoadNodes());
        Console.WriteLine("Апстримы (текущий: " + c.Active + "):");
        int i = 0;
        foreach (KeyValuePair<string, string> kv in c.Upstreams)
        {
            i++;
            string label = countries.ContainsKey(kv.Key) ? "   (" + countries[kv.Key] + ")" : "";
            string mark = kv.Key == c.Active ? "   <- активен" : "";
            Console.WriteLine(string.Format("  [{0}] {1,-12} {2}{3}{4}", i, kv.Key, kv.Value, label, mark));
        }
    }

    private static void SwitchByName(string name)
    {
        BridgeCfg c = LoadCfg();
        string activeName = name;
        if (!c.Upstreams.ContainsKey(name))
        {
            if (name == "direct")
            {
                c.Upstreams[name] = "direct";
                SaveUpstream(name, "direct");
            }
            else if (IsProxyUrl(name))
            {
                activeName = "custom";
                int suffix = 1;
                while (c.Upstreams.ContainsKey(activeName) && c.Upstreams[activeName] != name)
                    activeName = "custom-" + (++suffix);
                if (!c.Upstreams.ContainsKey(activeName))
                {
                    c.Upstreams[activeName] = name;
                    SaveUpstream(activeName, name);
                }
            }
            else
            {
                Console.WriteLine("неизвестный апстрим: " + name + " (нужен http://, socks5:// или direct)");
                return;
            }
        }
        EnsureBridge(c);
        string before = EgressThroughBridge(c);
        SetActive(c, activeName);
        ResetTunnels(c);
        Dictionary<string, object> st = BridgeStatus(c);
        if (st != null) Console.WriteLine("активный апстрим: " + st["active"] + " (" + st["upstream"] + ")" + (activeName != name ? " -> " + name : ""));
        Thread.Sleep(300);
        string after = EgressThroughBridge(c);
        Console.WriteLine("выходной IP: " + (after ?? "(нет ответа)") + (before != null && after != before ? "  (был " + before + ")" : ""));
    }

    private static void LaunchOpenCode(bool restart)
    {
        BridgeCfg c = LoadCfg();
        EnsureBridge(c);
        string exe = FindOpenCode();
        if (exe == null) throw new Exception("OpenCode.exe не найден");

        Process[] running = Process.GetProcessesByName("OpenCode");
        if (running.Length > 0)
        {
            if (!restart)
            {
                Console.WriteLine("OpenCode уже запущен (pid " + running[0].Id + ").");
                Console.WriteLine("Прокси задаётся при старте процесса: выберите [2] «Перезапустить через мост»,");
                Console.WriteLine("либо закройте OpenCode вручную и снова [1].");
                return;
            }
            if (InsideOpenCode())
            {
                Console.WriteLine("ОТМЕНА: эта консоль запущена ВНУТРИ OpenCode — перезапуск убьёт сессию.");
                Console.WriteLine("Запустите OpenCode-Happ.exe из отдельного окна (Пуск/проводник) и повторите.");
                return;
            }
            Console.WriteLine("останавливаю окно OpenCode ...");
            StopProcesses("OpenCode");
            Thread.Sleep(500);
            Console.WriteLine("останавливаю фоновый opencode-cli (сервер сессий) ...");
            StopProcesses("opencode-cli");
        }
        else
        {
            // окно закрыто, но сервер сессий мог остаться — новый Desktop переиспользует его БЕЗ прокси
            if (Process.GetProcessesByName("opencode-cli").Length > 0)
            {
                Console.WriteLine("фоновый opencode-cli остался от прошлого запуска — останавливаю,");
                Console.WriteLine("чтобы он поднялся заново с настройками прокси ...");
                StopProcesses("opencode-cli");
            }
        }
        Thread.Sleep(800);

        string url = "http://" + c.Host + ":" + c.Port;
        SyncServiceProxy(url);
        ProcessStartInfo psi = new ProcessStartInfo(exe, "--proxy-server=" + url);
        psi.UseShellExecute = false;
        psi.EnvironmentVariables["HTTP_PROXY"] = url;
        psi.EnvironmentVariables["HTTPS_PROXY"] = url;
        psi.EnvironmentVariables["ALL_PROXY"] = url;
        psi.EnvironmentVariables["NO_PROXY"] = "127.0.0.1,localhost,::1";
        Process.Start(psi);
        Console.WriteLine("OpenCode запущен через мост " + url + "  (апстрим: " + c.Active + ")");
    }

    private static bool StopProcesses(string name)
    {
        for (int round = 0; round < 8; round++)
        {
            Process[] ps = Process.GetProcessesByName(name);
            if (ps.Length == 0) return true;
            foreach (Process p in ps)
            {
                try { p.Kill(); } catch { }
            }
            Thread.Sleep(400);
        }
        bool gone = Process.GetProcessesByName(name).Length == 0;
        if (!gone) Console.WriteLine("  ! не удалось остановить все процессы " + name);
        return gone;
    }

    private static void StopBridge()
    {
        List<int> pids = FindPids("node.exe", "bridge.js");
        if (pids.Count == 0) { Console.WriteLine("мост не запущен"); return; }
        foreach (int pid in pids)
            try { Process.GetProcessById(pid).Kill(); Console.WriteLine("остановлен мост pid " + pid); }
            catch (Exception ex) { Console.WriteLine("не удалось остановить pid " + pid + ": " + ex.Message); }
    }

    private static void StopCompanion()
    {
        List<int> pids = FindPids("xray.exe", "companion-xray.json");
        if (pids.Count == 0) { Console.WriteLine("компаньон-xray не запущен"); return; }
        foreach (int pid in pids)
            try { Process.GetProcessById(pid).Kill(); Console.WriteLine("остановлен компаньон-xray pid " + pid); }
            catch (Exception ex) { Console.WriteLine("не удалось остановить pid " + pid + ": " + ex.Message); }
    }

    private static int RefreshPool()
    {
        return RefreshPoolNative();
    }

    private static void ShowStatus()
    {
        PrintHeader();
        BridgeCfg c = LoadCfg();
        string ip = TestPort(c.Host, c.Port, 300) ? EgressThroughBridge(c) : null;
        Console.WriteLine("Выходной IP через мост: " + (ip ?? "(нет ответа)"));
        List<NodeInfo> nodes = LoadNodes();
        Console.WriteLine("Узлов в списке: " + nodes.Count + ", стран: " +
            string.Join(", ", nodes.Select(x => x.Country).Distinct().ToArray()));
        int cpid = CompanionPid();
        Console.WriteLine("Компаньон-xray: " + (cpid != 0 ? "pid " + cpid : "не запущен"));
        if (cpid != 0)
        {
            List<string> ports = new List<string>();
            foreach (NodeInfo n in nodes) if (TestPort("127.0.0.1", n.Port, 200)) ports.Add(n.Port.ToString());
            Console.WriteLine("Слушают порты: " + (ports.Count > 0 ? string.Join(", ", ports.ToArray()) : "(нет)"));
        }
        Console.WriteLine("Каталог: " + Root);
    }

    // ---------------------------------------------------------------- меню
    private static int Menu()
    {
        while (true)
        {
            PrintHeader();
            Console.WriteLine();
            Console.WriteLine("  [1] Запустить OpenCode через мост");
            Console.WriteLine("  [2] Перезапустить OpenCode через мост");
            Console.WriteLine("  [3] Узлы Happ: список и переключение");
            Console.WriteLine("  [4] Сменить апстрим (happ-http / happ-socks / direct)");
            Console.WriteLine("  [5] Обновить пул узлов из памяти Happ");
            Console.WriteLine("  [6] Статус и проверка выхода");
            Console.WriteLine("  [7] Остановить мост");
            Console.WriteLine("  [0] Выход");
            Console.WriteLine();
            Console.Write("выбор: ");
            string ch = (Console.ReadLine() ?? "").Trim();
            Console.WriteLine();
            try
            {
                if (ch == "0") return 0;
                if (ch == "1") { LaunchOpenCode(false); Pause(); }
                else if (ch == "2") { LaunchOpenCode(true); Pause(); }
                else if (ch == "3") { NodesMenu(); }
                else if (ch == "4") { UpstreamsMenu(); }
                else if (ch == "5") { RefreshPool(); Pause(); }
                else if (ch == "6") { ShowStatus(); Pause(); }
                else if (ch == "7") { StopBridge(); Pause(); }
                else if (ch.Length > 0) Console.WriteLine("не понял выбор");
            }
            catch (Exception ex)
            {
                Console.WriteLine("Ошибка: " + ex.Message);
                Pause();
            }
        }
    }

    private static void NodesMenu()
    {
        while (true)
        {
            Console.WriteLine();
            ListNodes(true);
            Console.WriteLine();
            Console.WriteLine("  [номер] переключить мост на этот узел");
            Console.WriteLine("  [r]     обновить пул из памяти Happ");
            Console.WriteLine("  [0]     назад");
            Console.Write("узел: ");
            string ch = (Console.ReadLine() ?? "").Trim();
            Console.WriteLine();
            if (ch == "0" || ch == "") return;
            if (ch.Equals("r", StringComparison.OrdinalIgnoreCase)) { RefreshPool(); Pause(); continue; }
            int n;
            if (int.TryParse(ch, out n)) { UseNode(n, true); Pause(); }
            else Console.WriteLine("введите номер узла, r или 0");
        }
    }

    private static void UpstreamsMenu()
    {
        while (true)
        {
            Console.WriteLine();
            ListUpstreams();
            Console.WriteLine();
            Console.WriteLine("  [номер] переключить   [u] свой URL   [0] назад");
            Console.Write("апстрим: ");
            string ch = (Console.ReadLine() ?? "").Trim();
            Console.WriteLine();
            if (ch == "0" || ch == "") return;
            if (ch.Equals("u", StringComparison.OrdinalIgnoreCase))
            {
                Console.Write("URL (http://... | socks5://... | direct): ");
                string url = (Console.ReadLine() ?? "").Trim();
                if (url.Length > 0)
                {
                    if (!url.StartsWith("http") && !url.StartsWith("socks") && url != "direct")
                    {
                        Console.WriteLine("поддерживаются http://, socks5:// или direct");
                        continue;
                    }
                    SwitchByName(url);
                    Pause();
                }
                continue;
            }
            int n;
            if (int.TryParse(ch, out n))
            {
                BridgeCfg c = LoadCfg();
                if (n >= 1 && n <= c.Upstreams.Count)
                {
                    string name = c.Upstreams.Keys.ElementAt(n - 1);
                    SwitchByName(name);
                    Pause();
                }
                else Console.WriteLine("нет такого номера");
            }
        }
    }

    private static void Pause()
    {
        Console.WriteLine();
        Console.Write("Enter — продолжить");
        Console.ReadLine();
    }

    // ---------------------------------------------------------------- main
    private static int Main(string[] args)
    {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; } catch { }
        try
        {
            if (args.Length == 0) return Menu();
            string a = args[0].ToLowerInvariant();
            if (a == "--menu") return Menu();
            if (a == "--list") { ListNodes(true); return 0; }
            if (a == "--use" && args.Length > 1) { UseNode(Convert.ToInt32(args[1]), true); return 0; }
            if (a == "--status") { ShowStatus(); return 0; }
            if (a == "--upstreams") { ListUpstreams(); return 0; }
            if (a == "--upstream" && args.Length > 1) { SwitchByName(args[1]); return 0; }
            if (a == "--launch") { LaunchOpenCode(false); return 0; }
            if (a == "--restart") { LaunchOpenCode(true); return 0; }
            if (a == "--refresh") return RefreshPool();
            if (a == "--ensure") { BridgeCfg c = LoadCfg(); EnsureBridge(c); EnsureCompanion(); return 0; }
            if (a == "--stop-bridge") { StopBridge(); return 0; }
            if (a == "--stop-companion") { StopCompanion(); return 0; }
            if (a == "--help" || a == "-h" || a == "/?")
            {
                Console.WriteLine("OpenCode-Happ.exe - единый лаунчер OpenCode + переключатель узлов Happ");
                Console.WriteLine();
                Console.WriteLine("  без аргументов     интерактивное меню");
                Console.WriteLine("  --menu             интерактивное меню");
                Console.WriteLine("  --launch           запустить OpenCode через мост");
                Console.WriteLine("  --restart          перезапустить OpenCode через мост");
                Console.WriteLine("  --list             список узлов + текущий выход");
                Console.WriteLine("  --use N            переключить мост на узел N");
                Console.WriteLine("  --upstreams        список апстримов");
                Console.WriteLine("  --upstream NAME    переключить апстрим (happ-http, direct, URL)");
                Console.WriteLine("  --status           статус моста/узлов/OpenCode + egress IP");
                Console.WriteLine("  --refresh          обновить пул узлов из памяти Happ");
                Console.WriteLine("  --ensure           поднять мост и компаньон-xray");
                Console.WriteLine("  --stop-bridge      остановить мост");
                Console.WriteLine("  --stop-companion   остановить компаньон-xray");
                return 0;
            }
            Console.WriteLine("неизвестный аргумент: " + args[0] + " (см. --help)");
            return 2;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Ошибка: " + ex.Message);
            return 1;
        }
    }
}
