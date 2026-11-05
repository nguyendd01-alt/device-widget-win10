// Backend for the Device Widget: Bluetooth / USB input devices, audio, camera,
// Wi-Fi, radios, brightness, media player and network speed.
// Compiled by DeviceWidget.ps1 with the .NET Framework csc.exe (C# 5) against the
// WinRT metadata that ships with Windows 10, so nothing extra has to be installed.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Windows.Foundation;
using Windows.Devices.Radios;
using Windows.Devices.WiFi;
using Windows.Media.Control;
using Windows.Security.Credentials;
using Windows.Storage.Streams;

namespace DeviceWidget
{
    // ====================================================================== data
    public class BtDevice
    {
        public string InstanceId;
        public string ContainerId = "";
        public string Name;
        public string Category = "";
        public string Kind = "other";   // keyboard | mouse | headphones | phone | other
        public bool Connected;
        public int Battery = -1;
    }

    public class InputDevice
    {
        public string Id;
        public string Name;
        public string Kind;             // keyboard | mouse
    }

    public class AudioInfo
    {
        public bool Present;
        public string Name = "";
        public int Volume = -1;
        public bool Muted;
        public float Peak;
    }

    public class AudioEndpoint
    {
        public string Id;
        public string Name;
        public bool IsDefault;
    }

    public class UsageInfo
    {
        public bool InUse;
        public List<string> Apps = new List<string>();
    }

    public class NetState
    {
        public bool Ready;
        public bool HasBt, BtOn;
        public bool HasWifiRadio, WifiOn;
        public bool HasWifi, Connected;
        public string Ssid = "";
        public int Bars = -1;
        public bool Ethernet;
        public List<EthAdapter> EthAdapters = new List<EthAdapter>();
    }

    public class EthAdapter
    {
        public string Name = "", Description = "", Ip = "", Mac = "";
        public bool Up;
        public long SpeedMbps;
    }

    public class SysStats
    {
        public int Cpu = -1;                 // %
        public int RamPercent = -1;
        public double RamUsedGb, RamTotalGb;
        public bool HasBattery;
        public int Battery = -1;             // %
        public bool Charging, OnAc;
    }

    public class WifiNet
    {
        public string Ssid;
        public int Bars;
        public bool Secured;
    }

    public class MediaInfo
    {
        public bool Has;
        public string App = "", Title = "", Artist = "";
        public bool Playing;
        public byte[] Thumb;
        public int Version;
    }

    // ============================================================ WinRT helpers
    static class Wrt
    {
        public static T W<T>(IAsyncOperation<T> op) { return W(op, 15000); }

        public static T W<T>(IAsyncOperation<T> op, int ms)
        {
            var ev = new ManualResetEvent(false);
            op.Completed = delegate { ev.Set(); };
            if (!ev.WaitOne(ms)) { try { op.Cancel(); } catch { } throw new TimeoutException(); }
            return op.GetResults();
        }

        public static void W(IAsyncAction act, int ms)
        {
            var ev = new ManualResetEvent(false);
            act.Completed = delegate { ev.Set(); };
            if (!ev.WaitOne(ms)) { try { act.Cancel(); } catch { } throw new TimeoutException(); }
            act.GetResults();
        }
    }

    // ================================================================ devices
    public static class Devices
    {
        [StructLayout(LayoutKind.Sequential)]
        struct DEVPROPKEY { public Guid fmtid; public uint pid; }

        static DEVPROPKEY Key(string g, uint pid) { DEVPROPKEY k; k.fmtid = new Guid(g); k.pid = pid; return k; }

        static readonly DEVPROPKEY PKEY_FriendlyName = Key("a45c254e-df1c-4efd-8020-67d146a850e0", 14);
        static readonly DEVPROPKEY PKEY_DeviceDesc = Key("a45c254e-df1c-4efd-8020-67d146a850e0", 2);
        static readonly DEVPROPKEY PKEY_BusReportedDesc = Key("540b947e-8b40-45bc-a8a2-6a0b894cbda2", 4);
        static readonly DEVPROPKEY PKEY_Parent = Key("4340a6c5-93fa-4706-972c-7b648008a5a7", 8);
        static readonly DEVPROPKEY PKEY_ContainerId = Key("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c", 2);
        static readonly DEVPROPKEY PKEY_IsConnected = Key("83da6326-97a6-4088-9453-a1923f573b29", 15);
        static readonly DEVPROPKEY PKEY_Battery = Key("104ea319-6ee2-4701-bd47-8ddbf425bbe5", 2);
        static readonly DEVPROPKEY PKEY_ContainerCategory = Key("78c34fc8-104a-4aca-9ea4-524d52996e57", 90);

        const string CLASS_CAMERA = "{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}";
        const string CLASS_IMAGE = "{6bdd1fc6-810f-11d0-bec7-08002be2092f}";
        const string CLASS_KEYBOARD = "{4d36e96b-e325-11ce-bfc1-08002be10318}";
        const string CLASS_MOUSE = "{4d36e96f-e325-11ce-bfc1-08002be10318}";

