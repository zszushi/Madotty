namespace Madotty.Settings;

internal readonly record struct TerminalCapability(bool Registered, string? Package, string? StatusKey)
{
    public bool Available => Registered || Package is not null;

    public static async Task<TerminalCapability> Check(bool supported, Func<Task<bool>> registered,
        Func<Task<string?>> trustedPackage, Func<bool> isDefault)
    {
        if (!supported) return new(false, null, "RequiresWin11");
        try
        {
            if (await registered()) return new(true, null, isDefault() ? "IsDefault" : null);
            string? package = await trustedPackage();
            return new(false, package, package is null ? "NotRegistered" : null);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return new(false, null, "RegistrationCheckFailed");
        }
    }
}
