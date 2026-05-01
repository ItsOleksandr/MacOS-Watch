using MacControl;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorPages();
builder.WebHost.UseUrls("http://0.0.0.0:5050");

var app = builder.Build();
app.UseStaticFiles();
app.UseRouting();
app.MapRazorPages();

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
