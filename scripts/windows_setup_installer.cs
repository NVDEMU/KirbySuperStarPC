using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

internal static class KirbySuperStarSetupInstaller
{
    private const string ResourceName = "KirbySetupPack.zip";
    private const string ExeName = "KirbySuperStarSNESRecomp.exe";

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string target = Path.Combine(local, "Programs", "Kirby Super Star Recomp");
        DialogResult answer = MessageBox.Show(
            "Install or update Kirby Super Star Recomp for this Windows account?\n\n" +
            "Destination:\n" + target + "\n\n" +
            "The setup pack does not include a ROM. Your local ROM selection, settings, " +
            "saves, mod state, and generated game files will be preserved.",
            "Kirby Super Star Recomp Setup",
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Information);
        if (answer != DialogResult.OK) return;

        Form progress = new Form();
        progress.Text = "Kirby Super Star Recomp Setup";
        progress.Width = 500;
        progress.Height = 145;
        progress.FormBorderStyle = FormBorderStyle.FixedDialog;
        progress.StartPosition = FormStartPosition.CenterScreen;
        progress.MaximizeBox = false;
        progress.MinimizeBox = false;
        progress.ControlBox = false;
        Label label = new Label();
        label.Left = 16;
        label.Top = 14;
        label.Width = 455;
        label.Text = "Validating the setup pack...";
        ProgressBar bar = new ProgressBar();
        bar.Left = 16;
        bar.Top = 48;
        bar.Width = 455;
        bar.Height = 22;
        bar.Minimum = 0;
        bar.Maximum = 1;
        progress.Controls.Add(label);
        progress.Controls.Add(bar);
        progress.Show();
        Application.DoEvents();

