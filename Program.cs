using MacControl;
using Microsoft.AspNetCore.StaticFiles;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

var builder = WebApplication.CreateBuilder(args);

// Bind to every interface so a phone on the same Wi-Fi can reach the server.
// Without this the ASP.NET default is http://localhost:5000 — reachable only
// from the Mac itself. ASPNETCORE_URLS / --urls still win when they are set.
if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")) &&
    string.IsNullOrWhiteSpace(builder.Configuration["urls"]))
{
    builder.WebHost.UseUrls("http://0.0.0.0:5050");
}

builder.Services.AddRazorPages();

var app = builder.Build();

// Every control action requires a shared secret token. Without it, anyone on the
// same Wi-Fi could move the mouse and type on this Mac. See TokenStore for how the
// token is resolved (env var → token file → generated-and-persisted).
var controlToken = TokenStore.Resolve(app.Environment.ContentRootPath, app.Logger);

// The built-in content-type map does not always know .webmanifest; without the
// right type some browsers ignore the manifest and the home-screen shortcut
// falls back to a screenshot instead of the app icon.
var contentTypes = new FileExtensionContentTypeProvider();
contentTypes.Mappings[".webmanifest"] = "application/manifest+json";
app.UseStaticFiles(new StaticFileOptions { ContentTypeProvider = contentTypes });

app.UseRouting();

// Log the first request seen from each non-loopback client. "The phone can't
// connect" is otherwise pure guesswork: this turns it into a fact — if the phone's
// IP never appears here, its packets are not reaching the Mac at all (wrong Wi-Fi,
// AP/client isolation, VPN), and the problem is not this server. Only the first
// request per address is logged, so a 30Hz trackpad drag cannot flood the log.
// The Host header is logged alongside the address because it records which name
// the device actually resolved: "macbook-air.local:5050" proves mDNS worked on
// that phone, an IP proves it did not have to. Keying on both means a visit by
// name and a visit by IP are each reported once.
var seenClients = new System.Collections.Concurrent.ConcurrentDictionary<string, DateTime>();
app.Use(async (context, next) =>
{
    var ip = context.Connection.RemoteIpAddress;
    if (ip is not null && !System.Net.IPAddress.IsLoopback(ip))
    {
        var host = context.Request.Host.Value ?? "?";
        if (seenClients.TryAdd($"{ip}|{host}", DateTime.Now))
            app.Logger.LogInformation("New client connected: {Client} via {Host}", ip.ToString(), host);
    }
    await next();
});

// Gate only the /api/* surface: the Razor page itself must load unauthenticated
// so it can read the token from the URL and send it as a header from then on.
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/api"))
    {
        var provided = context.Request.Headers["X-MacControl-Token"].FirstOrDefault()
                       ?? context.Request.Query["token"].FirstOrDefault();
        if (!TokenStore.Matches(provided, controlToken))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsync("invalid or missing control token");
            return;
        }
    }
    await next();
});

app.MapRazorPages();

// Ask once at startup. This both reports the state and, when untrusted, makes
// macOS register the binary in the Accessibility list so the user only has to
// toggle it on — otherwise they must add a bare Unix executable by hand.
if (NativeInput.IsTrusted())
{
    app.Logger.LogInformation("Accessibility: granted — mouse and keyboard control is active.");
}
else
{
    app.Logger.LogWarning(
        "Accessibility: NOT granted. Volume works, but mouse and keyboard do nothing.\n" +
        "         Enable MacControl in System Settings > Privacy & Security > Accessibility.");
}

// Lets the UI and status.sh state plainly whether input control can work,
// instead of every button silently doing nothing.
app.MapGet("/api/accessibility", () => Results.Json(new { trusted = NativeInput.IsTrusted() }));

// The address a phone should use. The page cannot derive this from its own URL:
// opened on the Mac as localhost:5050 it would build a QR pointing at localhost,
// which is useless on the phone. Interfaces with a default gateway come first, so
// the active Wi-Fi wins over virtual adapters.
app.MapGet("/api/lan-address", () =>
{
    var candidates =
        from nic in NetworkInterface.GetAllNetworkInterfaces()
        where nic.OperationalStatus == OperationalStatus.Up
              && nic.NetworkInterfaceType != NetworkInterfaceType.Loopback
        let props = nic.GetIPProperties()
        let hasGateway = props.GatewayAddresses.Any(g => g.Address is { } a && !a.Equals(IPAddress.Any))
        from ua in props.UnicastAddresses
        where ua.Address.AddressFamily == AddressFamily.InterNetwork
              && !IPAddress.IsLoopback(ua.Address)
              && !ua.Address.ToString().StartsWith("169.254.") // self-assigned, never routable
        orderby hasGateway descending
        select ua.Address.ToString();

    return Results.Json(new { address = candidates.FirstOrDefault() });
});

app.MapGet("/api/volume", () => Results.Json(new { volume = SystemControl.GetVolume(), muted = SystemControl.GetMuted() }));
app.MapPost("/api/volume/{v:int}", (int v) => { SystemControl.SetVolume(v); return Results.Ok(); });
app.MapPost("/api/mute/{m:bool}", (bool m) => { SystemControl.SetMuted(m); return Results.Ok(); });

app.MapPost("/api/playpause", () => { SystemControl.PlayPause(); return Results.Ok(); });
app.MapPost("/api/key/{name}", (string name) => { SystemControl.Key(name); return Results.Ok(); });

app.MapPost("/api/mouse/move", (MouseDelta d) => { SystemControl.MouseMoveBy(d.dx, d.dy); return Results.Ok(); });
app.MapPost("/api/mouse/click/{button}", (string button) => { SystemControl.MouseClick(button); return Results.Ok(); });
app.MapPost("/api/mouse/scroll/{dy:int}", (int dy) => { SystemControl.Scroll(dy); return Results.Ok(); });

app.Run();

record MouseDelta(int dx, int dy);
