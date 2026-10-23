using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

internal static class KirbySuperStarPlayableInstaller
{
    private const string ResourceName = "KirbyPlayablePack.zip";
    private const string ExeRelativePath = "build\\KirbySuperStarSNESRecomp.exe";

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string target = Path.Combine(local, "Programs", "Kirby Super Star Recomp");
        DialogResult choice = MessageBox.Show(
            "Install or update the playable Kirby Super Star Recomp build?\\n\\n" +
            "The game executable is prebuilt. On first launch, select your own verified ROM. " +
            "No ROM image is included.\\n\\nDestination:\\n" + target,
            "Kirby Super Star Recomp", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
        if (choice != DialogResult.OK) return;

        try
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (stream == null) throw new InvalidDataException("Embedded playable package is missing.");
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read, false))
                {
                    string root = ValidateArchive(archive);
                    Directory.CreateDirectory(target);
                    string targetFull = Path.GetFullPath(target);
                    string targetPrefix = targetFull.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string raw = entry.FullName.Replace('\\', '/');
                        string[] parts = raw.Split(new char[] {'/'}, StringSplitOptions.RemoveEmptyEntries);
                        if (parts.Length == 0 || !String.Equals(parts[0], root, StringComparison.Ordinal)) continue;
                        if (parts.Length == 1) continue;
                        string relative = String.Join(Path.DirectorySeparatorChar.ToString(), parts, 1, parts.Length - 1);
                        if (ShouldPreserve(relative)) continue;
                        string destination = Path.GetFullPath(Path.Combine(targetFull, relative));
                        if (!destination.StartsWith(targetPrefix, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Archive path resolves outside install directory.");
                        bool isDirectory = raw.EndsWith("/", StringComparison.Ordinal) ||
                            (entry.Length == 0 && (entry.ExternalAttributes & (int)0x10) != 0);
                        if (isDirectory) { Directory.CreateDirectory(destination); continue; }
                        string parent = Path.GetDirectoryName(destination);
                        if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                        string temporary = destination + ".kirby-install-" + Guid.NewGuid().ToString("N") + ".tmp";
                        try
                        {
                            using (Stream input = entry.Open())
                            using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                                input.CopyTo(output);
                            if (File.Exists(destination)) File.Replace(temporary, destination, null);
                            else File.Move(temporary, destination);
                        }
                        finally { if (File.Exists(temporary)) File.Delete(temporary); }
                    }
                }
            }
            string executable = Path.Combine(target, ExeRelativePath);
            if (!File.Exists(executable)) throw new InvalidDataException("Playable game executable is missing.");
            try { File.AppendAllText(Path.Combine(target, "playable-install.log"), DateTime.Now.ToString("o") + " Playable build installed.\r\n"); } catch { }
            ProcessStartInfo start = new ProcessStartInfo(executable) { WorkingDirectory = Path.GetDirectoryName(executable), UseShellExecute = false };
            Process game = Process.Start(start);
            if (game == null) throw new InvalidOperationException("Windows could not launch the game.");
        }
        catch (Exception ex)
        {
            MessageBox.Show("The playable build could not be installed.\n\n" + ex.Message,
                "Kirby Super Star Recomp", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static string ValidateArchive(ZipArchive archive)
    {
        HashSet<string> roots = new HashSet<string>(StringComparer.Ordinal);
        bool hasExe = false;
        foreach (ZipArchiveEntry entry in archive.Entries)
        {
            string raw = entry.FullName.Replace('\\', '/');
            if (String.IsNullOrEmpty(raw) || raw.StartsWith("/", StringComparison.Ordinal))
                throw new InvalidDataException("Archive has an invalid path.");
            string[] parts = raw.Split(new char[] {'/'}, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) continue;
            foreach (string part in parts)
                if (part == "." || part == ".." || part.Contains(":"))
                    throw new InvalidDataException("Archive contains a path traversal entry.");
            int unixMode = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixMode == 0xA000) throw new InvalidDataException("Archive contains a symbolic link.");
            roots.Add(parts[0]);
            string lower = raw.ToLowerInvariant();
            if (lower.EndsWith("/build/kirbysuperstarsnesrecomp.exe")) hasExe = true;
            if (Path.GetFileName(raw).Equals("rom.cfg", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Archive must not contain a machine-specific ROM path.");
            if (lower.EndsWith(".sfc") || lower.EndsWith(".smc") || lower.EndsWith(".fig") ||
                lower.EndsWith(".srm") || lower.EndsWith(".sav"))
                throw new InvalidDataException("Archive must not contain a ROM or save file.");
        }
        if (roots.Count != 1) throw new InvalidDataException("Archive must have one top-level folder.");
        string root = null; foreach (string item in roots) root = item;
        if (root == null || !root.StartsWith("kirbysuperstar-", StringComparison.Ordinal) ||
            !root.EndsWith("-playable", StringComparison.Ordinal))
            throw new InvalidDataException("Archive is not a Kirby playable package.");
        if (!hasExe) throw new InvalidDataException("Archive has no playable game executable.");
        return root;
    }

    private static bool ShouldPreserve(string relative)
    {
        string path = relative.Replace('\\', '/').ToLowerInvariant();
        if (path == "build/rom.cfg" || path == "build/config.ini" || path == "build/keybinds.ini" ||
            path == "build/input.ini" || path == "build/controller.ini" ||
            path == "build/settings.toml" || path == "build/game_options.toml" ||
            path == "build/launcher-window.ini" || path == "build/mods/state.toml") return true;
        if (path.StartsWith("build/saves/", StringComparison.Ordinal) ||
            path.StartsWith("build/mods/custom/", StringComparison.Ordinal) ||
            path.StartsWith("build/mods/installed/", StringComparison.Ordinal)) return true;
        string extension = Path.GetExtension(path);
        return extension == ".srm" || extension == ".sav" || extension == ".state";
    }
}
