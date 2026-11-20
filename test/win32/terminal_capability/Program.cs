using Madotty.Settings;

static Task<bool> Yes() => Task.FromResult(true);
static Task<bool> No() => Task.FromResult(false);
static Task<string?> Bundle() => Task.FromResult<string?>("trusted.msix");
static Task<string?> Missing() => Task.FromResult<string?>(null);
const string failed = "RegistrationCheckFailed";
const string probe = "simulated check failure";
await Check("old Windows", false, Yes, Bundle, () => true, new(false, null, "RequiresWin11"));
await Check("unsigned MSI, no registration", true, No, Missing, () => false, new(false, null, "NotRegistered"));
await Check("trusted bundle", true, No, Bundle, () => false, new(false, "trusted.msix", null));
await Check("registered, bundle unnecessary", true, Yes, () => throw new Exception(probe), () => false, new(true, null, null));
await Check("already default", true, Yes, Missing, () => true, new(true, null, "IsDefault"));
await Check("catalog unavailable", true, () => throw new Exception(probe), Bundle, () => true, new(false, null, failed));
await Check("package check failed", true, No, () => throw new Exception(probe), () => false, new(false, null, failed));
await Check("default check failed", true, Yes, Bundle, () => throw new Exception(probe), new(false, null, failed));

static async Task Check(string name, bool supported, Func<Task<bool>> registered,
    Func<Task<string?>> bundle, Func<bool> isDefault, TerminalCapability expected)
{
    var actual = await TerminalCapability.Check(supported, registered, bundle, isDefault);
    if (actual != expected || actual.Available != (expected.Registered || expected.Package is not null))
        throw new InvalidOperationException($"{name}: expected {expected}, got {actual}");
    Console.WriteLine($"PASS {name}");
}
