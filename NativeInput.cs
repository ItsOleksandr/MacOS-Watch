using System.Runtime.InteropServices;

namespace MacControl;

// Native macOS input via CoreGraphics CGEvent. No subprocess, no Accessibility prompt
// per call (the host binary's grant covers all events). Each call posts in ~µs.
internal static class NativeInput
{
    private const string CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";

    [StructLayout(LayoutKind.Sequential)]
    public struct CGPoint { public double X, Y; public CGPoint(double x, double y) { X = x; Y = y; } }

    [StructLayout(LayoutKind.Sequential)]
    public struct CGRect { public double X, Y, Width, Height; }

    [DllImport(CG)] private static extern IntPtr CGEventCreate(IntPtr source);
    [DllImport(CG)] private static extern IntPtr CGEventCreateKeyboardEvent(IntPtr source, ushort virtualKey, bool keyDown);
    [DllImport(CG)] private static extern IntPtr CGEventCreateMouseEvent(IntPtr source, uint mouseType, CGPoint location, uint mouseButton);
    [DllImport(CG)] private static extern IntPtr CGEventCreateScrollWheelEvent(IntPtr source, uint units, uint wheelCount, int wheel1);
    [DllImport(CG)] private static extern void CGEventPost(uint tap, IntPtr evt);
    [DllImport(CG)] private static extern void CGEventSetIntegerValueField(IntPtr evt, uint field, long value);
    [DllImport(CG)] private static extern CGPoint CGEventGetLocation(IntPtr evt);
    [DllImport(CG)] private static extern void CFRelease(IntPtr cf);
    [DllImport(CG)] private static extern int CGWarpMouseCursorPosition(CGPoint pt);
    [DllImport(CG)] private static extern int CGAssociateMouseAndMouseCursorPosition(int connected);
    [DllImport(CG)] private static extern int CGGetActiveDisplayList(uint maxDisplays, [Out] uint[]? activeDisplays, out uint displayCount);
    [DllImport(CG)] private static extern CGRect CGDisplayBounds(uint display);

    // --- Accessibility (TCC) ---------------------------------------------------
    // CGEvent posting silently does nothing until the binary is trusted for
    // Accessibility, which is the single most common "the buttons do nothing"
    // cause. Ask the system directly instead of leaving the user to guess.
    private const string AS = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices";

