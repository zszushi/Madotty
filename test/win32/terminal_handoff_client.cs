using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class TerminalHandoffClient : IDisposable
{
    public static readonly Guid ServerClass = new Guid("A3A39CB0-46F7-4D5D-954E-F311DAE8EB6A");
    static readonly Guid ProxyClass = new Guid("9C11CDBC-C14F-4C6D-AC73-3110BAD9DCA6");
    static readonly Guid HandoffInterface = new Guid("6F23DA90-15C5-4203-9DB0-64E73F1B1B00");
    static readonly Guid MarkerInterface = new Guid("746E6BC0-AB05-4E38-AB14-71E86763141F");
    static readonly Guid ProxyFactoryInterface = new Guid("D5F569D0-593B-101A-B569-08002B2DBF7A");
    const int ClassNotRegistered = unchecked((int)0x80040154);

    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo
    {
        public IntPtr Title, IconPath;
        public int IconIndex;
        public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public ushort ShowWindow;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetClassObject(ref Guid clsid, ref Guid iid, out IntPtr factory);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int QueryInterface(IntPtr self, ref Guid iid, out IntPtr result);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int EstablishPtyHandoff(IntPtr self, out IntPtr input, out IntPtr output,
        IntPtr signal, IntPtr reference, IntPtr server, IntPtr client, ref StartupInfo startup);

    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved, uint flags);
    [DllImport("ole32.dll")] static extern void CoUninitialize();
    [DllImport("ole32.dll")] static extern int CoRegisterClassObject(ref Guid clsid, IntPtr factory, uint context, uint flags, out uint cookie);
    [DllImport("ole32.dll")] static extern int CoRevokeClassObject(uint cookie);
    [DllImport("ole32.dll")] static extern int CoRegisterPSClsid(ref Guid iid, ref Guid clsid);
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, out IntPtr instance);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr security, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool PeekNamedPipe(IntPtr pipe, IntPtr buffer, uint size, IntPtr read, out uint available, IntPtr left);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr pipe, [Out] byte[] buffer, uint size, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr pipe, byte[] buffer, uint size, out uint written, IntPtr overlapped);

    bool uninitializeCom;
    uint cookie;
    readonly string referencePath;
    FileStream referenceFile;
    IntPtr signalRead, signalWrite, process, input, output, instance;

    public TerminalHandoffClient(string proxyPath, string referencePath)
    {
        this.referencePath = referencePath;
        try
        {
            int hr = CoInitializeEx(IntPtr.Zero, 2);
            if (hr != unchecked((int)0x80010106))
            {
                Check(hr, "CoInitializeEx");
                uninitializeCom = true;
            }

            // Keep the proxy loaded for this PowerShell process: COM can cache
            // the process-local IID registrations after the class is revoked.
            IntPtr module = LoadLibraryEx(proxyPath, IntPtr.Zero, 0x900);
            if (module == IntPtr.Zero) throw new Win32Exception();
            IntPtr export = GetProcAddress(module, "DllGetClassObject");
            if (export == IntPtr.Zero) throw new Win32Exception();
            var getClassObject = (GetClassObject)Marshal.GetDelegateForFunctionPointer(export, typeof(GetClassObject));
            Guid clsid = ProxyClass, factoryIid = ProxyFactoryInterface;
            IntPtr factory;
            Check(getClassObject(ref clsid, ref factoryIid, out factory), "Proxy DllGetClassObject");
            try { Check(CoRegisterClassObject(ref clsid, factory, 1, 1, out cookie), "CoRegisterClassObject"); }
            finally { Marshal.Release(factory); }

            Guid handoffIid = HandoffInterface, markerIid = MarkerInterface;
            Check(CoRegisterPSClsid(ref handoffIid, ref clsid), "CoRegisterPSClsid (handoff)");
            Check(CoRegisterPSClsid(ref markerIid, ref clsid), "CoRegisterPSClsid (marker)");
            using (var self = Process.GetCurrentProcess())
                process = OpenProcess(0x101000, false, self.Id); // SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
            if (process == IntPtr.Zero || !CreatePipe(out signalRead, out signalWrite, IntPtr.Zero, 0))
                throw new Win32Exception();
            referenceFile = new FileStream(referencePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public bool TryConnect()
    {
        Guid clsid = ServerClass, iid = HandoffInterface;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out instance);
        if (hr == ClassNotRegistered) return false;
        Check(hr, "CoCreateInstance (ITerminalHandoff3)");
        Guid markerIid = MarkerInterface;
        IntPtr marker;
        IntPtr slot = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance));
        var query = (QueryInterface)Marshal.GetDelegateForFunctionPointer(slot, typeof(QueryInterface));
        Check(query(instance, ref markerIid, out marker), "QueryInterface (IDefaultTerminalMarker)");
        Marshal.Release(marker);
        return true;
    }

    public void Establish(string title, uint columns, uint rows)
    {
        IntPtr slot = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), 3 * IntPtr.Size);
        var establish = (EstablishPtyHandoff)Marshal.GetDelegateForFunctionPointer(slot, typeof(EstablishPtyHandoff));
        var startup = new StartupInfo {
            Title = Marshal.StringToBSTR(title), XCountChars = columns, YCountChars = rows,
            Flags = 8, ShowWindow = 5 // STARTF_USECOUNTCHARS; SW_SHOW
        };
        try
        {
            // These are fixture-owned kernel handles. A real console host uses
            // different processes for the peer and client roles.
            Check(establish(instance, out input, out output, signalWrite, referenceFile.SafeFileHandle.DangerousGetHandle(),
                process, process, ref startup),
                "ITerminalHandoff3::EstablishPtyHandoff");
            if (input == IntPtr.Zero || output == IntPtr.Zero)
                throw new InvalidOperationException("Handoff did not return both console pipes.");
        }
        finally { Marshal.FreeBSTR(startup.Title); }

        Marshal.Release(instance);
        instance = IntPtr.Zero;
    }

    public void PaintAndQuery()
    {
        const string esc = "\u001b";
        string vt = esc + "[?25l" + esc + "[1;1H" + esc + "[38;2;251;33;247m" +
            new string('\u2588', 12) + esc + "[0m" + esc + "[2;1H" + esc + "[48;2;31;215;87m" +
            new string(' ', 12) + esc + "[0m" + esc + "[3;7H" + esc + "[6n";
        byte[] bytes = Encoding.UTF8.GetBytes(vt);
        uint written;
        if (!WriteFile(output, bytes, (uint)bytes.Length, out written, IntPtr.Zero)) throw new Win32Exception();
        if (written != bytes.Length) throw new InvalidOperationException("Short console output write.");
    }

    public string ReadReply()
    {
        uint available = Available(input);
        return available == 0 ? "" : Encoding.ASCII.GetString(Read(input, Math.Min(available, 4096)));
    }

    public string ReadGrid()
    {
        if (Available(signalRead) < 6) return null;
        byte[] message = Read(signalRead, 6);
        if (message[0] != 8 || message[1] != 0)
            throw new InvalidOperationException("Unexpected ConPTY signal " + BitConverter.ToString(message));
        return String.Format("{0}x{1}", message[2] | message[3] << 8, message[4] | message[5] << 8);
    }

    public void EndOutput() { Close(ref output); }

    public bool ConsoleReferenceReleased()
    {
        if (referenceFile != null) referenceFile.Dispose();
        referenceFile = null;
        try
        {
            // An exclusive open is possible only after the remote duplicate
            // has closed (the original file object's sharing mode was none).
            using (File.Open(referencePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) return true;
        }
        catch (IOException exception)
        {
            if (exception.HResult != unchecked((int)0x80070020)) throw; // ERROR_SHARING_VIOLATION
            return false;
        }
    }

    static uint Available(IntPtr pipe)
    {
        uint available;
        if (!PeekNamedPipe(pipe, IntPtr.Zero, 0, IntPtr.Zero, out available, IntPtr.Zero))
            throw new Win32Exception();
        return available;
    }

    static byte[] Read(IntPtr pipe, uint size)
    {
        byte[] bytes = new byte[size];
        uint read;
        if (!ReadFile(pipe, bytes, size, out read, IntPtr.Zero)) throw new Win32Exception();
        if (read != size) throw new InvalidOperationException("Short console pipe read.");
        return bytes;
    }

    static void Check(int hr, string operation)
    {
        if (hr < 0) throw new COMException(String.Format("{0} returned HRESULT 0x{1:x8}", operation, hr), hr);
    }

    static void Close(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero) CloseHandle(handle);
        handle = IntPtr.Zero;
    }

    public void Dispose()
    {
        if (instance != IntPtr.Zero) Marshal.Release(instance);
        instance = IntPtr.Zero;
        Close(ref output);
        Close(ref input);
        Close(ref process);
        if (referenceFile != null) referenceFile.Dispose();
        referenceFile = null;
        Close(ref signalWrite);
        Close(ref signalRead);
        if (cookie != 0) CoRevokeClassObject(cookie);
        cookie = 0;
        if (uninitializeCom) CoUninitialize();
        uninitializeCom = false;
    }
}

