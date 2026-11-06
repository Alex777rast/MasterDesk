[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateRange(106,65535)][int]$BetaNumber,
    [Parameter(Mandatory)][ValidatePattern('^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')][string]$BuildDate
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$file = Get-Item -LiteralPath $Path
$allowedRoots = @('artifacts','dist','flutter\build\windows\x64\runner\Release','target\release')
if (-not @($allowedRoots | Where-Object {
    $file.FullName.StartsWith((Join-Path $repo $_) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
}).Count) { throw 'Metadata changes are restricted to this repository build outputs.' }
if ($file.Name -notin @('MasterDesk.exe','libmasterdesk.dll','dylib_virtual_display.dll') -and
    $file.Name -cne "MasterDesk-1.4.9-10-beta-$BetaNumber-$($BuildDate.Substring(0,10))-RDS-x86_64.exe") {
    throw 'Only own x64 payload files or the exact new package may be stamped.'
}
if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a linked build output.' }
$ancestor = $file.Directory
while ($ancestor -and $ancestor.FullName -cne $repo) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a linked build-output directory.' }
    $ancestor = $ancestor.Parent
}
if ((Get-AuthenticodeSignature -LiteralPath $file.FullName).Status -ne 'NotSigned') {
    throw 'Refusing to alter a signed or unverifiable executable.'
}

if (-not ('MasterDesk.BuildVersionResource' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace MasterDesk {
 public static class BuildVersionResource {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr BeginUpdateResourceW(string path, bool deleteExisting);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool UpdateResourceW(IntPtr handle, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool EndUpdateResourceW(IntPtr handle, bool discard);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
  [DllImport("kernel32.dll")]
  static extern bool FreeLibrary(IntPtr module);
  delegate bool LanguageCallback(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr parameter);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool EnumResourceLanguagesW(IntPtr module, IntPtr type, IntPtr name, LanguageCallback callback, IntPtr parameter);
  static void Align(BinaryWriter w) { while ((w.BaseStream.Position & 3) != 0) w.Write((byte)0); }
  static byte[] Block(string key, ushort type, ushort count, byte[] value, params byte[][] children) {
   using (var m = new MemoryStream()) using (var w = new BinaryWriter(m)) {
    w.Write((ushort)0); w.Write(count); w.Write(type);
    w.Write(Encoding.Unicode.GetBytes(key + "\0")); Align(w);
    if (value != null) w.Write(value);
    foreach (var child in children) { Align(w); w.Write(child); }
    if (m.Length > ushort.MaxValue) throw new InvalidOperationException("Version resource too large");
    long size = m.Length; m.Position = 0; w.Write((ushort)size); return m.ToArray();
   }
  }
  public static void Stamp(string path, int beta, string date, string copyright) {
   string version = "1.4.9-10 beta " + beta;
   var strings = new Dictionary<string,string> {
    {"CompanyName", "MasterDesk contributors"}, {"ProductName", "MasterDesk"},
    {"FileDescription", "MasterDesk Remote Desktop"}, {"FileVersion", version},
    {"ProductVersion", version}, {"InternalName", Path.GetFileNameWithoutExtension(path)},
    {"OriginalFilename", Path.GetFileName(path)}, {"LegalCopyright", copyright},
    {"Comments", "Build date: " + date}
   };
   var leaves = new List<byte[]>();
   foreach (var p in strings) leaves.Add(Block(p.Key, 1, checked((ushort)(p.Value.Length+1)), Encoding.Unicode.GetBytes(p.Value+"\0")));
   byte[] fixedInfo;
   using (var m = new MemoryStream()) using (var w = new BinaryWriter(m)) {
    uint[] values = {0xFEEF04BD,0x10000,0x10004,(uint)((9<<16)|beta),0x10004,
     (uint)((9<<16)|beta),0x3f,0,0x40004,Path.GetExtension(path).Equals(".dll",StringComparison.OrdinalIgnoreCase)?2u:1u,0,0,0};
    foreach (uint v in values) w.Write(v); fixedInfo=m.ToArray();
   }
   byte[] data=Block("VS_VERSION_INFO",0,(ushort)fixedInfo.Length,fixedInfo,
    Block("StringFileInfo",1,0,null,Block("040904b0",1,0,null,leaves.ToArray())),
    Block("VarFileInfo",1,0,null,Block("Translation",0,4,new byte[]{9,4,176,4})));
   // Read resources as data only, never execute a fixture or DLL entry point.
   var languages=new List<ushort>();
   IntPtr module=LoadLibraryExW(path,IntPtr.Zero,0x22);
   if(module==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    LanguageCallback callback=(m,t,n,l,p)=>{languages.Add(l);return true;};
    bool found=EnumResourceLanguagesW(module,new IntPtr(16),new IntPtr(1),callback,IntPtr.Zero);
    int error=Marshal.GetLastWin32Error();
    if(!found && error!=1812 && error!=1813 && error!=1814 && error!=1815)
     throw new Win32Exception(error);
   } finally { FreeLibrary(module); }
   IntPtr handle=BeginUpdateResourceW(path,false);
   if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
   bool committed=false;
   try {
    foreach(ushort language in languages)
     if(!UpdateResourceW(handle,new IntPtr(16),new IntPtr(1),language,null,0))
      throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!UpdateResourceW(handle,new IntPtr(16),new IntPtr(1),0x409,data,(uint)data.Length))
     throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!EndUpdateResourceW(handle,false)) throw new Win32Exception(Marshal.GetLastWin32Error());
    committed=true;
   } finally { if(!committed) EndUpdateResourceW(handle,true); }
  }
 }
}
'@
}
$oldCopyright = $file.VersionInfo.LegalCopyright
$copyright = if ([string]::IsNullOrWhiteSpace($oldCopyright)) {
    'MasterDesk contributors; upstream RustDesk copyrights retained in NOTICE. AGPL-3.0.'
} elseif ($oldCopyright.Contains('Modified by MasterDesk contributors.')) { $oldCopyright }
else { $oldCopyright.TrimEnd([char]0) + ' Modified by MasterDesk contributors.' }
[MasterDesk.BuildVersionResource]::Stamp($file.FullName,$BetaNumber,$BuildDate,$copyright)
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
if ($version.ProductName -cne 'MasterDesk' -or
    $version.ProductVersion -cne "1.4.9-10 beta $BetaNumber" -or
    $version.CompanyName -cne 'MasterDesk contributors' -or
    $version.FilePrivatePart -ne $BetaNumber) { throw 'PE metadata verification failed.' }
[ordered]@{Path=$file.FullName;Product=$version.ProductName;Version=$version.ProductVersion;
    PublisherMetadata=$version.CompanyName;Beta=$version.FilePrivatePart;
    SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash} | ConvertTo-Json -Compress
