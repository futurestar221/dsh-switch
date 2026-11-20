using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: AssemblyTitle("dsh-switch")]
[assembly: AssemblyDescription("DSH 多环境切换器")]
[assembly: AssemblyProduct("dsh-switch")]
[assembly: AssemblyCompany("dsh-switch contributors")]
[assembly: AssemblyCopyright("Copyright (c) 2026 dsh-switch contributors")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]

namespace DshManagerApp
{
    internal static class AppLog
    {
        private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "dsh-manager", "native.log");

        public static void Write(string message)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + message + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        public static string LogPathForUser()
        {
            return LogPath;
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool created;
            using (var mutex = new Mutex(true, @"Local\dsh-switch.SingleInstance", out created))
            {
                if (!created)
                {
                    AppLog.Write("另一个实例已在运行，尝试激活现有窗口");
                    NativeWindowHelper.ActivateExisting();
                    return;
                }
                AppLog.Write("程序启动");
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
        }
    }

    internal static class NativeWindowHelper
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        public static void ActivateExisting()
        {
            IntPtr hwnd = FindWindow(null, "dsh-switch");
            if (hwnd == IntPtr.Zero) return;
            ShowWindow(hwnd, 9);
            SetForegroundWindow(hwnd);
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly WebView2 browser;
        private readonly Panel loading;
        private readonly Label loadingTitle;
        private readonly Label loadingDetail;
        private readonly ProgressBar progress;
        private readonly Panel loadingCard;
        private readonly string managerRoot;
        private bool closing;
        private int backendPort;

        public MainForm()
        {
            managerRoot = FindManagerRoot();
            Text = "dsh-switch";
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(246, 247, 251);
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            browser = new WebView2();
            browser.Dock = DockStyle.Fill;
            browser.DefaultBackgroundColor = Color.FromArgb(246, 247, 251);
            Controls.Add(browser);

            loading = new Panel();
            loading.Dock = DockStyle.Fill;
            loading.BackColor = Color.FromArgb(246, 247, 251);
            Controls.Add(loading);
            loading.BringToFront();

            loadingCard = new Panel();
            loadingCard.Size = new Size(380, 220);
            loadingCard.BackColor = Color.Transparent;
            loading.Controls.Add(loadingCard);

            var logo = new PictureBox();
            logo.Size = new Size(68, 68);
            logo.SizeMode = PictureBoxSizeMode.Zoom;
            logo.Left = (loadingCard.Width - logo.Width) / 2;
            logo.Top = 6;
            try { logo.Image = Icon.ToBitmap(); } catch { }
            loadingCard.Controls.Add(logo);

            loadingTitle = new Label();
            loadingTitle.Text = "dsh-switch";
            loadingTitle.Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point);
            loadingTitle.ForeColor = Color.FromArgb(15, 23, 42);
            loadingTitle.TextAlign = ContentAlignment.MiddleCenter;
            loadingTitle.SetBounds(0, 84, loadingCard.Width, 32);
            loadingCard.Controls.Add(loadingTitle);

            loadingDetail = new Label();
            loadingDetail.Text = "正在启动本地服务…";
            loadingDetail.Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);
            loadingDetail.ForeColor = Color.FromArgb(100, 116, 139);
            loadingDetail.TextAlign = ContentAlignment.MiddleCenter;
            loadingDetail.SetBounds(0, 118, loadingCard.Width, 24);
            loadingCard.Controls.Add(loadingDetail);

            progress = new ProgressBar();
            progress.Style = ProgressBarStyle.Marquee;
            progress.MarqueeAnimationSpeed = 28;
            progress.SetBounds(60, 164, 260, 8);
            loadingCard.Controls.Add(progress);