    // CoreFoundation's Boolean is a single byte; the default bool marshalling is a
    // 4-byte Win32 BOOL and would read three bytes of garbage alongside it.
    [DllImport(AS)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool AXIsProcessTrusted();

    /// <summary>True when this binary may post synthetic input events.</summary>
    // Deliberately the plain check, not AXIsProcessTrustedWithOptions: the prompting
    // variant segfaults this process (it expects a GUI app context, which a LaunchAgent
    // binary is not), taking the whole server down. install.sh opens the Settings pane
    // and reveals the binary in Finder instead.
    public static bool IsTrusted() => AXIsProcessTrusted();

    private const uint kCGHIDEventTap = 0;
    private const uint kCGMouseEventClickState = 1;
    private const uint LeftDown = 1, LeftUp = 2, RightDown = 3, RightUp = 4, MouseMoved = 5;
    private const uint kCGScrollEventUnitLine = 1;

    // macOS virtual key codes (Carbon HIToolbox).
    private static readonly Dictionary<string, ushort> Keys = new(StringComparer.OrdinalIgnoreCase)
    {
        ["return"] = 0x24, ["enter"] = 0x24,
        ["tab"] = 0x30,
        ["space"] = 0x31,
        ["delete"] = 0x33, ["backspace"] = 0x33,
        ["esc"] = 0x35, ["escape"] = 0x35,
        ["arrow-left"] = 0x7B, ["left"] = 0x7B,
        ["arrow-right"] = 0x7C, ["right"] = 0x7C,
        ["arrow-down"] = 0x7D, ["down"] = 0x7D,
        ["arrow-up"] = 0x7E, ["up"] = 0x7E,
        ["home"] = 0x73, ["end"] = 0x77,
        ["page-up"] = 0x74, ["page-down"] = 0x79,
        ["f1"] = 0x7A, ["f2"] = 0x78, ["f3"] = 0x63, ["f4"] = 0x76,
        ["f5"] = 0x60, ["f6"] = 0x61, ["f7"] = 0x62, ["f8"] = 0x64,
        ["f9"] = 0x65, ["f10"] = 0x6D, ["f11"] = 0x67, ["f12"] = 0x6F,
    };

    private static readonly Dictionary<char, ushort> Chars = new()
    {
        ['a']=0, ['s']=1, ['d']=2, ['f']=3, ['h']=4, ['g']=5, ['z']=6, ['x']=7,
        ['c']=8, ['v']=9, ['b']=11, ['q']=12, ['w']=13, ['e']=14, ['r']=15,
        ['y']=16, ['t']=17, ['1']=18, ['2']=19, ['3']=20, ['4']=21, ['6']=22,
        ['5']=23, ['9']=25, ['7']=26, ['8']=28, ['0']=29, ['o']=31, ['u']=32,
        ['i']=34, ['p']=35, ['l']=37, ['j']=38, ['k']=40, ['n']=45, ['m']=46,
    };

    public static bool KeyTap(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return false;
        ushort vk;
        if (name.Length == 1 && Chars.TryGetValue(char.ToLowerInvariant(name[0]), out vk)) { /* ok */ }
        else if (!Keys.TryGetValue(name, out vk)) return false;

        var down = CGEventCreateKeyboardEvent(IntPtr.Zero, vk, true);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
        var up = CGEventCreateKeyboardEvent(IntPtr.Zero, vk, false);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
        return true;
    }

    public static (int x, int y) GetMouse()
    {
        var e = CGEventCreate(IntPtr.Zero);
        var p = CGEventGetLocation(e);
        CFRelease(e);
        return ((int)p.X, (int)p.Y);
    }

    // --- Display geometry ------------------------------------------------------
    // The global coordinate space has the main display's top-left at (0,0); a
    // display arranged to its left or above therefore has NEGATIVE coordinates.
    // Clamping the target to 0 would have made those displays unreachable, so the
    // cursor is instead kept inside the real union of the active displays.
    private static CGRect[] _displays = Array.Empty<CGRect>();
    private static DateTime _displaysAt = DateTime.MinValue;

    // Re-read periodically rather than per move: a drag posts moves at ~30Hz, while
    // displays are plugged in on a human timescale — a second of staleness at worst.
    private static CGRect[] Displays()
    {
        if (DateTime.UtcNow - _displaysAt < TimeSpan.FromSeconds(1)) return _displays;

        var list = new CGRect[0];
        if (CGGetActiveDisplayList(0, null, out var count) == 0 && count > 0)
        {
            var ids = new uint[count];
            if (CGGetActiveDisplayList(count, ids, out count) == 0)
            {
                list = new CGRect[count];
                for (var i = 0; i < count; i++) list[i] = CGDisplayBounds(ids[i]);
            }
        }
        _displays = list;
        _displaysAt = DateTime.UtcNow;
        return _displays;
    }

    /// <summary>
    /// Keeps a target point on some display. A point already on one is returned as
    /// is; otherwise it snaps to the nearest display, which is what lets the cursor
    /// cross into a screen that is offset diagonally or only partially adjacent.
    /// </summary>
    private static CGPoint ClampToDisplays(double x, double y)
    {
        var displays = Displays();
        if (displays.Length == 0) return new CGPoint(x, y); // no info: do not fight the OS

        var best = new CGPoint(x, y);
        var bestDist = double.MaxValue;
        foreach (var b in displays)
        {
            // Right/bottom edges are exclusive, hence the 1px inset.
            var cx = Math.Clamp(x, b.X, b.X + b.Width - 1);
            var cy = Math.Clamp(y, b.Y, b.Y + b.Height - 1);
            if (cx == x && cy == y) return new CGPoint(x, y);

            var dist = (cx - x) * (cx - x) + (cy - y) * (cy - y);
            if (dist < bestDist) { bestDist = dist; best = new CGPoint(cx, cy); }
        }
        return best;
    }

    public static void MoveBy(int dx, int dy)
    {
        var (x, y) = GetMouse();
        var pt = ClampToDisplays(x + dx, y + dy);
        // Warp positions the cursor; then post a moved event so apps under the cursor see it.
        CGAssociateMouseAndMouseCursorPosition(1);
        CGWarpMouseCursorPosition(pt);
        var e = CGEventCreateMouseEvent(IntPtr.Zero, MouseMoved, pt, 0);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }

    public static void Click(string button)
    {
        var (x, y) = GetMouse();
        var pt = new CGPoint(x, y);
        switch (button)
        {
            case "right":
                Post(RightDown, pt, 1, 1);
                Post(RightUp, pt, 1, 1);
                break;
            case "double":
                Post(LeftDown, pt, 0, 1);
                Post(LeftUp, pt, 0, 1);
                Post(LeftDown, pt, 0, 2);
                Post(LeftUp, pt, 0, 2);
                break;
            default:
                Post(LeftDown, pt, 0, 1);
                Post(LeftUp, pt, 0, 1);
                break;
        }
    }

    private static void Post(uint type, CGPoint pt, uint button, long clickState)
    {
        var e = CGEventCreateMouseEvent(IntPtr.Zero, type, pt, button);
        CGEventSetIntegerValueField(e, kCGMouseEventClickState, clickState);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }

    public static void Scroll(int dy)
    {
        // CG scroll: positive = up. UI sends positive = down, so negate.
        var e = CGEventCreateScrollWheelEvent(IntPtr.Zero, kCGScrollEventUnitLine, 1, -dy);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
}