        const uint FILTER_ENUMERATOR = 0x1, FILTER_PRESENT = 0x100, FILTER_CLASS = 0x200;

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_ID_List_SizeW(out uint len, string filter, uint flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_ID_ListW(string filter, char[] buffer, uint len, uint flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Locate_DevNodeW(out uint devInst, string id, uint flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_DevNode_PropertyW(uint devInst, ref DEVPROPKEY key, out uint type, byte[] buf, ref uint size, uint flags);

        static List<string> IdList(string filter, uint flags)
        {
            var result = new List<string>();
            uint len;
            if (CM_Get_Device_ID_List_SizeW(out len, filter, flags) != 0 || len == 0) return result;
            var buf = new char[len];
            if (CM_Get_Device_ID_ListW(filter, buf, len, flags) != 0) return result;
            foreach (var s in new string(buf).Split('\0')) if (s.Length > 0) result.Add(s);
            return result;
        }

        static byte[] Prop(uint dev, DEVPROPKEY key)
        {
            uint size = 0, type;
            CM_Get_DevNode_PropertyW(dev, ref key, out type, null, ref size, 0);
            if (size == 0) return null;
            var buf = new byte[size];
            if (CM_Get_DevNode_PropertyW(dev, ref key, out type, buf, ref size, 0) != 0) return null;
            return buf;
        }

        static string PropString(uint dev, DEVPROPKEY key)
        {
            var b = Prop(dev, key);
            if (b == null) return "";
            var parts = System.Text.Encoding.Unicode.GetString(b).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
            return string.Join(";", parts);
        }

        static bool PropBool(uint dev, DEVPROPKEY key)
        {
            var b = Prop(dev, key);
            return b != null && b.Length > 0 && b[0] != 0;
        }

        static int PropInt(uint dev, DEVPROPKEY key)
        {
            var b = Prop(dev, key);
            if (b == null || b.Length == 0) return -1;
            if (b.Length >= 4) return BitConverter.ToInt32(b, 0);
            if (b.Length >= 2) return BitConverter.ToInt16(b, 0);
            return b[0];
        }

        static string PropGuid(uint dev, DEVPROPKEY key)
        {
            var b = Prop(dev, key);
            if (b == null || b.Length != 16) return "";
            return new Guid(b).ToString("B");
        }

        static string Classify(string category, string name)
        {
            string c = (category ?? "").ToLowerInvariant();
            string n = (name ?? "").ToLowerInvariant();
            if (c.Contains("keyboard")) return "keyboard";
            if (c.Contains("mouse") || c.Contains("touchpad") || c.Contains("pen")) return "mouse";
            if (c.Contains("audio") || c.Contains("headphone") || c.Contains("headset") || c.Contains("speaker")) return "headphones";
            if (c.Contains("phone")) return "phone";
            if (n.Contains("keyboard") || n.Contains("keys")) return "keyboard";
            if (n.Contains("mouse") || n.Contains("trackpad")) return "mouse";
            string[] audio = { "bud", "pod", "headphone", "headset", "earphone", "tai nghe", "wh-", "wf-", "jbl", "audio", "sound" };
            foreach (var a in audio) if (n.Contains(a)) return "headphones";
            return "other";
        }

        public static List<BtDevice> GetBluetooth()
        {
            var byName = new Dictionary<string, BtDevice>(StringComparer.OrdinalIgnoreCase);
            var order = new List<BtDevice>();
            foreach (var en in new[] { "BTHENUM", "BTHLE" })
            {
                foreach (var id in IdList(en, FILTER_ENUMERATOR | FILTER_PRESENT))
                {
                    if (!id.StartsWith(en + "\\DEV_", StringComparison.OrdinalIgnoreCase)) continue;
                    uint dn;
                    if (CM_Locate_DevNodeW(out dn, id, 0) != 0) continue;
                    var d = new BtDevice();
                    d.InstanceId = id;
                    d.Name = PropString(dn, PKEY_FriendlyName);
                    if (d.Name.Length == 0) d.Name = "Bluetooth";
                    d.ContainerId = PropGuid(dn, PKEY_ContainerId);
                    d.Category = PropString(dn, PKEY_ContainerCategory);
                    d.Connected = PropBool(dn, PKEY_IsConnected);
                    d.Battery = PropInt(dn, PKEY_Battery);
                    if (d.Battery > 100) d.Battery = -1;
                    d.Kind = Classify(d.Category, d.Name);

                    BtDevice prev;
                    if (byName.TryGetValue(d.Name, out prev))
                    {
                        prev.Connected = prev.Connected || d.Connected;
                        if (d.Battery > prev.Battery) prev.Battery = d.Battery;
                        if (prev.Kind == "other") prev.Kind = d.Kind;
                    }
                    else { byName[d.Name] = d; order.Add(d); }
                }
            }
            return order;
        }

        /// <summary>Keyboards and mice plugged in over USB (wired or a 2.4 GHz receiver).</summary>
        public static List<InputDevice> GetUsbInputs()
        {
            var list = new List<InputDevice>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var pair in new[] { new[] { CLASS_KEYBOARD, "keyboard" }, new[] { CLASS_MOUSE, "mouse" } })
            {
                foreach (var id in IdList(pair[0], FILTER_CLASS | FILTER_PRESENT))
                {
                    string cur = id, usb = null;
                    for (int depth = 0; depth < 12 && !string.IsNullOrEmpty(cur); depth++)
                    {
                        string up = cur.ToUpperInvariant();
                        if (up.StartsWith("BTHENUM") || up.StartsWith("BTHLE")) { usb = null; break; }
                        if (up.StartsWith("USB\\VID_") && !up.Contains("&MI_")) { usb = cur; break; }
                        if (up.StartsWith("USB\\ROOT_HUB") || up.StartsWith("PCI\\") || up.StartsWith("ACPI\\") ||
                            up.StartsWith("ROOT\\") || up.StartsWith("HTREE\\") || up.StartsWith("SWD\\")) break;
                        uint dn;
                        if (CM_Locate_DevNodeW(out dn, cur, 0) != 0) break;
                        cur = PropString(dn, PKEY_Parent);
                    }
                    if (usb == null || !seen.Add(pair[1] + "|" + usb)) continue;
                    uint udn;
                    if (CM_Locate_DevNodeW(out udn, usb, 0) != 0) continue;
                    string name = PropString(udn, PKEY_BusReportedDesc);
                    if (name.Length == 0) name = PropString(udn, PKEY_FriendlyName);
                    if (name.Length == 0) name = PropString(udn, PKEY_DeviceDesc);
                    if (name.Length == 0 || name.StartsWith("USB Input Device", StringComparison.OrdinalIgnoreCase) ||
                        name.StartsWith("USB Composite Device", StringComparison.OrdinalIgnoreCase))
                        name = pair[1] == "keyboard" ? "USB Keyboard" : "USB Mouse";
                    // A mouse receiver usually also exposes a keyboard interface (and vice versa):
                    // trust the product name when it says what it is.
                    string low = name.ToLowerInvariant();
                    if (pair[1] == "keyboard" && low.Contains("mouse") && !low.Contains("keyboard")) continue;
                    if (pair[1] == "mouse" && low.Contains("keyboard") && !low.Contains("mouse")) continue;
                    list.Add(new InputDevice { Id = usb, Name = name, Kind = pair[1] });
                }
            }
            return list;
        }

        public static List<string> GetCameras()
        {
            var names = new List<string>();
            foreach (var cls in new[] { CLASS_CAMERA, CLASS_IMAGE })
            {
                foreach (var id in IdList(cls, FILTER_CLASS | FILTER_PRESENT))
                {
                    uint dn;
                    if (CM_Locate_DevNodeW(out dn, id, 0) != 0) continue;
                    var n = PropString(dn, PKEY_FriendlyName);
                    if (n.Length == 0) n = PropString(dn, PKEY_DeviceDesc);
                    if (n.Length == 0) n = "Camera";
                    var low = n.ToLowerInvariant();
                    if (cls == CLASS_IMAGE && (low.Contains("scan") || low.Contains("print"))) continue;
                    if (!names.Contains(n)) names.Add(n);
                }
            }
            return names;
        }

        // ------------------------------------------------------------ Core Audio
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        class MMDeviceEnumeratorCo { }

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
            [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROPERTYKEY { public Guid fmtid; public uint pid; }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct PROPVARIANT
        {
            [FieldOffset(0)] public ushort vt;
            [FieldOffset(8)] public IntPtr p;
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PROPERTYKEY key);
            [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        }

        [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioEndpointVolume
        {
            [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int GetChannelCount(out uint count);
            [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid ctx);
            [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
            [PreserveSig] int GetMasterVolumeLevel(out float level);
            [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
            [PreserveSig] int SetChannelVolumeLevel(uint ch, float level, ref Guid ctx);
            [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
            [PreserveSig] int GetChannelVolumeLevel(uint ch, out float level);
            [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float level);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        }

        [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioMeterInformation
        {
            [PreserveSig] int GetPeakValue(out float peak);
        }

        [ComImport, Guid("2A07407E-6497-4A18-9787-32F79BD0D98F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDeviceTopology
        {
            [PreserveSig] int GetConnectorCount(out uint count);
            [PreserveSig] int GetConnector(uint index, out IConnector connector);
        }

        [ComImport, Guid("9c2c4058-23f5-41de-877a-df3af236a09e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IConnector
        {
            [PreserveSig] int GetConnectorType(out int type);
            [PreserveSig] int GetDataFlow(out int flow);
            [PreserveSig] int ConnectTo(IntPtr other);
            [PreserveSig] int Disconnect();
            [PreserveSig] int IsConnected([MarshalAs(UnmanagedType.Bool)] out bool connected);
            [PreserveSig] int GetConnectedTo(out IntPtr other);
            [PreserveSig] int GetConnectorIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetDeviceIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KSPROPERTY { public Guid Set; public uint Id; public uint Flags; }

        [ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IKsControl
        {
            [PreserveSig] int KsProperty(ref KSPROPERTY prop, uint propLen, IntPtr data, uint dataLen, out uint returned);
        }

        // Undocumented but stable since Windows 7; used by every "default audio device" switcher.
        [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPolicyConfig
        {
            [PreserveSig] int GetMixFormat(IntPtr a, IntPtr b);
            [PreserveSig] int GetDeviceFormat(IntPtr a, int b, IntPtr c);
            [PreserveSig] int ResetDeviceFormat(IntPtr a);
            [PreserveSig] int SetDeviceFormat(IntPtr a, IntPtr b, IntPtr c);
            [PreserveSig] int GetProcessingPeriod(IntPtr a, int b, IntPtr c, IntPtr d);
            [PreserveSig] int SetProcessingPeriod(IntPtr a, IntPtr b);
            [PreserveSig] int GetShareMode(IntPtr a, IntPtr b);
            [PreserveSig] int SetShareMode(IntPtr a, IntPtr b);
            [PreserveSig] int GetPropertyValue(IntPtr a, IntPtr b, IntPtr c);
            [PreserveSig] int SetPropertyValue(IntPtr a, IntPtr b, IntPtr c);
            [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        }

        [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
        class PolicyConfigClient { }

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PROPVARIANT pv);

        const int CLSCTX_ALL = 23;
        static readonly Guid KSPROPSETID_BtAudio = new Guid("7FA06C40-B8F6-4C7E-8556-E8C33A12E54D");

        static IMMDeviceEnumerator NewEnum() { return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCo()); }

        static string EndpointName(IMMDevice dev)
        {
            string name = "";
            IPropertyStore ps;
            if (dev.OpenPropertyStore(0, out ps) == 0 && ps != null)
            {
                PROPERTYKEY k; k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14;
                PROPVARIANT v;
                if (ps.GetValue(ref k, out v) == 0)
                {
                    if (v.vt == 31 && v.p != IntPtr.Zero) name = Marshal.PtrToStringUni(v.p);
                    PropVariantClear(ref v);
                }
                Marshal.ReleaseComObject(ps);
            }
            return name;
        }

        static Guid EndpointContainer(IMMDevice dev)
        {
            Guid g = Guid.Empty;
            IPropertyStore ps;
            if (dev.OpenPropertyStore(0, out ps) == 0 && ps != null)
            {
                PROPERTYKEY k; k.fmtid = new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c"); k.pid = 2;
                PROPVARIANT v;
                if (ps.GetValue(ref k, out v) == 0)
                {
                    if (v.vt == 72 && v.p != IntPtr.Zero) g = (Guid)Marshal.PtrToStructure(v.p, typeof(Guid));
                    PropVariantClear(ref v);
                }
                Marshal.ReleaseComObject(ps);
            }
            return g;
        }

        public static AudioInfo GetDefaultAudio(bool capture)
        {
            var info = new AudioInfo();
            IMMDeviceEnumerator en = null;
            IMMDevice dev = null;
            try
            {
                en = NewEnum();
                if (en.GetDefaultAudioEndpoint(capture ? 1 : 0, 1, out dev) != 0 || dev == null) return info;
                info.Present = true;
                info.Name = EndpointName(dev);

                object o;
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                {
                    var vol = (IAudioEndpointVolume)o;
                    float f; bool m;
                    if (vol.GetMasterVolumeLevelScalar(out f) == 0) info.Volume = (int)Math.Round(f * 100);
                    if (vol.GetMute(out m) == 0) info.Muted = m;
                    Marshal.ReleaseComObject(o);
                }
                iid = typeof(IAudioMeterInformation).GUID;
                if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                {
                    float p;
                    if (((IAudioMeterInformation)o).GetPeakValue(out p) == 0) info.Peak = p;
                    Marshal.ReleaseComObject(o);
                }
            }
            catch { }
            finally
            {
                if (dev != null) Marshal.ReleaseComObject(dev);
                if (en != null) Marshal.ReleaseComObject(en);
            }
            return info;
        }

        public static List<AudioEndpoint> ListEndpoints(bool capture)
        {
            var list = new List<AudioEndpoint>();
            IMMDeviceEnumerator en = null;
            try
            {
                en = NewEnum();
                int flow = capture ? 1 : 0;
                string defId = null;
                IMMDevice def;
                if (en.GetDefaultAudioEndpoint(flow, 1, out def) == 0 && def != null)
                {
                    def.GetId(out defId);
                    Marshal.ReleaseComObject(def);
                }
                IMMDeviceCollection col;
                if (en.EnumAudioEndpoints(flow, 1, out col) != 0 || col == null) return list;
                uint n;
                col.GetCount(out n);
                for (uint i = 0; i < n; i++)
                {
                    IMMDevice d;
                    if (col.Item(i, out d) != 0 || d == null) continue;
                    var ep = new AudioEndpoint();
                    d.GetId(out ep.Id);
                    ep.Name = EndpointName(d);
                    ep.IsDefault = ep.Id == defId;
                    list.Add(ep);
                    Marshal.ReleaseComObject(d);
                }
                Marshal.ReleaseComObject(col);
            }
            catch { }
            finally { if (en != null) Marshal.ReleaseComObject(en); }
            return list;
        }

        public static bool SetDefaultEndpoint(string id)
        {
            try
            {
                var pc = (IPolicyConfig)(new PolicyConfigClient());
                bool ok = true;
                for (int role = 0; role < 3; role++) ok &= pc.SetDefaultEndpoint(id, role) == 0;
                Marshal.ReleaseComObject(pc);
                return ok;
            }
            catch { return false; }
        }

        static void WithVolume(bool capture, Action<IAudioEndpointVolume> action)
        {
            IMMDeviceEnumerator en = null;
            IMMDevice dev = null;
            try
            {
                en = NewEnum();
                if (en.GetDefaultAudioEndpoint(capture ? 1 : 0, 1, out dev) != 0 || dev == null) return;
                object o;
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                {
                    action((IAudioEndpointVolume)o);
                    Marshal.ReleaseComObject(o);
                }
            }
            catch { }
            finally
            {
                if (dev != null) Marshal.ReleaseComObject(dev);
                if (en != null) Marshal.ReleaseComObject(en);
            }
        }

        public static void SetVolume(bool capture, int percent)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            WithVolume(capture, delegate(IAudioEndpointVolume v)
            {
                Guid g = Guid.Empty;
                v.SetMasterVolumeLevelScalar(percent / 100f, ref g);
                bool m;
                if (percent > 0 && v.GetMute(out m) == 0 && m) v.SetMute(false, ref g);
            });
        }

        public static void SetMute(bool capture, bool mute)
        {
            WithVolume(capture, delegate(IAudioEndpointVolume v) { Guid g = Guid.Empty; v.SetMute(mute, ref g); });
        }

        /// <summary>Connect / disconnect a paired Bluetooth audio device (same trick as the
        /// "Connect" button in Sound settings). Returns false if the device has no audio driver.</summary>
        public static Task<bool> BtAudio(string containerId, bool connect)
        {
            return Task.Run(delegate
            {
                Guid target;
                try { target = new Guid(containerId); } catch { return false; }
                bool any = false;
                IMMDeviceEnumerator en = null;
                try
                {
                    en = NewEnum();
                    IMMDeviceCollection col;
                    if (en.EnumAudioEndpoints(2, 0xF, out col) != 0 || col == null) return false;
                    uint n;
                    col.GetCount(out n);
                    for (uint i = 0; i < n; i++)
                    {
                        IMMDevice d;
                        if (col.Item(i, out d) != 0 || d == null) continue;
                        try
                        {
                            if (EndpointContainer(d) != target) continue;
                            object o;
                            Guid iid = typeof(IDeviceTopology).GUID;
                            if (d.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) != 0 || o == null) continue;
                            var topo = (IDeviceTopology)o;
                            uint cc;
                            topo.GetConnectorCount(out cc);
                            for (uint j = 0; j < cc; j++)
                            {
                                IConnector con;
                                if (topo.GetConnector(j, out con) != 0 || con == null) continue;
                                string other;
                                if (con.GetDeviceIdConnectedTo(out other) == 0 && other != null &&
                                    other.StartsWith("{2}.\\\\?\\bth", StringComparison.OrdinalIgnoreCase))
                                {
                                    IMMDevice od;
                                    if (en.GetDevice(other, out od) == 0 && od != null)
                                    {
                                        object ko;
                                        Guid kid = typeof(IKsControl).GUID;
                                        if (od.Activate(ref kid, CLSCTX_ALL, IntPtr.Zero, out ko) == 0 && ko != null)
                                        {
                                            var prop = new KSPROPERTY { Set = KSPROPSETID_BtAudio, Id = connect ? 0u : 1u, Flags = 1 };
                                            uint ret;
                                            ((IKsControl)ko).KsProperty(ref prop, (uint)Marshal.SizeOf(prop), IntPtr.Zero, 0, out ret);
                                            any = true;
                                            Marshal.ReleaseComObject(ko);
                                        }
                                        Marshal.ReleaseComObject(od);
                                    }
                                }
                                Marshal.ReleaseComObject(con);
                            }
                            Marshal.ReleaseComObject(topo);
                        }
                        finally { Marshal.ReleaseComObject(d); }
                    }
                    Marshal.ReleaseComObject(col);
                }
                catch { }
                finally { if (en != null) Marshal.ReleaseComObject(en); }
                return any;
            });
        }

        // -------------------------------------------- privacy "in use" (mic/webcam)
        public static UsageInfo GetUsage(string capability)
        {
            var u = new UsageInfo();
            string path = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\" + capability;
            try { Scan(Registry.CurrentUser, path, u); } catch { }
            return u;
        }

        static void Scan(RegistryKey root, string path, UsageInfo u)
        {
            using (var k = root.OpenSubKey(path))
            {
                if (k == null) return;
                foreach (var name in k.GetSubKeyNames())
                {
                    if (name == "NonPackaged") { Scan(root, path + "\\NonPackaged", u); continue; }
                    using (var sk = k.OpenSubKey(name))
                    {
                        if (sk == null) continue;
                        object start = sk.GetValue("LastUsedTimeStart");
                        object stop = sk.GetValue("LastUsedTimeStop");
                        if (start is long && stop is long && (long)stop == 0 && (long)start > 0)
                        {
                            u.InUse = true;
                            var app = PrettyApp(name);
                            if (!u.Apps.Contains(app)) u.Apps.Add(app);
                        }
                    }
                }
            }
        }

        public static string PrettyApp(string key)
        {
            string s = key ?? "";
            int bang = s.IndexOf('!');
            if (bang > 0) s = s.Substring(0, bang);
            if (s.Contains("#") || s.Contains("\\")) s = s.Substring(Math.Max(s.LastIndexOf('#'), s.LastIndexOf('\\')) + 1);
            if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s.Substring(0, s.Length - 4);
            int us = s.IndexOf('_');
            if (us > 0) s = s.Substring(0, us);
            int dot = s.LastIndexOf('.');
            if (dot >= 0 && dot < s.Length - 1) s = s.Substring(dot + 1);
            if (s.Length > 0) s = char.ToUpperInvariant(s[0]) + s.Substring(1);
            return s;
        }
    }

    // ============================================================ Wi-Fi / radios
    public static class Net
    {
        static WiFiAdapter adapter;
        static DateTime adapterTried = DateTime.MinValue;
        static readonly object wlock = new object();
        public static volatile NetState State = new NetState();

        static WiFiAdapter Adapter()
        {
            lock (wlock)
            {
                if (adapter == null && (DateTime.Now - adapterTried).TotalSeconds > 20)
                {
                    adapterTried = DateTime.Now;
                    if (Wrt.W(WiFiAdapter.RequestAccessAsync()) == WiFiAccessStatus.Allowed)
                    {
                        var all = Wrt.W(WiFiAdapter.FindAllAdaptersAsync());
                        if (all.Count > 0) adapter = all[0];
                    }
                }
                return adapter;
            }
        }

        static void ResetAdapter() { lock (wlock) { adapter = null; adapterTried = DateTime.MinValue; } }

        public static bool IsVirtual(string desc)
        {
            string d = (desc ?? "").ToLowerInvariant();
            string[] bad = { "virtual", "wintun", "tap-", "tunnel", "hyper-v", "vmware", "virtualbox", "loopback",
                             "pseudo", "bluetooth", "vpn", "wan miniport", "teredo", "npcap" };
            foreach (var b in bad) if (d.Contains(b)) return true;
            return false;
        }

        // Wired (LAN) adapters. Listing adapters is slow (~60 ms), so cache it and refresh
        // when Windows reports a network change, or every 5 s at most.
        static List<EthAdapter> ethCache = new List<EthAdapter>();
        static DateTime ethAt = DateTime.MinValue;
        static bool ethHooked;

        static List<EthAdapter> EthernetAdapters()
        {
            if (!ethHooked)
            {
                ethHooked = true;
                try
                {
                    NetworkChange.NetworkAddressChanged += delegate { ethAt = DateTime.MinValue; };
                    NetworkChange.NetworkAvailabilityChanged += delegate { ethAt = DateTime.MinValue; };
                }
                catch { }
            }
            if ((DateTime.UtcNow - ethAt).TotalSeconds < 5) return ethCache;
            ethAt = DateTime.UtcNow;
            var list = new List<EthAdapter>();
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.NetworkInterfaceType != NetworkInterfaceType.Ethernet &&
                        ni.NetworkInterfaceType != NetworkInterfaceType.GigabitEthernet &&
                        ni.NetworkInterfaceType != NetworkInterfaceType.FastEthernetT) continue;
                    if (IsVirtual(ni.Description)) continue;
                    var a = new EthAdapter { Name = ni.Name, Description = ni.Description, Up = ni.OperationalStatus == OperationalStatus.Up };
                    try { a.SpeedMbps = ni.Speed > 0 ? ni.Speed / 1000000 : 0; } catch { }
                    try
                    {
                        var mac = ni.GetPhysicalAddress().GetAddressBytes();
                        a.Mac = string.Join(":", mac.Select(b => b.ToString("X2")));
                        foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                            if (ua.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork) { a.Ip = ua.Address.ToString(); break; }
                    }
                    catch { }
                    list.Add(a);
                }
            }
            catch { }
            ethCache = list.OrderByDescending(x => x.Up).ToList();
            return ethCache;
        }

        public static void PollState()
        {
            var s = new NetState();
            try
            {
                foreach (var r in Wrt.W(Radio.GetRadiosAsync()))
                {
                    if (r.Kind == RadioKind.Bluetooth) { s.HasBt = true; s.BtOn |= r.State == RadioState.On; }
                    else if (r.Kind == RadioKind.WiFi) { s.HasWifiRadio = true; s.WifiOn |= r.State == RadioState.On; }
                }
            }
            catch { }
            try
            {
                var a = Adapter();
                if (a != null)
                {
                    s.HasWifi = true;
                    var prof = Wrt.W(a.NetworkAdapter.GetConnectedProfileAsync());
                    if (prof != null && prof.IsWlanConnectionProfile)
                    {
                        s.Connected = true;
                        s.Ssid = prof.WlanConnectionProfileDetails.GetConnectedSsid() ?? "";
                        var bars = prof.GetSignalBars();
                        s.Bars = bars.HasValue ? bars.Value : -1;
                    }
                }
            }
            catch { ResetAdapter(); }
            s.EthAdapters = EthernetAdapters();
            s.Ethernet = s.EthAdapters.Any(x => x.Up);
            s.Ready = true;
            State = s;
        }

        public static Task<List<WifiNet>> Scan()
        {
            return Task.Run(delegate
            {
                var best = new Dictionary<string, WifiNet>();
                var a = Adapter();
                if (a == null) return new List<WifiNet>();
                Wrt.W(a.ScanAsync(), 15000);
                foreach (var n in a.NetworkReport.AvailableNetworks)
                {
                    if (string.IsNullOrEmpty(n.Ssid)) continue;
                    WifiNet w;
                    if (best.TryGetValue(n.Ssid, out w) && w.Bars >= n.SignalBars) continue;
                    var auth = n.SecuritySettings.NetworkAuthenticationType;
                    best[n.Ssid] = new WifiNet
                    {
                        Ssid = n.Ssid,
                        Bars = n.SignalBars,
                        Secured = auth != Windows.Networking.Connectivity.NetworkAuthenticationType.None &&
                                  auth != Windows.Networking.Connectivity.NetworkAuthenticationType.Open80211
                    };
                }
                return best.Values.OrderByDescending(x => x.Bars).ThenBy(x => x.Ssid).ToList();
            });
        }

        /// <summary>Returns a WiFiConnectionStatus name: Success, InvalidCredential, NetworkNotAvailable, ...</summary>
        public static Task<string> Connect(string ssid, string password)
        {
            return Task.Run(delegate
            {
                var a = Adapter();
                if (a == null) return "NoAdapter";
                WiFiAvailableNetwork net = null;
                for (int pass = 0; pass < 2 && net == null; pass++)
                {
                    if (pass == 1) Wrt.W(a.ScanAsync(), 15000);
                    foreach (var n in a.NetworkReport.AvailableNetworks)
                        if (n.Ssid == ssid && (net == null || n.SignalBars > net.SignalBars)) net = n;
                }
                if (net == null) return "NetworkNotAvailable";
                WiFiConnectionResult r;
                if (string.IsNullOrEmpty(password))
                    r = Wrt.W(a.ConnectAsync(net, WiFiReconnectionKind.Automatic), 40000);
                else
                {
                    var cred = new PasswordCredential();
                    cred.Password = password;
                    r = Wrt.W(a.ConnectAsync(net, WiFiReconnectionKind.Automatic, cred), 40000);
                }
                PollState();
                return r.ConnectionStatus.ToString();
            });
        }

        public static Task Disconnect()
        {
            return Task.Run(delegate
            {
                var a = Adapter();
                if (a != null) a.Disconnect();
                Thread.Sleep(600);
                PollState();
            });
        }

        public static Task<bool> SetRadio(bool bluetooth, bool on)
        {
            return Task.Run(delegate
            {
                bool ok = false;
                Wrt.W(Radio.RequestAccessAsync());
                foreach (var r in Wrt.W(Radio.GetRadiosAsync()))
                {
                    if ((bluetooth && r.Kind == RadioKind.Bluetooth) || (!bluetooth && r.Kind == RadioKind.WiFi))
                        ok |= Wrt.W(r.SetStateAsync(on ? RadioState.On : RadioState.Off)) == RadioAccessStatus.Allowed;
                }
                Thread.Sleep(400);
                if (!bluetooth) ResetAdapter();
                PollState();
                return ok;
            });
        }
    }

    // ============================================================= net speed
    public static class NetSpeed
    {
        static long lastRx = -1, lastTx = -1;
        static DateTime lastT;
        public static double Down, Up;      // bytes per second

        /// <summary>Forget the last sample (used after the widget was hidden for a while).</summary>
        public static void Reset() { lastRx = -1; Down = 0; Up = 0; }

        // Listing adapters costs ~60 ms, so keep the list and refresh it only every 15 s;
        // reading the byte counters of a known adapter is cheap.
        static List<NetworkInterface> nics = new List<NetworkInterface>();
        static DateTime nicsAt = DateTime.MinValue;

        public static void Sample()
        {
            long rx = 0, tx = 0;
            try
            {
                if ((DateTime.UtcNow - nicsAt).TotalSeconds > 15)
                {
                    nicsAt = DateTime.UtcNow;
                    nics = NetworkInterface.GetAllNetworkInterfaces().Where(ni =>
                        ni.OperationalStatus == OperationalStatus.Up &&
                        ni.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                        ni.NetworkInterfaceType != NetworkInterfaceType.Tunnel &&
                        !Net.IsVirtual(ni.Description)).ToList();
                    lastRx = -1;   // the set changed: start a fresh baseline
                }
                foreach (var ni in nics)
                {
                    try
                    {
                        var st = ni.GetIPStatistics();
                        rx += st.BytesReceived;
                        tx += st.BytesSent;
                    }
                    catch { nicsAt = DateTime.MinValue; }
                }
            }
            catch { return; }
            var now = DateTime.UtcNow;
            if (lastRx >= 0)
            {
                double sec = (now - lastT).TotalSeconds;
                if (sec > 0.2)
                {
                    Down = Math.Max(0, (rx - lastRx) / sec);
                    Up = Math.Max(0, (tx - lastTx) / sec);
                }
            }
            lastRx = rx; lastTx = tx; lastT = now;
        }
    }

    // ============================================================ brightness
    public static class Brightness
    {
        public static volatile int Current = -1;
        public static volatile int Mode;     // 0 = unsupported, 1 = laptop (WMI), 2 = monitor (DDC/CI)
        static int pending = -1;
        static DateTime lastSet = DateTime.MinValue;
        static readonly object l = new object();
        static readonly AutoResetEvent ev = new AutoResetEvent(false);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
        delegate bool MonEnum(IntPtr hMon, IntPtr hdc, IntPtr rc, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr data);
        [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
        [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] arr);
        [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] arr);
        [DllImport("dxva2.dll")] static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
        [DllImport("dxva2.dll")] static extern bool SetMonitorBrightness(IntPtr h, uint value);

        public static bool Supported { get { return Mode > 0; } }

        public static void Start()
        {
            var t = new Thread(Loop);
            t.IsBackground = true;
            t.Start();
        }

        public static void Set(int percent)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            lock (l) { pending = percent; lastSet = DateTime.Now; }
            Current = percent;
            ev.Set();
        }

        static void Loop()
        {
            Read();
            while (true)
            {
                ev.WaitOne(15000);
                if (Watcher.Paused && pending < 0) continue;
                int p;
                bool recent;
                lock (l) { p = pending; pending = -1; recent = (DateTime.Now - lastSet).TotalSeconds < 5; }
                try
                {
                    if (p >= 0) Apply(p);
                    else if (!recent) Read();
                }
                catch { }
            }
        }

        static void ForEachMonitor(Action<IntPtr> action)
        {
            var handles = new List<IntPtr>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hm, IntPtr a, IntPtr b, IntPtr c)
            {
                handles.Add(hm);
                return true;
            }, IntPtr.Zero);
            foreach (var hm in handles)
            {
                uint n;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) continue;
                var arr = new PHYSICAL_MONITOR[n];
                if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
                try { foreach (var pm in arr) action(pm.h); }
                finally { DestroyPhysicalMonitors(n, arr); }
            }
        }

        static void Read()
        {
            try
            {
                using (var s = new ManagementObjectSearcher("root\\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness"))
                    foreach (ManagementObject o in s.Get())
                    {
                        Current = Convert.ToInt32(o["CurrentBrightness"]);
                        Mode = 1;
                        return;
                    }
            }
            catch { }
            int found = -1;
            ForEachMonitor(delegate(IntPtr h)
            {
                uint mn, cur, mx;
                if (found < 0 && GetMonitorBrightness(h, out mn, out cur, out mx) && mx > mn)
                    found = (int)Math.Round((cur - mn) * 100.0 / (mx - mn));
            });
            if (found >= 0) { Current = found; Mode = 2; }
        }

        static void Apply(int percent)
        {
            if (Mode == 1)
            {
                using (var s = new ManagementObjectSearcher("root\\WMI", "SELECT * FROM WmiMonitorBrightnessMethods"))
                    foreach (ManagementObject o in s.Get())
                        o.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, (byte)percent });
                return;
            }
            ForEachMonitor(delegate(IntPtr h)
            {
                uint mn, cur, mx;
                if (GetMonitorBrightness(h, out mn, out cur, out mx) && mx > mn)
                    SetMonitorBrightness(h, (uint)(mn + Math.Round((mx - mn) * percent / 100.0)));
            });
        }
    }

    // ================================================================= media
    public static class Media
    {
        public static volatile MediaInfo Info = new MediaInfo();
        static GlobalSystemMediaTransportControlsSessionManager mgr;
        static readonly object ml = new object();
        static string lastKey = "";
        static byte[] lastThumb;
        static int version;

        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

        static GlobalSystemMediaTransportControlsSession Session()
        {
            if (mgr == null) mgr = Wrt.W(GlobalSystemMediaTransportControlsSessionManager.RequestAsync());
            return mgr.GetCurrentSession();
        }

        public static void Poll()
        {
            lock (ml)
            {
                var s = Session();
                if (s == null)
                {
                    if (Info.Has) { lastKey = ""; lastThumb = null; version++; }
                    Info = new MediaInfo { Version = version };
                    return;
                }
                var p = Wrt.W(s.TryGetMediaPropertiesAsync());
                var mi = new MediaInfo
                {
                    Has = true,
                    App = Devices.PrettyApp(s.SourceAppUserModelId),
                    Title = p.Title ?? "",
                    Artist = p.Artist ?? "",
                    Playing = s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
                };
                string key = mi.App + "|" + mi.Title + "|" + mi.Artist;
                if (key != lastKey)
                {
                    lastKey = key;
                    lastThumb = null;
                    version++;
                    try
                    {
                        if (p.Thumbnail != null)
                        {
                            var stream = Wrt.W(p.Thumbnail.OpenReadAsync());
                            ulong size = stream.Size;
                            if (size > 0 && size < 10000000)
                            {
                                var reader = new DataReader(stream);
                                Wrt.W(reader.LoadAsync((uint)size));
                                var bytes = new byte[size];
                                reader.ReadBytes(bytes);
                                lastThumb = bytes;
                            }
                            stream.Dispose();
                        }
                    }
                    catch { }
                }
                mi.Thumb = lastThumb;
                mi.Version = version;
                Info = mi;
            }
        }

        /// <summary>0 = play/pause, 1 = next, 2 = previous.</summary>
        public static Task Command(int cmd)
        {
            return Task.Run(delegate
            {
                bool ok = false;
                try
                {
                    GlobalSystemMediaTransportControlsSession s;
                    lock (ml) { s = Session(); }
                    if (s != null)
                    {
                        if (cmd == 0) ok = Wrt.W(s.TryTogglePlayPauseAsync());
                        else if (cmd == 1) ok = Wrt.W(s.TrySkipNextAsync());
                        else ok = Wrt.W(s.TrySkipPreviousAsync());
                    }
                }
                catch { }
                if (!ok)
                {
                    byte vk = cmd == 0 ? (byte)0xB3 : cmd == 1 ? (byte)0xB0 : (byte)0xB1;
                    keybd_event(vk, 0, 0, UIntPtr.Zero);
                    keybd_event(vk, 0, 2, UIntPtr.Zero);
                }
                Thread.Sleep(300);
                try { Poll(); } catch { }
            });
        }
    }

    // ========================================================= global hotkey
    public static class HotKey
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        const int ID = 0x5D17;
        const uint MOD_NOREPEAT = 0x4000;
        const int WM_HOTKEY = 0x0312;
        static IntPtr hwnd = IntPtr.Zero;
        static bool registered;

        public static event EventHandler Pressed;

        /// <summary>Listen for WM_HOTKEY on the widget's own window.</summary>
        public static void Attach(IntPtr windowHandle)
        {
            hwnd = windowHandle;
            var src = System.Windows.Interop.HwndSource.FromHwnd(windowHandle);
            if (src != null) src.AddHook(Hook);
        }

        /// <summary>mods: 1 = Alt, 2 = Ctrl, 4 = Shift, 8 = Win. Returns false if another app owns the combo.</summary>
        public static bool Register(uint mods, uint vk)
        {
            Unregister();
            if (hwnd == IntPtr.Zero) return false;
            registered = RegisterHotKey(hwnd, ID, mods | MOD_NOREPEAT, vk);
            return registered;
        }

        public static void Unregister()
        {
            if (registered && hwnd != IntPtr.Zero) UnregisterHotKey(hwnd, ID);
            registered = false;
        }

        static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled)
        {
            if (msg == WM_HOTKEY && w.ToInt32() == ID)
            {
                handled = true;
                var p = Pressed;
                if (p != null) p(null, EventArgs.Empty);
            }
            return IntPtr.Zero;
        }
    }

    // ====================================================== CPU / RAM / battery
    public static class SysInfo
    {
        [StructLayout(LayoutKind.Sequential)]
        struct FILETIME { public uint Low, High; public ulong Value { get { return ((ulong)High << 32) | Low; } } }
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

        [StructLayout(LayoutKind.Sequential)]
        class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);

        [StructLayout(LayoutKind.Sequential)]
        struct SYSTEM_POWER_STATUS { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int BatteryLifeTime, BatteryFullLifeTime; }
        [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);

        static ulong lastIdle, lastTotal;
        static int lastCpu = -1;
        static string cpuName;

        /// <summary>Call about once a second; CPU % is measured between two calls.</summary>
        public static SysStats Sample()
        {
            var st = new SysStats();
            FILETIME idle, kernel, user;
            if (GetSystemTimes(out idle, out kernel, out user))
            {
                ulong total = kernel.Value + user.Value;   // kernel time includes idle time
                if (lastTotal > 0 && total > lastTotal)
                {
                    double busy = 1.0 - (double)(idle.Value - lastIdle) / (total - lastTotal);
                    lastCpu = (int)Math.Round(Math.Max(0, Math.Min(1, busy)) * 100);
                }
                lastIdle = idle.Value; lastTotal = total;
            }
            st.Cpu = lastCpu;

            var m = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(m))
            {
                st.RamPercent = (int)m.dwMemoryLoad;
                st.RamTotalGb = m.ullTotalPhys / 1073741824.0;
                st.RamUsedGb = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
            }

            SYSTEM_POWER_STATUS p;
            if (GetSystemPowerStatus(out p))
            {
                st.OnAc = p.ACLineStatus == 1;
                st.HasBattery = (p.BatteryFlag & 128) == 0 && p.BatteryFlag != 255;
                if (st.HasBattery && p.BatteryLifePercent <= 100) st.Battery = p.BatteryLifePercent;
                st.Charging = (p.BatteryFlag & 8) != 0;
            }
            return st;
        }

