using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;

// Small SCM host. The job object kills the complete process tree if this host dies.
public sealed class RunnerService : ServiceBase
{
    private Process child;
    private IntPtr job;
    private volatile bool stopping;
    private readonly string root = Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')).FullName;

    public RunnerService() {
        string arch = new DirectoryInfo(root).Name;
        if (arch != "x64" && arch != "arm64") throw new InvalidOperationException("Invalid architecture directory");
        ServiceName = "LocalGitHubRunner-" + arch;
        CanShutdown = true; AutoLog = false;
    }
    public static void Main() { ServiceBase.Run(new RunnerService()); }

    protected override void OnStart(string[] args)
    {
        stopping = false;
        File.Delete(Path.Combine(root, ".state", "stop"));
        job = CreateJobObject(IntPtr.Zero, null);
        var limits = new ExtendedLimits();
        limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits)))
            throw new InvalidOperationException("Cannot create runner process job");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        child = Process.Start(new ProcessStartInfo {
            FileName = powershell,
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(root, "bin", "service.ps1") + "\"",
            WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true
        });
        if (!AssignProcessToJobObject(job, child.Handle))
        {
            child.Kill();
            CloseHandle(job);
            throw new InvalidOperationException("Cannot contain runner process tree");
        }
        var monitor = new Thread(() => { child.WaitForExit(); if (!stopping) Environment.Exit(1); });
        monitor.IsBackground = true;
        monitor.Start();
    }

    protected override void OnStop()
    {
        stopping = true;
        RequestAdditionalTime(60000);
        File.WriteAllText(Path.Combine(root, ".state", "stop"), "stop");
        if (child != null) child.WaitForExit(40000);
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
    }
    protected override void OnShutdown() { OnStop(); }

    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits info, uint length);
    [DllImport("kernel32.dll")] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
