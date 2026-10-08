// Setup.cs — однофайловый установщик KeePass Kit. Внутри exe лежат install.ps1, kit.json, официальный
// установщик KeePass и плагины: он распаковывает их во временную папку и запускает install.ps1 без окна
// консоли. Требует прав администратора (манифест), поэтому окно UAC появляется один раз — при запуске.
// Сборка — build.ps1. Один исходник, два файла:
//   KeePass-Kit-Setup.exe         мастер «Установить → Готово»
//   KeePass-Kit-Setup-Silent.exe  без окон (то же даёт ключ /silent у первого)
// Ключи передаются в install.ps1: /nowinhello /withwinhello /noguard /nostart
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("KeePass Kit Setup")]
[assembly: AssemblyProduct("KeePass Kit")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

public static class Setup
{
    public const string Title = "KeePass Kit";
    public static bool Ru = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
    public static string T(string ru, string en) { return Ru ? ru : en; }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    public static string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"KeePassKit\setup-tmp");
    public static string PsArgs = "";

    static readonly Dictionary<string, string> Passthrough = new Dictionary<string, string> {
        { "nowinhello", "-NoWinHello" }, { "withwinhello", "-WithWinHello" }, { "noguard", "-NoGuard" }, { "nostart", "-NoStart" }
    };

    [STAThread]
    static int Main(string[] args)
    {
        bool silent = Path.GetFileNameWithoutExtension(Application.ExecutablePath).IndexOf("silent", StringComparison.OrdinalIgnoreCase) >= 0;
        foreach (string a in args)
        {
            string s = a.TrimStart('/', '-').ToLowerInvariant();
            if (s == "silent" || s == "verysilent" || s == "quiet" || s == "s" || s == "q") silent = true;
            else if (Passthrough.ContainsKey(s)) PsArgs += " " + Passthrough[s];
        }
        if (silent)
        {
            try { string o, e; return RunInstall("-Silent" + PsArgs, out o, out e); } catch { return 1; }
        }
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Wizard w = new Wizard();
        Application.Run(w);
        return w.ExitCode;
    }

    // распаковать вложенные файлы в рабочую папку, выполнить install.ps1, убрать распакованное; вернуть код выхода
    public static int RunInstall(string psArgs, out string stdout, out string stderr)
    {
        string dir = Dir;
        Directory.CreateDirectory(dir);
        Assembly asm = Assembly.GetExecutingAssembly();
        List<string> files = new List<string>();
        foreach (string name in asm.GetManifestResourceNames())
        {
            string path = Path.Combine(dir, name);
            using (Stream src = asm.GetManifestResourceStream(name))
            using (FileStream dst = File.Create(path))
                src.CopyTo(dst);
            files.Add(path);
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
        string argLine = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "install.ps1") + "\" -NoFinishBox -Dir \"" + dir + "\" " + psArgs;
        ProcessStartInfo psi = new ProcessStartInfo(ps, argLine);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        try
        {
            using (Process p = Process.Start(psi))
            {
                Task<string> err = p.StandardError.ReadToEndAsync();
                stdout = p.StandardOutput.ReadToEnd();
                stderr = err.Result;
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        finally
        {
            foreach (string f in files) { try { File.Delete(f); } catch { } }
            try { if (Directory.GetFileSystemEntries(dir).Length == 0) Directory.Delete(dir); } catch { }
        }
    }

    // строки после «=== ИТОГ ===» без отметки времени
    public static string Summary(string stdout)
    {
        StringBuilder sb = new StringBuilder();
        bool on = false;
        foreach (string raw in (stdout ?? "").Split('\n'))
        {
            string line = raw.TrimEnd('\r');
            if (line.Length > 20 && line[4] == '-' && line[13] == ':') line = line.Substring(20);
            if (line.StartsWith("=== ")) { on = line.Contains("ИТОГ"); continue; }
            if (on && line.Trim().Length > 0) sb.AppendLine(line);
        }
        return sb.ToString().Trim();
    }
}

// Мастер: 0 приветствие → 2 установка → 3 готово
public class Wizard : Form
{
    public int ExitCode = 1;
    int page;
    string error, summary;
    Label head, sub, body;
    ProgressBar bar;
    Button next, cancel;
    static string T(string ru, string en) { return Setup.T(ru, en); }
    float scale = 1F;
    int S(int v) { return (int)Math.Round(v * scale); }
    Point P(int x, int y) { return new Point(S(x), S(y)); }
    Size Z(int w, int h) { return new Size(S(w), S(h)); }

    public Wizard()
    {
        SuspendLayout();
        AutoScaleMode = AutoScaleMode.None;
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96F;
        ClientSize = Z(500, 384);
        Text = T("Установка ", "Setup — ") + Setup.Title;
        Font = new Font("Segoe UI", 9F);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        Panel header = new Panel(); header.BackColor = Color.White; header.Location = P(0, 0); header.Size = Z(500, 66);
        head = new Label(); head.Font = new Font("Segoe UI", 11F, FontStyle.Bold); head.Location = P(18, 12); head.Size = Z(464, 24);
        sub = new Label(); sub.ForeColor = Color.FromArgb(90, 90, 90); sub.Location = P(18, 38); sub.Size = Z(464, 20);
        header.Controls.Add(head); header.Controls.Add(sub);
        Label line1 = new Label(); line1.BorderStyle = BorderStyle.Fixed3D; line1.Location = P(0, 66); line1.Size = Z(500, 2);

        body = new Label(); body.Location = P(24, 82); body.Size = Z(452, 244);
        bar = new ProgressBar(); bar.Style = ProgressBarStyle.Marquee; bar.MarqueeAnimationSpeed = 30; bar.Location = P(24, 150); bar.Size = Z(452, 18); bar.Visible = false;

        Label line2 = new Label(); line2.BorderStyle = BorderStyle.Fixed3D; line2.Location = P(0, 332); line2.Size = Z(500, 2);
        next = new Button(); next.Location = P(300, 346); next.Size = Z(88, 26);
        cancel = new Button(); cancel.Text = T("Отмена", "Cancel"); cancel.Location = P(400, 346); cancel.Size = Z(88, 26);
        next.Click += delegate { if (page == 0) StartInstall(); else Close(); };
        cancel.Click += delegate { Close(); };
        AcceptButton = next; CancelButton = cancel;

        Controls.Add(bar); Controls.Add(body);
        Controls.Add(header); Controls.Add(line1); Controls.Add(line2);
        Controls.Add(next); Controls.Add(cancel);
        ResumeLayout(false);
        PerformLayout();

        FormClosing += delegate(object s, FormClosingEventArgs e) { if (page == 2) e.Cancel = true; };
        ShowPage(0);
    }

    public void ShowPage(int p)
    {
        page = p;
        body.Visible = (p != 2);
        bar.Visible = (p == 2);
        next.Enabled = (p != 2);
        cancel.Enabled = (p < 2);
        switch (p)
        {
            case 0:
                head.Text = T("Установка KeePass с плагинами и настройками", "KeePass with plugins and settings");
                sub.Text = T("KeePass 2.x, KeeAgent, значки сайтов, вход по отпечатку", "KeePass 2.x, KeeAgent, site icons, fingerprint unlock");
                body.Text = T("Установщик приведёт KeePass на этом компьютере к одному виду:\n\n"
                            + "•  поставит или обновит KeePass;\n"
                            + "•  поставит плагины KeeAgent (SSH-агент), Yet Another Favicon Downloader (значки сайтов) "
                            + "и KeePassWinHello (вход по отпечатку, если есть сканер);\n"
                            + "•  уберёт устаревшие KeePassHttp и KeePassFaviconDownloader;\n"
                            + "•  включит запуск свёрнутым и заблокированным, автозапуск, откроет базу из Dropbox;\n"
                            + "•  выключит службу Windows ssh-agent и поставит сторожа, чтобы KeeAgent не терял канал.\n\n"
                            + "Если KeePass открыт, он будет закрыт и запущен снова.",
                              "Setup brings KeePass on this computer to a standard state:\n\n"
                            + "•  installs or updates KeePass;\n"
                            + "•  installs KeeAgent (SSH agent), Yet Another Favicon Downloader (site icons) "
                            + "and KeePassWinHello (fingerprint unlock, if a reader is present);\n"
                            + "•  removes the obsolete KeePassHttp and KeePassFaviconDownloader;\n"
                            + "•  start minimized and locked, autostart, opens the database from Dropbox;\n"
                            + "•  disables the Windows ssh-agent service and installs a guard so KeeAgent keeps the pipe.\n\n"
                            + "If KeePass is open, it will be closed and started again.");
                next.Text = T("Установить", "Install");
                break;
            case 2:
                head.Text = T("Установка", "Installing");
                sub.Text = T("Подождите, это может занять минуту", "Please wait, this may take a minute");
                break;
            case 3:
                head.Text = T("Готово", "Done");
                sub.Text = T("KeePass установлен и настроен", "KeePass is installed and configured");
                body.Text = (string.IsNullOrEmpty(summary) ? "" : summary + "\n\n")
                          + T("Журнал: ", "Log: ") + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"KeePassKit\install.log");
                next.Text = T("Готово", "Finish");
                next.Focus();
                break;
        }
    }

    void StartInstall()
    {
        ShowPage(2);
        Task.Factory.StartNew<int>(delegate
        {
            try
            {
                string o, e;
                int c = Setup.RunInstall(Setup.PsArgs, out o, out e);
                summary = Setup.Summary(o);
                if (c != 0) error = string.IsNullOrEmpty(e) ? o : e;
                return c;
            }
            catch (Exception ex) { error = ex.Message; return 1; }
        }).ContinueWith(delegate(Task<int> t) { Done(t.Result); }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Done(int code)
    {
        ExitCode = code;
        page = 3;
        if (code != 0)
        {
            MessageBox.Show(this, T("Установка не удалась:\n\n", "Installation failed:\n\n") + (error ?? "").Trim(), Setup.Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
            return;
        }
        ShowPage(3);
        Activate();
    }
}
