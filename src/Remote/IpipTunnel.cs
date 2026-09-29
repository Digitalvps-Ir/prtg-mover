// IP-in-IP (protocol 4) tunnel for PRTG Mover.
// Wintun carries only 10.66.67.0/24. The outer header is added by Windows on a raw protocol-4 socket.
// This program never installs a default route.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

internal static class IpipTunnel
{
    const string AdapterName = "prtg-ipip";
    static readonly Guid AdapterGuid = new Guid("8f2e3c10-5b4a-4d1e-9c77-0a1b2c3d4e5f");
    static volatile bool _run = true;
    static IntPtr _adapter;
    static IntPtr _session;
    static Socket _raw;
    static uint _localPublic;
    static readonly Dictionary<uint, uint> PeerByInner = new Dictionary<uint, uint>();
    static readonly HashSet<uint> PeerPublic = new HashSet<uint>();
    static string _logPath;
    static string _readyPath;

    static int Main(string[] args)
    {
        if (args.Length < 1) return 2;
        string dir = Path.GetDirectoryName(Path.GetFullPath(args[0]));
        _logPath = Path.Combine(dir, "tunnel.log");
        _readyPath = Path.Combine(dir, "ready.txt");
        try { if (File.Exists(_readyPath)) File.Delete(_readyPath); } catch { }
        try
        {
            string localTunnel = null;
            string localPublic = null;
            foreach (string line in File.ReadAllLines(args[0]))
            {
                int eq = line.IndexOf('=');
                if (eq < 1) continue;
                string key = line.Substring(0, eq).Trim();
                string val = line.Substring(eq + 1).Trim();
                if (key == "localTunnel") localTunnel = val;
                else if (key == "localPublic") localPublic = val;
                else if (key == "peer")
                {
                    string[] parts = val.Split(',');
                    if (parts.Length != 2) throw new InvalidOperationException("bad peer");
                    uint pub = Pack(parts[1].Trim());
                    PeerByInner[Pack(parts[0].Trim())] = pub;
                    PeerPublic.Add(pub);
                }
            }
            if (localTunnel == null || localPublic == null || PeerByInner.Count == 0)
                throw new InvalidOperationException("tunnel config is incomplete");
            _localPublic = Pack(localPublic);

            SetDllDirectory(dir);
            IntPtr guid = Marshal.AllocHGlobal(16);
            try
            {
                Marshal.Copy(AdapterGuid.ToByteArray(), 0, guid, 16);
                _adapter = WintunCreateAdapter(AdapterName, "IPIP", guid);
            }
            finally { Marshal.FreeHGlobal(guid); }
            if (_adapter == IntPtr.Zero) throw new InvalidOperationException("WintunCreateAdapter failed: " + Marshal.GetLastWin32Error());

            Run("interface ipv4 set address name=\"" + AdapterName + "\" static " + localTunnel + " 255.255.255.0 none");
            Run("interface ipv4 set subinterface \"" + AdapterName + "\" mtu=1400 store=persistent");
            Run("interface ipv4 set interface \"" + AdapterName + "\" metric=9000");

            _session = WintunStartSession(_adapter, 0x200000);
            if (_session == IntPtr.Zero) throw new InvalidOperationException("WintunStartSession failed: " + Marshal.GetLastWin32Error());

            _raw = new Socket(AddressFamily.InterNetwork, SocketType.Raw, (ProtocolType)4);
            _raw.Bind(new IPEndPoint(IPAddress.Parse(localPublic), 0));
            _raw.ReceiveTimeout = 200;

            File.WriteAllText(_readyPath, localTunnel);
            Log("IPIP up " + localTunnel + " via " + localPublic + " peers " + PeerByInner.Count);

            Thread rx = new Thread(ReceiveLoop);
            rx.IsBackground = true;
            rx.Start();
            SendLoop();
            return 0;
        }
        catch (Exception ex)
        {
            Log(ex.ToString());
            return 1;
        }
        finally
        {
            _run = false;
            try { if (_raw != null) _raw.Close(); } catch { }
            if (_session != IntPtr.Zero) WintunEndSession(_session);
            if (_adapter != IntPtr.Zero) WintunCloseAdapter(_adapter);
        }
    }

