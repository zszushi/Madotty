using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class NativeConsoleProbe : IDisposable
{
    const uint CreateNewConsole = 0x10;
    const uint StartfUseShowWindow = 1;
    const ushort SwShowNormal = 1;
    const uint WaitTimeout = 0x102;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public uint size;
        public string reserved, desktop, title;
        public uint x, y, width, height, columns, rows, fill, flags;
        public ushort showWindow, reservedSize;
        public IntPtr reservedBytes, input, output, error;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation
    {
        public IntPtr process, thread;
        public uint processId, threadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
        string workingDirectory, ref StartupInfo startup, out ProcessInformation process);

    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint exitCode);

    IntPtr process;
    public uint Id { get; private set; }
    public bool Exited { get { return WaitForSingleObject(process, 0) != WaitTimeout; } }

    public static NativeConsoleProbe Start(string workDirectory, string title)
    {
        var startup = new StartupInfo {
            size = (uint)Marshal.SizeOf(typeof(StartupInfo)),
            title = title,
            flags = StartfUseShowWindow,
            showWindow = SwShowNormal
        };
        var command = new StringBuilder("cmd.exe /d /q /c native-console.cmd");
        string cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        ProcessInformation info;
        if (!CreateProcess(cmd, command, IntPtr.Zero, IntPtr.Zero, false,
            CreateNewConsole, IntPtr.Zero, workDirectory, ref startup, out info))
            throw new Win32Exception();

        CloseHandle(info.thread);
        return new NativeConsoleProbe { process = info.process, Id = info.processId };
    }

    public void Dispose()
    {
        if (process == IntPtr.Zero) return;
        if (!Exited)
        {
            TerminateProcess(process, 1);
            WaitForSingleObject(process, 5000);
        }
        CloseHandle(process);
        process = IntPtr.Zero;
    }
}
