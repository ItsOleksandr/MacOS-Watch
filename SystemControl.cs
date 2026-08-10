using System.Diagnostics;

namespace MacControl;

public static class SystemControl
{
    public static (int exit, string stdout, string stderr) Run(string file, string args)
    {
        using var p = new Process();
        p.StartInfo.FileName = file;
        p.StartInfo.Arguments = args;
        p.StartInfo.RedirectStandardOutput = true;
        p.StartInfo.RedirectStandardError = true;
        p.StartInfo.UseShellExecute = false;
        p.Start();
        var so = p.StandardOutput.ReadToEnd();
        var se = p.StandardError.ReadToEnd();
        p.WaitForExit(5000);
        return (p.ExitCode, so, se);
    }
    
    public static void RunDetached(string file, string args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = file,
            Arguments = args,
            UseShellExecute = false,
            RedirectStandardOutput = false,
            RedirectStandardError = false,
            CreateNoWindow = true,
        };
        Process.Start(psi);
    }

    public static void Osa(string script) => Run("/usr/bin/osascript", $"-e \"{script.Replace("\"", "\\\"")}\"");

    public static int GetVolume()
    {
        var r = Run("/usr/bin/osascript", "-e \"output volume of (get volume settings)\"");
        return int.TryParse(r.stdout.Trim(), out var v) ? v : 0;
    }

    public static void SetVolume(int v)
    {
        v = Math.Clamp(v, 0, 100);
        Osa($"set volume output volume {v}");
    }

    public static bool GetMuted()
    {
        var r = Run("/usr/bin/osascript", "-e \"output muted of (get volume settings)\"");
        return r.stdout.Trim() == "true";
    }

    public static void SetMuted(bool m) => Osa($"set volume {(m ? "with" : "without")} output muted");

    // Keypress via native CGEvent — no subprocess, no race, posts in microseconds.
    // Falls back to cliclick if the key isn't in the native map (e.g. exotic keys).
    public static void Key(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return;
        if (NativeInput.KeyTap(name)) return;
        var arg = name.Length == 1 ? $"t:{name}" : $"kp:{name}";
        RunDetached(Cliclick, arg);
    }

    // Media key — keep cliclick (kp:play-pause). Synthesizing system-defined media
    // events via CGEvent requires AppKit; cliclick handles it correctly and
    // play-pause isn't rapid-tapped, so subprocess cost is fine here.
    public static void PlayPause() => RunDetached(Cliclick, "kp:play-pause");

    // cliclick wrappers
    private const string Cliclick = "/usr/local/bin/cliclick";

    public static (int x, int y) GetMousePos() => NativeInput.GetMouse();

    public static void MouseMoveBy(int dx, int dy) => NativeInput.MoveBy(dx, dy);

    public static void MouseClick(string button = "left") => NativeInput.Click(button);

    public static void Scroll(int dy) => NativeInput.Scroll(dy);
}