    static void SendLoop()
    {
        IntPtr wait = WintunGetReadWaitEvent(_session);
        while (_run)
        {
            uint size;
            IntPtr pkt = WintunReceivePacket(_session, out size);
            if (pkt == IntPtr.Zero)
            {
                if (Marshal.GetLastWin32Error() == 259) WaitForSingleObject(wait, 200);
                continue;
            }
            int n = (int)size;
            byte[] inner = new byte[n];
            Marshal.Copy(pkt, inner, 0, n);
            WintunReleaseReceivePacket(_session, pkt);
            if (n < 20 || (inner[0] >> 4) != 4) continue;
            if (inner[9] == 4) continue;
            uint dest = ReadU32(inner, 16);
            uint peer;
            if (!PeerByInner.TryGetValue(dest, out peer)) continue;
            try { _raw.SendTo(inner, 0, n, SocketFlags.None, new IPEndPoint(Unpack(peer), 0)); }
            catch (Exception ex) { Log("send: " + ex.Message); }
        }
    }

    static void ReceiveLoop()
    {
        byte[] buf = new byte[65535];
        while (_run)
        {
            int n;
            try { n = _raw.Receive(buf); }
            catch (SocketException) { continue; }
            catch { if (!_run) return; continue; }
            if (n < 40) continue;
            int ihl = (buf[0] & 0x0F) * 4;
            if (ihl < 20 || buf[9] != 4 || n < ihl + 20) continue;
            uint src = ReadU32(buf, 12);
            if (src == _localPublic || !PeerPublic.Contains(src)) continue;
            if (ReadU32(buf, 16) != _localPublic) continue;
            int inner = n - ihl;
            IntPtr mem = WintunAllocateSendPacket(_session, (uint)inner);
            if (mem == IntPtr.Zero) continue;
            Marshal.Copy(buf, ihl, mem, inner);
            WintunSendPacket(_session, mem);
        }
    }

    static void Run(string args)
    {
        Process p = Process.Start(new ProcessStartInfo
        {
            FileName = "netsh",
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        p.WaitForExit();
        if (p.ExitCode != 0) Log("netsh exit " + p.ExitCode + " " + args);
    }

    static uint Pack(string ip)
    {
        byte[] b = IPAddress.Parse(ip).GetAddressBytes();
        return ReadU32(b, 0);
    }

    static IPAddress Unpack(uint value)
    {
        return new IPAddress(new byte[] { (byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value });
    }

    static uint ReadU32(byte[] b, int o)
    {
        return (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
    }

    static void Log(string message)
    {
        try { File.AppendAllText(_logPath, DateTime.UtcNow.ToString("o") + " " + message + "\r\n"); } catch { }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string path);
    [DllImport("kernel32.dll")]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("wintun.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunCreateAdapter", SetLastError = true)]
    static extern IntPtr WintunCreateAdapter(string name, string tunnelType, IntPtr requestedGuid);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunCloseAdapter")]
    static extern void WintunCloseAdapter(IntPtr adapter);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunStartSession", SetLastError = true)]
    static extern IntPtr WintunStartSession(IntPtr adapter, uint capacity);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunEndSession")]
    static extern void WintunEndSession(IntPtr session);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunGetReadWaitEvent")]
    static extern IntPtr WintunGetReadWaitEvent(IntPtr session);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunReceivePacket", SetLastError = true)]
    static extern IntPtr WintunReceivePacket(IntPtr session, out uint packetSize);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunReleaseReceivePacket")]
    static extern void WintunReleaseReceivePacket(IntPtr session, IntPtr packet);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunAllocateSendPacket", SetLastError = true)]
    static extern IntPtr WintunAllocateSendPacket(IntPtr session, uint packetSize);
    [DllImport("wintun.dll", CallingConvention = CallingConvention.StdCall, EntryPoint = "WintunSendPacket")]
    static extern void WintunSendPacket(IntPtr session, IntPtr packet);
}
