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

    // macOS key codes via System Events
    public static void KeyCode(int code) =>
        Osa($"tell application \\\"System Events\\\" to key code {code}");

    public static void PlayPause() => KeyCode(49); // Space (works in most video players when focused)
    public static void MediaPlayPause() => Run("/usr/bin/osascript", "-e \"tell application \\\"System Events\\\" to key code 49 using {}\"");

    // cliclick wrappers
    private const string Cliclick = "/usr/local/bin/cliclick";

    public static (int x, int y) GetMousePos()
    {
        var r = Run(Cliclick, "p:.");
        var parts = r.stdout.Trim().Split(',');
        if (parts.Length == 2 && int.TryParse(parts[0], out var x) && int.TryParse(parts[1], out var y))
            return (x, y);
        return (0, 0);
    }

    public static void MouseMoveBy(int dx, int dy)
    {
        var (x, y) = GetMousePos();
        var nx = Math.Max(0, x + dx);
        var ny = Math.Max(0, y + dy);
        Run(Cliclick, $"m:{nx},{ny}");
    }

    public static void MouseClick(string button = "left")
    {
        var cmd = button switch { "right" => "rc:.", "double" => "dc:.", _ => "c:." };
        Run(Cliclick, cmd);
    }

    public static void Scroll(int dy)
    {
        // cliclick wheel: positive = down
        Run(Cliclick, $"w:0,{dy}");
    }
}
