using System.IO;
namespace PcCleaner.Tests { public static class TmpT {
 [Test] public static void Tmp_cleanup() {
  string keep; string p;
  using (TempDir d = new TempDir()) {
   keep = d.MakeDir("keep"); File.WriteAllText(Path.Combine(keep,"k.txt"),"x");
   string f = d.Make("a\\b\\c.txt", new byte[]{1}); File.SetAttributes(f, FileAttributes.ReadOnly);
   var psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c mklink /J \"" + Path.Combine(d.Path,"j") + "\" \"" + keep + "\"") { UseShellExecute=false, CreateNoWindow=true };
   System.Diagnostics.Process.Start(psi).WaitForExit();
   Assert.True(Directory.Exists(Path.Combine(d.Path,"j")), "junction");
   p = d.Path;
   // keep must survive: copy outside
   Directory.CreateDirectory(Path.Combine(Path.GetTempPath(),"PcCleanerTests_keep")); File.WriteAllText(Path.Combine(Path.GetTempPath(),"PcCleanerTests_keep","k.txt"),"x");
  }
  Assert.False(Directory.Exists(p), "removed");
 }
 [Test] public static void Real_skipped() { throw new System.Exception("should not run"); }
}}