        public static string CpuName()
        {
            if (cpuName != null) return cpuName;
            cpuName = "";
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0"))
                    if (k != null) cpuName = ((k.GetValue("ProcessorNameString") as string) ?? "").Trim();
            }
            catch { }
            return cpuName;
        }
    }

    // ============================================= Liquid Glass (blur behind)
    public static class Glass
    {
        [StructLayout(LayoutKind.Sequential)]
        struct ACCENT_POLICY { public int AccentState, AccentFlags; public uint GradientColor; public int AnimationId; }
        [StructLayout(LayoutKind.Sequential)]
        struct WINCOMPATTRDATA { public int Attribute; public IntPtr Data; public int SizeOfData; }
        [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WINCOMPATTRDATA d);
        [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
        [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);

        /// <summary>Blur whatever is behind the window (Windows 10 "blur behind" accent).</summary>
        public static bool Enable(IntPtr hwnd, bool on)
        {
            var accent = new ACCENT_POLICY { AccentState = on ? 3 : 0 };
            int size = Marshal.SizeOf(accent);
            IntPtr ptr = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(accent, ptr, false);
                var data = new WINCOMPATTRDATA { Attribute = 19, Data = ptr, SizeOfData = size };
                return SetWindowCompositionAttribute(hwnd, ref data) != 0;
            }
            finally { Marshal.FreeHGlobal(ptr); }
        }

        /// <summary>Clip the window (and its blur) to a rounded rectangle, sizes in physical pixels.</summary>
        public static void Clip(IntPtr hwnd, int width, int height, int radius)
        {
            IntPtr rgn = CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2, radius * 2);
            SetWindowRgn(hwnd, rgn, true);   // the window owns the region from now on
        }
    }

    // ===================================================== pin to the desktop
    /// <summary>"Desktop gadget" mode: the window is owned by the desktop (Progman), so it sits just
    /// above the wallpaper, below normal windows, and is not minimised by Win + D / Show desktop.</summary>
    public static class DesktopPin
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int idx, IntPtr v);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong32(IntPtr h, int idx, int v);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

        const int GWL_HWNDPARENT = -8;
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
        static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
        static IntPtr originalOwner = IntPtr.Zero;
        static bool pinned;

        static IntPtr SetOwner(IntPtr h, IntPtr owner)
        {
            if (IntPtr.Size == 8) return SetWindowLongPtr64(h, GWL_HWNDPARENT, owner);
            return new IntPtr(SetWindowLong32(h, GWL_HWNDPARENT, owner.ToInt32()));
        }

        public static void Pin(IntPtr hwnd, bool on)
        {
            if (on == pinned) return;
            if (on)
            {
                var desktop = FindWindow("Progman", null);
                if (desktop == IntPtr.Zero) return;
                originalOwner = SetOwner(hwnd, desktop);
            }
            else SetOwner(hwnd, originalOwner);
            pinned = on;
        }

        /// <summary>Move the window to the bottom of the z-order (just above the wallpaper).</summary>
        public static void SendToBottom(IntPtr hwnd)
        {
            SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
        }

        public static IntPtr Foreground() { return GetForegroundWindow(); }

        public static void Focus(IntPtr h)
        {
            if (h != IntPtr.Zero && IsWindow(h) && IsWindowVisible(h)) SetForegroundWindow(h);
        }
    }

    // ============================================================ background
    public static class Watcher
    {
        static bool started;
        /// <summary>True while the widget is hidden: stop polling so it costs nothing in the background.</summary>
        public static volatile bool Paused;

        public static void Start()
        {
            if (started) return;
            started = true;
            var t = new Thread(Loop);
            t.IsBackground = true;
            t.SetApartmentState(ApartmentState.MTA);
            t.Start();
            Brightness.Start();
        }

        static void Loop()
        {
            try { Wrt.W(Radio.RequestAccessAsync()); } catch { }
            int i = 0;
            while (true)
            {
                if (Paused) { Thread.Sleep(400); i = 0; continue; }
                if (i % 2 == 0) { try { Net.PollState(); } catch { } }
                try { Media.Poll(); } catch { }
                i++;
                Thread.Sleep(1000);
            }
        }
    }
}
