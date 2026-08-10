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
/// </summary>
public static class TokenStore
{
    public static string Resolve(string contentRoot, ILogger logger)
    {
        var fromEnv = Environment.GetEnvironmentVariable("MACCONTROL_TOKEN");
        if (!string.IsNullOrWhiteSpace(fromEnv))
            return fromEnv.Trim();

        var path = Path.Combine(contentRoot, "token");
        if (File.Exists(path))
        {
            var existing = File.ReadAllText(path).Trim();
            if (!string.IsNullOrWhiteSpace(existing))
                return existing;
        }

        var generated = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        try
        {
            File.WriteAllText(path, generated);
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
