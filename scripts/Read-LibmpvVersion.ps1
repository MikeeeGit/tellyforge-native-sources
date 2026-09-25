#Requires -Version 5.1
# SPDX-License-Identifier: MIT

[CmdletBinding()]
param([Parameter(Mandatory)][string]$LibraryPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$library = (Resolve-Path -LiteralPath $LibraryPath).Path
if ([IO.Path]::GetFileName($library) -cne 'libmpv-2.dll') {
    throw 'The probe requires an explicit libmpv-2.dll path.'
}
foreach ($dependency in @('z.dll', 'libGLESv2.dll', 'libEGL.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($library)) $dependency) -PathType Leaf)) {
        throw "The hash-verified probe bundle is missing $dependency."
    }
}

if ($null -eq ('TellyForge.NativeMpvProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace TellyForge {
    public sealed class NativeMpvProbeResult {
        public string Version { get; set; }
        public string[] LoadedModules { get; set; }
    }
    public static class NativeMpvProbe {
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetModuleFileNameW(IntPtr module, StringBuilder name, int size);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr Create();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Initialize(IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Option(IntPtr handle, string name, string value);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr Property(IntPtr handle, string name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Release(IntPtr value);
        private static T Symbol<T>(IntPtr module, string name) where T : class {
            var address = GetProcAddress(module, name);
            if (address == IntPtr.Zero) throw new EntryPointNotFoundException(name);
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        private static IntPtr LoadExact(string path, List<string> loadedPaths) {
            // Search only the explicit DLL's directory and System32; never PATH,
            // the working directory or an installed application's directory.
            var module = LoadLibraryExW(path, IntPtr.Zero, 0x900);
            if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var buffer = new StringBuilder(32768);
                var length = GetModuleFileNameW(module, buffer, buffer.Capacity);
                if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
                var actual = Path.GetFullPath(buffer.ToString());
                if (!String.Equals(actual, Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) {
                    throw new InvalidOperationException("A native dependency was loaded from an unexpected path.");
                }
                loadedPaths.Add(actual);
                return module;
            }
            catch { FreeLibrary(module); throw; }
        }
        public static NativeMpvProbeResult Read(string path) {
            var modules = new List<IntPtr>();
            var loadedPaths = new List<string>();
            IntPtr handle = IntPtr.Zero;
            Release destroy = null;
            try {
                var directory = Path.GetDirectoryName(path);
                // Load dependency-first and verify each actual module path.
                foreach (var name in new[] { "z.dll", "libGLESv2.dll", "libEGL.dll", "libmpv-2.dll" }) {
                    modules.Add(LoadExact(Path.Combine(directory, name), loadedPaths));
                }
                var module = modules[modules.Count - 1];
                destroy = Symbol<Release>(module, "mpv_terminate_destroy");
                handle = Symbol<Create>(module, "mpv_create")();
                if (handle == IntPtr.Zero) throw new InvalidOperationException("mpv_create failed");
                var option = Symbol<Option>(module, "mpv_set_option_string");
                foreach (var setting in new[] { new[] { "config", "no" }, new[] { "terminal", "no" }, new[] { "vo", "null" }, new[] { "ao", "null" } }) {
                    if (option(handle, setting[0], setting[1]) < 0) throw new InvalidOperationException("mpv option failed: " + setting[0]);
                }
                if (Symbol<Initialize>(module, "mpv_initialize")(handle) < 0) throw new InvalidOperationException("mpv_initialize failed");
                var value = Symbol<Property>(module, "mpv_get_property_string")(handle, "mpv-version");
                if (value == IntPtr.Zero) throw new InvalidOperationException("mpv-version is unavailable");
                try { return new NativeMpvProbeResult { Version = Marshal.PtrToStringAnsi(value), LoadedModules = loadedPaths.ToArray() }; }
                finally { Symbol<Release>(module, "mpv_free")(value); }
            }
            finally {
                if (handle != IntPtr.Zero && destroy != null) destroy(handle);
                for (var index = modules.Count - 1; index >= 0; index--) FreeLibrary(modules[index]);
            }
        }
    }
}
'@
}
$result = [TellyForge.NativeMpvProbe]::Read($library)
[pscustomobject][ordered]@{
    version = $result.Version
    loadedModulePaths = @($result.LoadedModules)
}
