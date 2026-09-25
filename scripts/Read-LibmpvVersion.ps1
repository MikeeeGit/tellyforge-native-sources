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

if ($null -eq ('TellyForge.NativeMpvProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace TellyForge {
    public static class NativeMpvProbe {
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);
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
        public static string Read(string path) {
            // Explicit full path, with dependent DLLs resolved relative to that library.
            var module = LoadLibraryExW(path, IntPtr.Zero, 8);
            if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr handle = IntPtr.Zero;
            Release destroy = null;
            try {
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
                try { return Marshal.PtrToStringAnsi(value); }
                finally { Symbol<Release>(module, "mpv_free")(value); }
            }
            finally {
                if (handle != IntPtr.Zero && destroy != null) destroy(handle);
                FreeLibrary(module);
            }
        }
    }
}
'@
}
[TellyForge.NativeMpvProbe]::Read($library)