public static class TerminalHandoffWindow
{
    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfo
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, Bits;
        public uint Compression, SizeImage;
        public int DpiX, DpiY;
        public uint ColorsUsed, ImportantColors;
    }

    public class Frame
    {
        public int Width, Height, Ink, Green;
        public int GreenLeft = int.MaxValue, GreenTop = int.MaxValue, GreenRight = -1, GreenBottom = -1;
        public int CellWidth { get { return Green == 0 ? 0 : (GreenRight - GreenLeft + 1) / 12; } }
        public int CellHeight { get { return Green == 0 ? 0 : GreenBottom - GreenTop + 1; } }
        public bool HasFixtureColors
        {
            get
            {
                return CellWidth > 0 && CellHeight > 0 &&
                    GreenRight - GreenLeft + 1 == 12 * CellWidth &&
                    Green == 12 * CellWidth * CellHeight && Ink >= 12 * CellWidth;
            }
        }
        public override string ToString()
        {
            return String.Format("{0}x{1}px client; {2} foreground px; {3} background px; {4}x{5}px cells",
                Width, Height, Ink, Green, CellWidth, CellHeight);
        }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string name);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")]
    static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static Rect OwnedRect(IntPtr window, int pid, string expectedClass)
    {
        uint owner;
        Rect rect;
        var name = new StringBuilder(64);
        if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)pid ||
            GetClassName(window, name, name.Capacity) == 0 || name.ToString() != expectedClass ||
            !GetWindowRect(window, out rect))
            throw new InvalidOperationException("Expected an HWND owned by the test terminal.");
        return rect;
    }

    public static void Shrink(IntPtr window, int pid, int width, int height)
    {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            Rect rect = OwnedRect(window, pid, "GhosttyWindow");
            // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
            if (!SetWindowPos(window, IntPtr.Zero, 0, 0, rect.Right - rect.Left - width,
                rect.Bottom - rect.Top - height, 0x16))
                throw new Win32Exception();
        }
        finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }

    public static Frame Capture(IntPtr window, int pid)
    {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            Rect outer = OwnedRect(window, pid, "GhosttyWindow");
            IntPtr surface = FindWindowEx(window, IntPtr.Zero, "GhosttyTerminal", null);
            if (surface == IntPtr.Zero) return null;
            Rect content = OwnedRect(surface, pid, "GhosttyTerminal");
            IntPtr messageResult;
            if (SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 3, 300, out messageResult) == IntPtr.Zero)
                return null;
            int width = outer.Right - outer.Left, height = outer.Bottom - outer.Top;
            int left = Math.Max(0, content.Left - outer.Left), right = Math.Min(width, content.Right - outer.Left);
            int top = Math.Max(0, content.Top - outer.Top), bottom = Math.Min(height, content.Bottom - outer.Top);
            if (left >= right || top >= bottom) return null;

            IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed.");
            try
            {
                var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, Bits = 32 };
                IntPtr data;
                IntPtr bitmap = CreateDIBSection(dc, ref info, 0, out data, IntPtr.Zero, 0);
                if (bitmap == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed.");
                IntPtr previous = SelectObject(dc, bitmap);
                try
                {
                    DwmFlush();
                    if (!PrintWindow(window, dc, 2)) return null;
                    GdiFlush();
                    int[] raw = new int[checked(width * height)];
                    Marshal.Copy(data, raw, 0, raw.Length);
                    var frame = new Frame { Width = right - left, Height = bottom - top };
                    for (int y = top; y < bottom; y++)
                    for (int x = left; x < right; x++)
                    {
                        switch (raw[y * width + x] & 0xffffff)
                        {
                            case 0xfb21f7: frame.Ink++; break;
                            case 0x1fd757:
                                frame.Green++;
                                frame.GreenLeft = Math.Min(frame.GreenLeft, x);
                                frame.GreenTop = Math.Min(frame.GreenTop, y);
                                frame.GreenRight = Math.Max(frame.GreenRight, x);
                                frame.GreenBottom = Math.Max(frame.GreenBottom, y);
                                break;
                        }
                    }
                    return frame;
                }
                finally { SelectObject(dc, previous); DeleteObject(bitmap); }
            }
            finally { DeleteDC(dc); }
        }
        finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