            loading.Resize += delegate { CenterLoadingCard(); };
            Shown += OnShown;
            FormClosing += OnFormClosing;
            HandleCreated += delegate { WindowEffects.Apply(this.Handle); };
            Load += delegate { ApplyInitialWindowSize(); };
        }

        private void ApplyInitialWindowSize()
        {
            float scale = WindowEffects.GetDpiForWindow(Handle) / 96f;
            if (scale < 0.75f) scale = 0.75f;
            if (scale > 3f) scale = 3f;
            Rectangle work = Screen.FromHandle(Handle).WorkingArea;
            int margin = (int)Math.Round(24 * scale);
            int targetW = (int)Math.Round(1100 * scale);
            int targetH = (int)Math.Round(760 * scale);
            int maxW = Math.Max((int)Math.Round(880 * scale), work.Width - margin * 2);
            int maxH = Math.Max((int)Math.Round(620 * scale), work.Height - margin * 2);
            ClientSize = new Size(Math.Min(targetW, maxW), Math.Min(targetH, maxH));
            int borderW = Width - ClientSize.Width;
            int borderH = Height - ClientSize.Height;
            MinimumSize = new Size(
                (int)Math.Round(900 * scale) + borderW,
                (int)Math.Round(620 * scale) + borderH);
            Left = work.Left + Math.Max(0, (work.Width - Width) / 2);
            Top = work.Top + Math.Max(0, (work.Height - Height) / 2);
            AppLog.Write(
                "窗口尺寸: dpi=" + WindowEffects.GetDpiForWindow(Handle) +
                " scale=" + scale.ToString("0.###") +
                " work=" + work.Left + "," + work.Top + "," + work.Width + "," + work.Height +
                " client=" + ClientSize.Width + "," + ClientSize.Height +
                " bounds=" + Left + "," + Top + "," + Width + "," + Height +
                " state=" + WindowState);
        }

        private void CenterLoadingCard()
        {
            loadingCard.Left = Math.Max(0, (loading.ClientSize.Width - loadingCard.Width) / 2);
            loadingCard.Top = Math.Max(0, (loading.ClientSize.Height - loadingCard.Height) / 2);
        }

        private async void OnShown(object sender, EventArgs e)
        {
            CenterLoadingCard();
            try
            {
                backendPort = await Task.Run(delegate { return Backend.EnsureRunning(managerRoot, SetLoadingDetail); });
                if (closing) return;

                SetLoadingDetail("正在载入工作台…");
                string dataFolder = ResolveWebViewDataFolder();
                Directory.CreateDirectory(dataFolder);
                CoreWebView2EnvironmentOptions options = new CoreWebView2EnvironmentOptions();
                string extraArgs = Environment.GetEnvironmentVariable("DSH_WEBVIEW2_BROWSER_ARGS");
                if (!String.IsNullOrWhiteSpace(extraArgs)) options.AdditionalBrowserArguments = extraArgs;
                AppLog.Write("初始化 WebView2，数据目录=" + dataFolder + "，额外参数=" + (extraArgs ?? ""));
                CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, dataFolder, options);
                await browser.EnsureCoreWebView2Async(environment);
                if (closing) return;

                CoreWebView2 core = browser.CoreWebView2;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.IsZoomControlEnabled = false;
                core.Settings.IsSwipeNavigationEnabled = false;
                core.NewWindowRequested += delegate(object s, CoreWebView2NewWindowRequestedEventArgs args)
                {
                    args.Handled = true;
                    Uri uri;
                    if (Uri.TryCreate(args.Uri, UriKind.Absolute, out uri) && (uri.Scheme == "http" || uri.Scheme == "https"))
                    {
                        try { Process.Start(new ProcessStartInfo(args.Uri) { UseShellExecute = true }); } catch { }
                    }
                };
                core.NavigationCompleted += delegate(object s, CoreWebView2NavigationCompletedEventArgs args)
                {
                    if (args.IsSuccess)
                    {
                        loading.Visible = false;
                        browser.BringToFront();
                    }
                    else if (!closing)
                    {
                        AppLog.Write("页面载入失败：" + args.WebErrorStatus);
                        SetLoadingDetail("页面载入失败，正在重试…");
                        browser.Reload();
                    }
                };
                core.WindowCloseRequested += delegate
                {
                    if (closing) return;
                    try { BeginInvoke(new Action(Close)); } catch { Close(); }
                };
                core.ProcessFailed += delegate(object s, CoreWebView2ProcessFailedEventArgs args)
                {
                    AppLog.Write("WebView2 进程失败：" + args.ProcessFailedKind + " / " + args.ProcessDescription + " / exit=" + args.ExitCode);
                    if (!closing)
                    {
                        MessageBox.Show(this, "管理界面进程异常退出。\r\n\r\n" + args.ProcessFailedKind +
                            "\r\n日志：" + AppLog.LogPathForUser(), "dsh-switch",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };
                AppLog.Write("导航到 http://127.0.0.1:" + backendPort + "/");
                core.Navigate("http://127.0.0.1:" + backendPort + "/");
                Text = "dsh-switch";
            }
            catch (Exception ex)
            {
                AppLog.Write("启动失败：" + ex);
                if (closing) return;
                loading.Visible = false;
                MessageBox.Show(this,
                    "dsh-switch 启动失败。\r\n\r\n" + ex.Message + "\r\n\r\n程序目录：" + managerRoot,
                    "dsh-switch", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close();
            }
        }

        private void SetLoadingDetail(string text)
        {
            if (closing || IsDisposed) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<string>(SetLoadingDetail), text); } catch { }
                return;
            }
            loadingDetail.Text = text;
        }

        private static string ResolveWebViewDataFolder()
        {
            string preferred = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dsh-manager", "webview2");
            try
            {
                Directory.CreateDirectory(preferred);
                return preferred;
            }
            catch
            {
                string fallback = Path.Combine(Path.GetTempPath(), "dsh-manager", "webview2");
                Directory.CreateDirectory(fallback);
                return fallback;
            }
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (closing) return;
            closing = true;
            progress.MarqueeAnimationSpeed = 0;
            try { Backend.Quit(backendPort); } catch { }
        }

        private static string FindManagerRoot()
        {
            string configured = Environment.GetEnvironmentVariable("DSH_SWITCH_ROOT");
            if (String.IsNullOrWhiteSpace(configured))
            {
                configured = Environment.GetEnvironmentVariable("DSH_MANAGER_ROOT");
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string parent = Path.GetFullPath(Path.Combine(baseDir, ".."));
            string[] candidates = new string[]
            {
                configured,
                parent,
                baseDir
            };
            foreach (string root in candidates)
            {
                if (String.IsNullOrWhiteSpace(root)) continue;
                try
                {
                    if (File.Exists(Path.Combine(root, "web", "start.ps1"))) return root;
                }
                catch { }
            }
            throw new DirectoryNotFoundException("找不到 dsh-switch 资源目录。请把 app 文件夹放在项目根目录，或设置 DSH_SWITCH_ROOT。");
        }
    }

    internal static class Backend
    {
        private static string PortFile
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "dsh-manager", "web.port");
            }
        }

        public static int EnsureRunning(string root, Action<string> report)
        {
            report("正在启动本地服务…");
            int current = ReadLivePort();
            if (current > 0) return current;

            string script = Path.Combine(root, "web", "start.ps1");
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            var info = new ProcessStartInfo();
            info.FileName = powershell;
            info.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -NoWindow";
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(info);

            for (int i = 0; i < 100; i++)
            {
                Thread.Sleep(250);
                current = ReadLivePort();
                if (current > 0)
                {
                    report("本地服务已就绪，正在打开界面…");
                    return current;
                }
                if (i == 12) report("首次启动需要准备配置，请稍候…");
            }
            throw new TimeoutException("本地服务在 25 秒内没有就绪。请检查管理器日志和浏览器安全软件拦截。");
        }

        private static int ReadLivePort()
        {
            try
            {
                if (!File.Exists(PortFile)) return 0;
                int port;
                if (!Int32.TryParse(File.ReadAllText(PortFile).Trim(), out port) || port <= 0) return 0;
                using (var client = new TcpClient())
                {
                    IAsyncResult result = client.BeginConnect("127.0.0.1", port, null, null);
                    if (!result.AsyncWaitHandle.WaitOne(350)) return 0;
                    client.EndConnect(result);
                    return port;
                }
            }
            catch { return 0; }
        }

        public static void Quit(int port)
        {
            if (port <= 0) return;
            try
            {
                var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/api/quit");
                request.Method = "POST";
                request.ContentType = "application/json";
                request.Headers["X-Dshm"] = "1";
                request.Timeout = 700;
                request.ReadWriteTimeout = 700;
                request.Proxy = null;
                byte[] body = System.Text.Encoding.UTF8.GetBytes("{}");
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (request.GetResponse()) { }
            }
            catch { }
        }
    }

    internal static class WindowEffects
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);

        public static void Apply(IntPtr handle)
        {
            try
            {
                int preference = 2;
                DwmSetWindowAttribute(handle, 33, ref preference, sizeof(int));
            }
            catch { }
        }
    }
}