        try
        {
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (resource == null) throw new InvalidDataException("The embedded setup pack is missing.");
                using (ZipArchive archive = new ZipArchive(resource, ZipArchiveMode.Read, false))
                {
                    string packRoot = ValidateArchive(archive);
                    Directory.CreateDirectory(target);
                    string targetFull = Path.GetFullPath(target);
                    string targetPrefix = targetFull.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

                    bar.Maximum = Math.Max(1, archive.Entries.Count);
                    int index = 0;
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        index++;
                        if (index % 20 == 0 || index == archive.Entries.Count)
                        {
                            label.Text = "Installing files... " + index + " / " + archive.Entries.Count;
                            bar.Value = Math.Min(bar.Maximum, index);
                            Application.DoEvents();
                        }

                        string name = entry.FullName.Replace('\\', '/');
                        string[] parts = name.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                        if (parts.Length == 0 || !String.Equals(parts[0], packRoot, StringComparison.Ordinal)) continue;
                        if (parts.Length == 1) continue; // The top-level directory itself.

                        string relative = String.Join(Path.DirectorySeparatorChar.ToString(), parts, 1, parts.Length - 1);
                        if (ShouldPreserve(relative)) continue;

                        string destination = Path.GetFullPath(Path.Combine(targetFull, relative));
                        if (!destination.StartsWith(targetPrefix, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("An archive entry resolves outside the install folder.");

                        bool isDirectory = name.EndsWith("/", StringComparison.Ordinal) ||
                            entry.Length == 0 && (entry.ExternalAttributes & (int)0x10) != 0;
                        if (isDirectory)
                        {
                            Directory.CreateDirectory(destination);
                            continue;
                        }

                        string parent = Path.GetDirectoryName(destination);
                        if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                        string temporary = destination + ".kirby-install-" + Guid.NewGuid().ToString("N") + ".tmp";
                        try
                        {
                            using (Stream input = entry.Open())
                            using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                            {
                                input.CopyTo(output);
                            }

                            if (File.Exists(destination))
                            {
                                File.Replace(temporary, destination, null);
                            }
                            else
                            {
                                File.Move(temporary, destination);
                            }
                        }
                        finally
                        {
                            if (File.Exists(temporary)) File.Delete(temporary);
                        }
                    }
                }
            }

            string executable = Path.Combine(target, ExeName);
            if (!File.Exists(executable))
                throw new InvalidDataException("The setup pack was installed, but " + ExeName + " is missing.");

            progress.Close();
            MessageBox.Show(
                "Kirby Super Star Recomp is installed.\n\n" +
                "On first launch, choose your own verified ROM and select Generate & rebuild.\n" +
                "No disc image was included or copied from the build machine.",
                "Kirby Super Star Recomp Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);

            // If an earlier playable binary survived an update, offer it as an
            // explicit escape hatch instead of trapping the player in mandatory setup.
            // The warning is deliberate: the old binary may lack this update's fixes.
            string existingBuild = Path.Combine(target, "build", ExeName);
            if (File.Exists(existingBuild))
            {
                DialogResult existingChoice = MessageBox.Show(
                    "An existing playable build was detected.\n\n" +
                    "Yes: launch that build now and skip regenerating/rebuilding C. " +
                    "It may not include the latest runtime or graphics fixes.\n\n" +
                    "No: open Setup & rebuild and use the updated sources. The existing " +
                    "build will be kept either way.",
                    "Kirby Super Star Recomp",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (existingChoice == DialogResult.Yes)
                {
                    Process.Start(new ProcessStartInfo(existingBuild, "--launcher")
                    {
                        WorkingDirectory = target,
                        UseShellExecute = false
                    });
                    return;
                }
            }

            // Keep a small launch breadcrumb and detect a host that exits immediately.
            // Process.Start alone only proves Windows created a process; it does not
            // prove the native launcher survived startup.
            string diagnostics = Path.Combine(target, "launcher-diagnostics.log");
            try
            {
                File.AppendAllText(diagnostics, DateTime.Now.ToString("o") +
                    " Installer completed; launching " + executable + Environment.NewLine);
            }
            catch { }

            ProcessStartInfo launchInfo = new ProcessStartInfo(executable)
            {
                WorkingDirectory = target,
                // We need a child-specific environment to keep the setup host
                // from auto-handing-off to a previous build/ after an update.
                UseShellExecute = false
            };
            launchInfo.EnvironmentVariables["SNESRECOMP_NO_HANDOFF"] = "1";
            launchInfo.EnvironmentVariables["SNESRECOMP_FORCE_SETUP"] = "1";
            Process launched = Process.Start(launchInfo);
            if (launched == null)
                throw new InvalidOperationException("Windows did not return a process for the setup host.");

            if (launched.WaitForExit(4000))
            {
                string detail = "Setup host exited within four seconds (exit code " +
                    launched.ExitCode + ").";
                try
                {
                    File.AppendAllText(diagnostics, DateTime.Now.ToString("o") +
                        " " + detail + Environment.NewLine);
                }
                catch { }

                MessageBox.Show(
                    detail + "\\n\\nIf you did not close it yourself, check the diagnostic log:\\n" +
                    diagnostics + "\\n\\nThe installed files were left in place.",
                    "Kirby Super Star Recomp did not stay open",
                    MessageBoxButtons.OK,
                    launched.ExitCode == 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Error);
            }
        }
        catch (Exception ex)
        {
            progress.Close();
            MessageBox.Show(
                "Installation failed. Your existing ROM selection and generated game files were not intentionally removed.\n\n" +
                ex.Message,
                "Kirby Super Star Recomp Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static string ValidateArchive(ZipArchive archive)
    {
        HashSet<string> roots = new HashSet<string>(StringComparer.Ordinal);
        foreach (ZipArchiveEntry entry in archive.Entries)
        {
            string raw = entry.FullName.Replace('\\', '/');
            if (String.IsNullOrEmpty(raw) || raw.StartsWith("/", StringComparison.Ordinal))
                throw new InvalidDataException("The setup archive contains an invalid path.");

            string[] parts = raw.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) continue;
            if (parts[0].Contains(":"))
                throw new InvalidDataException("The setup archive contains a drive-qualified path.");
            foreach (string part in parts)
            {
                if (part == "." || part == "..")
                    throw new InvalidDataException("The setup archive contains a path traversal entry.");
            }

            int unixMode = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixMode == 0xA000)
                throw new InvalidDataException("The setup archive contains a symbolic link.");

            roots.Add(parts[0]);
            if (Path.GetFileName(raw).Equals("rom.cfg", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The setup archive contains a machine-specific ROM path cache.");
            string lower = raw.ToLowerInvariant();
            if (lower.EndsWith(".sfc") || lower.EndsWith(".smc") || lower.EndsWith(".srm") || lower.EndsWith(".fig"))
                throw new InvalidDataException("The setup archive contains ROM or memory-card data.");
        }

        if (roots.Count != 1)
            throw new InvalidDataException("The setup archive must contain exactly one top-level folder.");
        string root = null;
        foreach (string candidate in roots) root = candidate;
        if (root == null || !root.StartsWith("kirbysuperstar-", StringComparison.Ordinal))
            throw new InvalidDataException("The embedded archive is not a Kirby Super Star setup pack.");
        return root;
    }

    private static bool ShouldPreserve(string relative)
    {
        string normalized = relative.Replace('\\', '/');
        string lower = normalized.ToLowerInvariant();
        string first = lower.Split('/')[0];

        if (first == "rom.cfg" || first == "config.ini" || first == "keybinds.ini" ||
            first == "input.ini" || first == "controller.ini" || first == "settings.toml" ||
            first == "game_options.toml" || first == "saves" || first == "build")
            return true;
        if (lower == "recomp/funcs.h" || lower.StartsWith("src/gen/", StringComparison.Ordinal))
            return true;
        if (lower == "mods/state.toml" || lower.StartsWith("mods/custom/", StringComparison.Ordinal) ||
            lower.StartsWith("mods/installed/", StringComparison.Ordinal))
            return true;
        string extension = Path.GetExtension(lower);
        if (extension == ".srm" || extension == ".sav" || extension == ".state")
            return true;
        return false;
    }
}
