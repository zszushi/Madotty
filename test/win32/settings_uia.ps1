# The companion follows the user's display language. Locate controls by their
# stable automation IDs and use the shipped translations for option labels.
$settingsSource = Join-Path $PSScriptRoot '..\..\src\apprt\winui-settings'
$settingsEnglish = @{}
$settingsLabels = @{}
$englishCatalog = [xml][IO.File]::ReadAllText((Join-Path $settingsSource 'Strings.resx'))
foreach ($entry in $englishCatalog.root.data) {
    $settingsEnglish[[string]$entry.name] = [string]$entry.value
}
foreach ($file in Get-ChildItem -LiteralPath $settingsSource -Filter 'Strings.*.resx') {
    $catalog = [xml][IO.File]::ReadAllText($file.FullName)
    foreach ($entry in $catalog.root.data) {
        $english = $settingsEnglish[[string]$entry.name]
        $translated = [string]$entry.value
        if (!$english -or !$translated) { continue }
        $settingsLabels[$english] = @($settingsLabels[$english] | Where-Object { $_ }) + $translated
    }
}

function Get-SettingsLabels([string]$text, [object[]]$values = @()) {
    foreach ($label in (@($text) + @($settingsLabels[$text]) | Where-Object { $_ } | Select-Object -Unique)) {
        if ($values.Count) { [string]::Format($label, $values) } else { $label }
    }
}

function New-SettingsNameCondition([string]$text, [object[]]$values = @()) {
    $conditions = @(foreach ($label in Get-SettingsLabels $text $values) {
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $label)
    })
    if ($conditions.Count -eq 1) { return $conditions[0] }
    return [System.Windows.Automation.OrCondition]::new([System.Windows.Automation.Condition[]]$conditions)
}

function Find-SettingsWindow([scriptblock]$lookup) {
    foreach ($title in Get-SettingsLabels 'Madotty Settings') {
        $hwnd = & $lookup $title
        if ($hwnd -ne [IntPtr]::Zero) { return $hwnd }
    }
    return [IntPtr]::Zero
}
