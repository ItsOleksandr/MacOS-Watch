using System.Security.Cryptography;
using System.Text;

namespace MacControl;

/// <summary>
/// Resolves the shared control token and compares candidates in constant time.
///
/// Precedence:
///   1. MACCONTROL_TOKEN environment variable, if set.
///   2. A `token` file in the content root, if it exists.
///   3. A freshly generated random token, persisted to that `token` file.
///
/// This makes the server secure by default: with no configuration at all it
/// still requires a secret, which it prints to the log on first start. Anyone
/// on the LAN who does not know the token gets 401 and cannot control the Mac.
///
/// Steps 1 and 2 are also how a chosen password gets in: write it to the `token`
/// file (`./scripts/set-password.sh`) and it is used verbatim instead of a
/// random one. A self-chosen secret is guessable in a way a random one is not,
/// so a short one is accepted but warned about rather than silently trusted.
/// </summary>
public static class TokenStore
{
    /// <summary>Below this, a chosen password is weak enough to be worth a log warning.</summary>
    private const int MinReasonableLength = 8;

    public static string Resolve(string contentRoot, ILogger logger)
    {
        var fromEnv = Environment.GetEnvironmentVariable("MACCONTROL_TOKEN");
        if (!string.IsNullOrWhiteSpace(fromEnv))
        {
            var token = fromEnv.Trim();
            logger.LogInformation("Using the control token from MACCONTROL_TOKEN.");
            WarnIfWeak(token, logger);
            return token;
        }

        var path = Path.Combine(contentRoot, "token");
        if (File.Exists(path))
        {
            // Trim: an editor or `echo` leaves a trailing newline, and a token
            // that differs from what the user typed by an invisible character
            // is the most confusing possible 401.
            var existing = File.ReadAllText(path).Trim();
            if (!string.IsNullOrWhiteSpace(existing))
            {
                logger.LogInformation("Using the control token from {Path}.", path);
                WarnIfWeak(existing, logger);
                return existing;
            }
        }

        var generated = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        try
        {
            File.WriteAllText(path, generated);
            // Owner-only: the file sits next to the binary in ~/Applications.
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch (Exception e)
        {
            logger.LogWarning("Could not persist control token to {Path}: {Message}", path, e.Message);
        }

        logger.LogWarning(
            "Generated a new control token: {Token}\n" +
            "         Open the UI at:  http://<mac-ip>:5050/?token={Token}",
            generated, generated);
        return generated;
    }

    /// <summary>
    /// A random 32-hex-character token is unguessable; a hand-picked one may not
    /// be, and this server hands whoever guesses it the mouse and keyboard.
    /// Warn, but do not refuse — on a home LAN a short password is the user's
    /// call to make, and refusing to start would lock them out of their own Mac.
    /// </summary>
    private static void WarnIfWeak(string token, ILogger logger)
    {
        if (token.Length < MinReasonableLength)
            logger.LogWarning(
                "The control password is only {Length} characters. Anyone on this network " +
                "who guesses it can move the mouse and type on this Mac — use at least {Min}.",
                token.Length, MinReasonableLength);
    }

    /// <summary>Constant-time comparison so the token is not leaked by timing.</summary>
    public static bool Matches(string? candidate, string token)
    {
        if (string.IsNullOrEmpty(candidate))
            return false;

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(candidate),
            Encoding.UTF8.GetBytes(token));
    }
}
