[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Scope='Function', Target='*')]
[CmdletBinding()]
param(
    [string]$InitialModRoot,
    [switch]$SelfTest
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Restart-InStaIfNeeded {
    if ($SelfTest) {
        return
    }

    if ([System.Threading.Thread]::CurrentThread.ApartmentState -eq [System.Threading.ApartmentState]::STA) {
        return
    }

    if (-not $PSCommandPath) {
        throw 'KenshiPromptExplorer must run in STA mode. Re-run it with pwsh -STA -File KenshiPromptExplorer.ps1.'
    }

    $procPath = [System.Diagnostics.Process]::GetCurrentProcess().Path
    $launchArgs = [System.Collections.Generic.List[string]]::new()
    $launchArgs.Add('-NoProfile')
    $launchArgs.Add('-STA')
    $launchArgs.Add('-File')
    $launchArgs.Add($PSCommandPath)
    if ($InitialModRoot) {
        $launchArgs.Add('-InitialModRoot')
        $launchArgs.Add($InitialModRoot)
    }

    Start-Process -FilePath $procPath -ArgumentList $launchArgs
    exit
}

Restart-InStaIfNeeded

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function New-Utf8Encoding {
    param([bool]$EmitBom = $false)
    return [System.Text.UTF8Encoding]::new($EmitBom)
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-IsChildPath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    $root = (Get-NormalizedPath -Path $RootPath).TrimEnd('\') + '\'
    $candidate = Get-NormalizedPath -Path $CandidatePath
    return $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    if (-not (Test-IsChildPath -RootPath $RootPath -CandidatePath $CandidatePath)) {
        throw "Refusing to access path outside selected mod root: $CandidatePath"
    }
}

function Resolve-ModRoot {
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-NormalizedPath -Path $Path
    if (Test-Path -LiteralPath (Join-Path $full 'Kayak\KayakDB') -PathType Container) {
        return $full
    }

    $directChild = Join-Path $full 'SentientSands'
    if (Test-Path -LiteralPath (Join-Path $directChild 'Kayak\KayakDB') -PathType Container) {
        return (Get-NormalizedPath -Path $directChild)
    }

    $childMatch = Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Kayak\KayakDB') -PathType Container } |
        Select-Object -First 1

    if ($childMatch) {
        return $childMatch.FullName
    }

    return $full
}

function Test-ModRoot {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-ModRoot -Path $Path
    $required = @(
        'Kayak\KayakDB',
        'server\config\models.json',
        'server\config\providers.json'
    )

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolved $item))) {
            $missing.Add($item)
        }
    }

    [pscustomobject]@{
        IsValid   = ($missing.Count -eq 0)
        ModRoot   = $resolved
        Missing   = @($missing)
        ErrorText = if ($missing.Count -eq 0) { '' } else { 'Missing required paths: ' + ($missing -join ', ') }
    }
}

function Read-TextFileDetailed {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = New-Utf8Encoding -EmitBom:$hasUtf8Bom
    $offset = if ($hasUtf8Bom) { 3 } else { 0 }
    $count = [Math]::Max(0, $bytes.Length - $offset)
    $content = $encoding.GetString($bytes, $offset, $count)

    $newline = if ($content -match "`r`n") {
        "`r`n"
    }
    elseif ($content -match "`n") {
        "`n"
    }
    else {
        [Environment]::NewLine
    }

    [pscustomobject]@{
        Content    = $content
        NewLine    = $newline
        Encoding   = $encoding
        HasUtf8Bom = $hasUtf8Bom
    }
}

function Write-TextFileDetailed {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$FileProfile
    )

    $newline = if ($FileProfile.NewLine) { $FileProfile.NewLine } else { [Environment]::NewLine }
    $encoding = if ($FileProfile.Encoding) { $FileProfile.Encoding } else { New-Utf8Encoding }
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($Content, "`r`n|`n|`r", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newline })
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Get-SectionValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $currentSection = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -match '^\[(.+?)\]\s*$') {
            $currentSection = $matches[1]
            continue
        }
        if (-not $currentSection.Equals($Section, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($trimmed -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $currentKey = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($currentKey.Equals($Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $value
            }
        }
    }

    return $null
}

function Get-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $raw = [System.IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) {
        return @{}
    }

    return ($raw | ConvertFrom-Json -AsHashtable)
}

function Get-ModContext {
    param([Parameter(Mandatory)][string]$ModRoot)

    $validation = Test-ModRoot -Path $ModRoot
    if (-not $validation.IsValid) {
        throw $validation.ErrorText
    }

    $root = $validation.ModRoot
    $kayakDbRoot = Join-Path $root 'Kayak\KayakDB'
    $campaignsRoot = Join-Path $kayakDbRoot 'Campaigns'
    $templateRoot = Join-Path $kayakDbRoot 'Template'
    $modelsPath = Join-Path $root 'server\config\models.json'
    $providersPath = Join-Path $root 'server\config\providers.json'
    $configMasterPath = Join-Path $root 'config_master.txt'
    $legacyIniPath = Join-Path $root 'SentientSands_Config.ini'

    $activeModel = Get-SectionValue -Path $configMasterPath -Section 'SentientSands' -Key 'CurrentModel'
    if (-not $activeModel) {
        $activeModel = Get-SectionValue -Path $legacyIniPath -Section 'Settings' -Key 'CurrentModel'
    }

    $activeCampaign = Get-SectionValue -Path $configMasterPath -Section 'SentientSands' -Key 'ActiveCampaign'
    if (-not $activeCampaign) {
        $activeCampaign = Get-SectionValue -Path $legacyIniPath -Section 'Settings' -Key 'ActiveCampaign'
    }

    $campaigns = @(Get-ChildItem -LiteralPath $campaignsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Path = $_.FullName
            }
        })

    if (-not $activeCampaign -and $campaigns.Count -gt 0) {
        $activeCampaign = $campaigns[0].Name
    }

    $models = Get-JsonHashtable -Path $modelsPath
    $providers = Get-JsonHashtable -Path $providersPath

    [pscustomobject]@{
        ModRoot        = $root
        KayakDbRoot    = $kayakDbRoot
        CampaignsRoot  = $campaignsRoot
        TemplateRoot   = $templateRoot
        ModelsPath     = $modelsPath
        ProvidersPath  = $providersPath
        ConfigMaster   = $configMasterPath
        LegacyIni      = $legacyIniPath
        Campaigns      = $campaigns
        ActiveCampaign = $activeCampaign
        ActiveModel    = $activeModel
        Models         = $models
        Providers      = $providers
    }
}

function Get-TemplateWorkspaceName {
    return '[Template]'
}

function Test-IsTemplateWorkspace {
    param([string]$Campaign)
    return $Campaign -eq (Get-TemplateWorkspaceName)
}

function Normalize-FieldKey {
    param([Parameter(Mandatory)][string]$FieldName)
    return $FieldName.Trim().TrimStart('$').ToLowerInvariant().Replace(' ', '_')
}

function Parse-EntityKvLine {
    param([Parameter(Mandatory)][string]$Line)

    $pattern = '^\s*([^:=\->\[\r\n]+?)\s*(?:->|:=|:(?!=)|=(?!=))\s*(.*)$'
    $match = [System.Text.RegularExpressions.Regex]::Match($Line, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $key = $match.Groups[1].Value.Trim()
    $value = $match.Groups[2].Value.Trim()
    if ($value.Length -ge 2) {
        $first = $value[0]
        $last = $value[$value.Length - 1]
        if (($first -eq '"' -or $first -eq "'") -and $first -eq $last) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    [pscustomobject]@{
        Key        = $key
        Value      = $value
        Normalized = (Normalize-FieldKey -FieldName $key)
        IsProse    = $key.Trim().StartsWith('$')
    }
}

function Parse-EntityDocument {
    param([Parameter(Mandatory)][string]$Content)

    $lines = $Content -split "`r`n|`n|`r", 0
    $header = [ordered]@{}
    $fields = [ordered]@{}
    $meta = @{}
    $layoutOrder = [System.Collections.Generic.List[string]]::new()
    $freeLines = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $reserved = @('Category', 'Name', 'Id')
    $index = 0

    foreach ($expected in $reserved) {
        while ($index -lt $lines.Count -and -not $lines[$index].Trim()) {
            $index++
        }

        if ($index -ge $lines.Count) {
            $warnings.Add("Missing reserved header line: $expected")
            continue
        }

        $parsed = Parse-EntityKvLine -Line $lines[$index]
        if ($parsed -and $parsed.Key.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            $header[$expected] = $parsed.Value
        }
        else {
            $warnings.Add("Expected reserved header line: $expected")
        }
        $index++
    }

    for (; $index -lt $lines.Count; $index++) {
        $raw = $lines[$index]
        $trimmed = $raw.Trim()
        if (-not $trimmed) {
            continue
        }
        if ($trimmed -match '^\[.+\]$') {
            continue
        }
        if ($trimmed -match '^&>\s*(.+)$') {
            continue
        }

        $parsed = Parse-EntityKvLine -Line $trimmed
        if ($parsed -and $reserved -notcontains $parsed.Key) {
            $normalized = $parsed.Normalized
            if (-not $fields.Contains($normalized)) {
                $fields[$normalized] = $parsed.Value
                $meta[$normalized] = [pscustomobject]@{
                    OriginalKey = $parsed.Key.TrimStart('$')
                    IsProse     = $parsed.IsProse
                }
                $layoutOrder.Add($normalized)
            }
        }
        else {
            $freeLines.Add($trimmed)
        }
    }

    $requiredHeadersPresent = $header.Contains('Category') -and $header.Contains('Name') -and $header.Contains('Id')
    $canRoundTripStructured = $requiredHeadersPresent -and ($freeLines.Count -eq 0)

    [pscustomobject]@{
        Header                 = $header
        Fields                 = $fields
        FieldMeta              = $meta
        LayoutOrder            = @($layoutOrder)
        FreeLines              = @($freeLines)
        Warnings               = @($warnings)
        CanRoundTripStructured = $canRoundTripStructured
    }
}

function Get-EntityGroupName {
    param(
        [Parameter(Mandatory)][string]$FieldName,
        $Document
    )

    $key = Normalize-FieldKey -FieldName $FieldName
    if ($key -in @('persistent_id', 'runtime_id')) { return 'ids' }

    $isProse = $false
    if ($Document -and $Document.FieldMeta -and $Document.FieldMeta.ContainsKey($key)) {
        $isProse = [bool]$Document.FieldMeta[$key].IsProse
    }
    elseif ($key -in @('knows_about', 'loyalty', 'religion', 'outlook', 'motivation', 'personality', 'backstory', 'speech_quirks')) {
        $isProse = $true
    }

    if (-not $isProse) { return 'structural' }
    if ($key -in @('knows_about', 'loyalty', 'religion', 'outlook', 'motivation')) { return 'knowledge' }
    if ($key -in @('personality', 'backstory', 'speech_quirks')) { return 'prose' }
    return 'custom'
}

function Get-FieldPriority {
    param(
        [Parameter(Mandatory)][string]$FieldName,
        $Document
    )

    $priority = @{
        persistent_id  = 100
        runtime_id     = 110
        display_name   = 200
        original_name  = 210
        race           = 220
        sex            = 230
        faction        = 240
        origin_faction = 250
        location       = 260
        role           = 270
        job            = 280
        weight         = 290
        relation       = 300
        price_modifier = 310
        knows_about    = 400
        loyalty        = 500
        religion       = 510
        outlook        = 520
        motivation     = 530
        personality    = 600
        backstory      = 610
        speech_quirks  = 620
    }

    $normalized = Normalize-FieldKey -FieldName $FieldName
    if ($priority.ContainsKey($normalized)) {
        return $priority[$normalized]
    }

    switch (Get-EntityGroupName -FieldName $normalized -Document $Document) {
        'structural' { return 350 }
        'knowledge' { return 500 }
        'prose' { return 600 }
        'custom' { return 800 }
        default { return 1000 }
    }
}

function Get-SortedEntityFieldNames {
    param([Parameter(Mandatory)]$Document)

    $layoutLookup = @{}
    for ($i = 0; $i -lt $Document.LayoutOrder.Count; $i++) {
        $layoutLookup[$Document.LayoutOrder[$i]] = $i
    }

    return @($Document.Fields.Keys | Sort-Object `
            @{ Expression = { Get-FieldPriority -FieldName $_ -Document $Document } }, `
            @{ Expression = { if ($layoutLookup.ContainsKey($_)) { $layoutLookup[$_] } else { 9999 } } }, `
            @{ Expression = { $_ } })
}

function Render-EntityDocument {
    param([Parameter(Mandatory)]$Document)

    $lines = [System.Collections.Generic.List[string]]::new()
    $category = if ($Document.Header.Contains('Category')) { $Document.Header['Category'] } else { '' }
    $name = if ($Document.Header.Contains('Name')) { $Document.Header['Name'] } else { '' }
    $id = if ($Document.Header.Contains('Id')) { $Document.Header['Id'] } else { '' }

    $lines.Add("Category = $category")
    $lines.Add("Name = $name")
    $lines.Add("Id = $id")
    $lines.Add('')

    $sortedKeys = Get-SortedEntityFieldNames -Document $Document
    $previousGroup = ''

    foreach ($key in $sortedKeys) {
        $value = [string]$Document.Fields[$key]
        $group = Get-EntityGroupName -FieldName $key -Document $Document
        if ($previousGroup -and $group -ne $previousGroup) {
            $lines.Add('')
        }

        $meta = if ($Document.FieldMeta.ContainsKey($key)) { $Document.FieldMeta[$key] } else { $null }
        $isProse = if ($meta) { [bool]$meta.IsProse } else { $group -in @('knowledge', 'prose', 'custom') }
        $outputName = if ($meta -and $meta.OriginalKey) { $meta.OriginalKey } else { $key }
        $prefix = if ($isProse) { '$' } else { '' }
        $lines.Add(($prefix + $outputName + ' = ' + $value.Trim()))
        $previousGroup = $group
    }

    return ($lines -join "`n").TrimEnd()
}

function New-EntityDocumentFromTemplate {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$EntryId,
        $TemplateDocument
    )

    $fields = [ordered]@{}
    $meta = @{}
    $layoutOrder = [System.Collections.Generic.List[string]]::new()

    if ($TemplateDocument -and $TemplateDocument.CanRoundTripStructured) {
        foreach ($key in $TemplateDocument.LayoutOrder) {
            if (-not $fields.Contains($key)) {
                $fields[$key] = ''
                if ($TemplateDocument.FieldMeta.ContainsKey($key)) {
                    $meta[$key] = $TemplateDocument.FieldMeta[$key]
                }
                else {
                    $meta[$key] = [pscustomobject]@{
                        OriginalKey = $key
                        IsProse     = $false
                    }
                }
                $layoutOrder.Add($key)
            }
        }
    }
    else {
        foreach ($key in @('display_name', 'faction', 'race', 'location', 'role', 'weight', 'knows_about', 'personality', 'backstory', 'speech_quirks')) {
            $fields[$key] = ''
            $meta[$key] = [pscustomobject]@{
                OriginalKey = $key
                IsProse     = ($key -in @('knows_about', 'personality', 'backstory', 'speech_quirks'))
            }
            $layoutOrder.Add($key)
        }
    }

    if (-not $fields.Contains('display_name')) {
        $fields['display_name'] = ''
        $meta['display_name'] = [pscustomobject]@{ OriginalKey = 'display_name'; IsProse = $false }
        $layoutOrder.Insert(0, 'display_name')
    }

    $fields['display_name'] = $DisplayName

    [pscustomobject]@{
        Header                 = [ordered]@{ Category = $Category; Name = $FolderName; Id = $EntryId }
        Fields                 = $fields
        FieldMeta              = $meta
        LayoutOrder            = @($layoutOrder)
        FreeLines              = @()
        Warnings               = @()
        CanRoundTripStructured = $true
    }
}

function Get-EntityDocumentsFromRoot {
    param([string]$RootPath)

    $documents = [System.Collections.Generic.List[object]]::new()
    if (-not $RootPath -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return @($documents)
    }

    foreach ($dir in @(Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $entityPath = Join-Path $dir.FullName 'entity.txt'
        if (-not (Test-Path -LiteralPath $entityPath -PathType Leaf)) {
            continue
        }

        $document = Parse-EntityDocument -Content ([System.IO.File]::ReadAllText($entityPath))
        if ($document -and $document.CanRoundTripStructured) {
            $documents.Add($document)
        }
    }

    return @($documents)
}


function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Text)

    $slug = [System.Text.RegularExpressions.Regex]::Replace($Text.Trim(), '[^\w\-]+', '_')
    $slug = $slug.Trim('_')
    if (-not $slug) {
        $slug = 'new_entry'
    }
    return $slug
}

function Get-ModeRootPath {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Campaign,
        [Parameter(Mandatory)][string]$Mode
    )

    if (Test-IsTemplateWorkspace -Campaign $Campaign) {
        return (Get-TemplateModeRootPath -Context $Context -Mode $Mode)
    }

    $campaignRoot = Join-Path $Context.CampaignsRoot $Campaign
    if ($Mode -eq 'Gameplay Prompts') {
        return (Join-Path $campaignRoot 'mandatory')
    }

    return (Join-Path $campaignRoot 'categories')
}

function Get-TemplateModeRootPath {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Mode
    )

    if ($Mode -eq 'Gameplay Prompts') {
        Join-Path $Context.TemplateRoot 'mandatory'
    }
    else {
        Join-Path $Context.TemplateRoot 'categories'
    }
}

function Test-SearchMatch {
    param(
        [string]$Search,
        [string]$Text
    )

    if (-not $Search) {
        return $true
    }

    return $Text.IndexOf($Search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function New-TreeItem {
    param(
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)]$NodeData,
        [switch]$Expand
    )

    $item = [System.Windows.Controls.TreeViewItem]::new()
    $item.Header = $Header
    $item.Tag = $NodeData
    $item.IsExpanded = [bool]$Expand
    return $item
}

function Add-MandatoryTreeChildren {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$TargetCollection,
        [string]$Search
    )

    $directories = @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($dir in $directories) {
        $tempItem = New-TreeItem -Header $dir.Name -NodeData ([pscustomobject]@{
                Kind         = 'Folder'
                DisplayName  = $dir.Name
                Path         = $dir.FullName
                RelativePath = $dir.FullName.Substring($BasePath.Length).TrimStart('\')
            })

        Add-MandatoryTreeChildren -RootPath $dir.FullName -BasePath $BasePath -TargetCollection $tempItem.Items -Search $Search

        $folderMatches = (Test-SearchMatch -Search $Search -Text $dir.Name) -or (Test-SearchMatch -Search $Search -Text $tempItem.Tag.RelativePath)
        if ($tempItem.Items.Count -gt 0 -or $folderMatches -or -not $Search) {
            $TargetCollection.Add($tempItem) | Out-Null
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $relativePath = $file.FullName.Substring($BasePath.Length).TrimStart('\')
        if (-not (Test-SearchMatch -Search $Search -Text $relativePath) -and -not (Test-SearchMatch -Search $Search -Text $file.Name)) {
            continue
        }

        $child = New-TreeItem -Header $file.Name -NodeData ([pscustomobject]@{
                Kind         = 'MandatoryFile'
                DisplayName  = $file.Name
                Path         = $file.FullName
                RelativePath = $relativePath
            })
        $TargetCollection.Add($child) | Out-Null
    }
}

function Add-ContentTreeChildren {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)]$TargetCollection,
        [string]$Search
    )

    $directories = @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($dir in $directories) {
        $entityPath = Join-Path $dir.FullName 'entity.txt'
        if (Test-Path -LiteralPath $entityPath -PathType Leaf) {
            $relativePath = $entityPath.Substring($BasePath.Length).TrimStart('\')
            $leafName = $dir.Name
            if (-not (Test-SearchMatch -Search $Search -Text $leafName) -and -not (Test-SearchMatch -Search $Search -Text $relativePath)) {
                continue
            }

            $leaf = New-TreeItem -Header $leafName -NodeData ([pscustomobject]@{
                    Kind         = 'EntityFile'
                    DisplayName  = $leafName
                    Path         = $entityPath
                    RelativePath = $relativePath
                    CategoryName = ($relativePath -split '\\')[0]
                    FolderPath   = $dir.FullName
                })
            $TargetCollection.Add($leaf) | Out-Null
            continue
        }

        $item = New-TreeItem -Header $dir.Name -NodeData ([pscustomobject]@{
                Kind         = 'Folder'
                DisplayName  = $dir.Name
                Path         = $dir.FullName
                RelativePath = $dir.FullName.Substring($BasePath.Length).TrimStart('\')
            })

        Add-ContentTreeChildren -RootPath $dir.FullName -BasePath $BasePath -TargetCollection $item.Items -Search $Search
        $folderMatches = (Test-SearchMatch -Search $Search -Text $dir.Name) -or (Test-SearchMatch -Search $Search -Text $item.Tag.RelativePath)
        if ($item.Items.Count -gt 0 -or $folderMatches -or -not $Search) {
            $TargetCollection.Add($item) | Out-Null
        }
    }
}

function Get-TreeNodeRelativePath {
    param($Item)

    if (-not $Item) {
        return ''
    }

    $tag = if ($Item.PSObject.Properties['Tag']) { $Item.Tag } else { $Item }
    if ($tag -and $tag.PSObject.Properties['RelativePath'] -and $tag.RelativePath) {
        return [string]$tag.RelativePath
    }

    return ''
}

function Get-ExpandedTreeNodeKeys {
    $keys = [System.Collections.Generic.List[string]]::new()

    function Add-ExpandedKeysFromItems {
        param($Items, $ExpandedKeys)

        foreach ($item in @($Items)) {
            if ($item -isnot [System.Windows.Controls.TreeViewItem]) {
                continue
            }

            $key = Get-TreeNodeRelativePath -Item $item
            if ($item.IsExpanded -and $key) {
                $ExpandedKeys.Add($key) | Out-Null
            }

            if ($item.Items.Count -gt 0) {
                Add-ExpandedKeysFromItems -Items $item.Items -ExpandedKeys $ExpandedKeys
            }
        }
    }

    Add-ExpandedKeysFromItems -Items $Controls.PromptTree.Items -ExpandedKeys $keys
    return @($keys)
}

function Find-TreeViewItemByRelativePath {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$RelativePath
    )

    foreach ($item in @($Items)) {
        if ($item -isnot [System.Windows.Controls.TreeViewItem]) {
            continue
        }

        if ((Get-TreeNodeRelativePath -Item $item).Equals($RelativePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $item
        }

        $match = Find-TreeViewItemByRelativePath -Items $item.Items -RelativePath $RelativePath
        if ($match) {
            return $match
        }
    }

    return $null
}

function Expand-TreeViewToRelativePath {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$RelativePath
    )

    foreach ($item in @($Items)) {
        if ($item -isnot [System.Windows.Controls.TreeViewItem]) {
            continue
        }

        $itemPath = Get-TreeNodeRelativePath -Item $item
        if ($itemPath -and $itemPath.Equals($RelativePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($item.Items.Count -gt 0) {
            $found = Expand-TreeViewToRelativePath -Items $item.Items -RelativePath $RelativePath
            if ($found) {
                $item.IsExpanded = $true
                return $true
            }
        }
    }

    return $false
}

function Restore-ExpandedTreeNodeKeys {
    param(
        [string[]]$ExpandedKeys,
        [string]$RevealRelativePath
    )

    foreach ($key in @($ExpandedKeys | Where-Object { $_ } | Select-Object -Unique)) {
        $item = Find-TreeViewItemByRelativePath -Items $Controls.PromptTree.Items -RelativePath $key
        if ($item) {
            $item.IsExpanded = $true
        }
    }

    if ($RevealRelativePath) {
        [void](Expand-TreeViewToRelativePath -Items $Controls.PromptTree.Items -RelativePath $RevealRelativePath)
    }
}

function Get-SiblingEntityPath {
    param(
        [Parameter(Mandatory)][string]$EntityPath,
        [Parameter(Mandatory)][string]$ModeRoot
    )

    $entityFolder = Split-Path -Path $EntityPath -Parent
    $folder = Split-Path -Path $entityFolder -Parent
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        return $null
    }

    $siblings = Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'entity.txt') -PathType Leaf) -and
            -not $_.FullName.Equals($entityFolder, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object Name

    $first = $siblings | Select-Object -First 1
    if ($first) {
        return (Join-Path $first.FullName 'entity.txt')
    }

    $relative = $EntityPath.Substring($ModeRoot.Length).TrimStart('\')
    $topCategory = ($relative -split '\\')[0]
    $categoryRoot = Join-Path $ModeRoot $topCategory
    if (Test-Path -LiteralPath $categoryRoot -PathType Container) {
        $fallback = Get-ChildItem -LiteralPath $categoryRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'entity.txt') -PathType Leaf) -and
                -not $_.FullName.Equals($entityFolder, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object FullName |
            Select-Object -First 1
        if ($fallback) {
            return (Join-Path $fallback.FullName 'entity.txt')
        }
    }

    return $null
}

function Get-ReferenceTextForDocument {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Mode,
        [bool]$UseTemplate
    )

    $templateRoot = Get-TemplateModeRootPath -Context $Context -Mode $Mode
    $modeRoot = Get-ModeRootPath -Context $Context -Campaign $Document.Campaign -Mode $Mode
    $referencePath = $null

    if ($UseTemplate) {
        $referencePath = Join-Path $templateRoot $Document.RelativePath
        if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
            $referencePath = $null
        }
    }

    if (-not $referencePath) {
        if ($Document.Type -like 'Entity*') {
            $referencePath = Get-SiblingEntityPath -EntityPath $Document.Path -ModeRoot $modeRoot
            if (-not $referencePath) {
                $templateCandidate = Join-Path $templateRoot $Document.RelativePath
                $referencePath = Get-SiblingEntityPath -EntityPath $templateCandidate -ModeRoot $templateRoot
            }
        }
        else {
            $relativeDir = Split-Path -Path $Document.RelativePath -Parent
            $dir = if ($relativeDir) { Join-Path $modeRoot $relativeDir } else { $modeRoot }
            if (Test-Path -LiteralPath $dir -PathType Container) {
                $referencePath = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.FullName.Equals($Document.Path, [System.StringComparison]::OrdinalIgnoreCase) } |
                    Sort-Object Name |
                    Select-Object -First 1 -ExpandProperty FullName
            }
            if (-not $referencePath) {
                $templateCandidate = Join-Path $templateRoot $Document.RelativePath
                if (Test-Path -LiteralPath $templateCandidate -PathType Leaf) {
                    $referencePath = $templateCandidate
                }
            }
        }
    }

    if ($referencePath -and (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
        return [System.IO.File]::ReadAllText($referencePath)
    }

    return ''
}

function Get-FirstEntityDocumentFromRoot {
    param([Parameter(Mandatory)][string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'entity.txt') -PathType Leaf } |
        Sort-Object Name |
        Select-Object -First 1

    if (-not $candidate) {
        $candidate = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'entity.txt') -PathType Leaf } |
            Sort-Object FullName |
            Select-Object -First 1
    }

    if ($candidate) {
        return (Parse-EntityDocument -Content ([System.IO.File]::ReadAllText((Join-Path $candidate.FullName 'entity.txt'))))
    }

    return $null
}

function Get-CurrentModelDescriptor {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$ModelKey
    )

    $selectedKey = if ($ModelKey) { $ModelKey } else { $Context.ActiveModel }
    if (-not $selectedKey) {
        return $null
    }
    if (-not $Context.Models.ContainsKey($selectedKey)) {
        return $null
    }

    $model = $Context.Models[$selectedKey]
    $providerKey = $model.provider
    $provider = if ($Context.Providers.ContainsKey($providerKey)) { $Context.Providers[$providerKey] } else { $null }

    [pscustomobject]@{
        ModelKey    = $selectedKey
        ProviderKey = $providerKey
        ModelName   = $model.model
        Provider    = $provider
    }
}

function Get-ModelKeysForProvider {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$ProviderKey
    )

    $allKeys = @($Context.Models.Keys | Sort-Object)
    if (-not $ProviderKey) {
        return $allKeys
    }

    return @($allKeys | Where-Object {
        $Context.Models.ContainsKey($_) -and
        $Context.Models[$_].provider -eq $ProviderKey
    })
}

function Test-PlaceholderApiKey {
    param([string]$ApiKey)

    if (-not $ApiKey) {
        return $true
    }

    return $ApiKey -match '^(YOUR_|REPLACE_|CHANGEME|PUT_)'
}

function Build-AiPromptText {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$CurrentText,
        [Parameter(Mandatory)][string]$ReferenceText,
        [Parameter(Mandatory)][string]$UserInstructions
    )

    if ($Document.Type -eq 'Mandatory') {
@"
Generate a Sentient Sands mandatory prompt file.

Target relative path:
$($Document.RelativePath)

Rules:
- Keep the output in plain text only.
- Preserve the tone and structure conventions used by sibling mandatory prompt files.
- Do not add markdown fences or commentary.

Current file:
<<<CURRENT
$CurrentText
CURRENT

Reference example:
<<<REFERENCE
$ReferenceText
REFERENCE

User instructions:
$UserInstructions
"@
    }
    else {
@"
Generate a KayakDB entity.txt entry for Sentient Sands.

Target relative path:
$($Document.RelativePath)

Rules:
- Return only the final entity.txt content.
- Keep the first three header lines exactly in this order: Category, Name, Id.
- Preserve field ordering and style from the supplied schema/reference.
- Use `$ prefixes only where the schema/reference implies prose fields.
- Do not add markdown fences or commentary.

Current schema/content:
<<<CURRENT
$CurrentText
CURRENT

Reference example:
<<<REFERENCE
$ReferenceText
REFERENCE

User instructions:
$UserInstructions
"@
    }
}

function Invoke-AiDraft {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$ModelKey,
        [Parameter(Mandatory)][string]$CurrentText,
        [Parameter(Mandatory)][string]$ReferenceText,
        [Parameter(Mandatory)][string]$UserInstructions
    )

    $descriptor = Get-CurrentModelDescriptor -Context $Context -ModelKey $ModelKey
    if (-not $descriptor) {
        throw "Configured model '$ModelKey' was not found in models.json."
    }
    if (-not $descriptor.Provider) {
        throw "Provider '$($descriptor.ProviderKey)' for model '$ModelKey' was not found in providers.json."
    }

    $apiKey = [string]$descriptor.Provider.api_key
    $baseUrl = [string]$descriptor.Provider.base_url
    if (-not $baseUrl) {
        throw "Provider '$($descriptor.ProviderKey)' has no base_url."
    }
    if ((Test-PlaceholderApiKey -ApiKey $apiKey) -and $descriptor.ProviderKey -notin @('ollama', 'player2')) {
        throw "Provider '$($descriptor.ProviderKey)' is configured with a placeholder or empty API key."
    }

    $promptText = Build-AiPromptText -Document $Document -CurrentText $CurrentText -ReferenceText $ReferenceText -UserInstructions $UserInstructions
    $uriBase = $baseUrl.TrimEnd('/')
    $uri = if ($uriBase.EndsWith('/chat/completions', [System.StringComparison]::OrdinalIgnoreCase)) {
        $uriBase
    }
    else {
        $uriBase + '/chat/completions'
    }

    $headers = @{
        'Content-Type' = 'application/json'
    }
    if ($apiKey) {
        $headers['Authorization'] = "Bearer $apiKey"
    }

    $payload = @{
        model       = $descriptor.ModelName
        temperature = 0.7
        messages    = @(
            @{
                role    = 'system'
                content = 'You generate Sentient Sands / Kayak prompt files. Return only the final file content.'
            },
            @{
                role    = 'user'
                content = $promptText
            }
        )
    }

    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($payload | ConvertTo-Json -Depth 8)
    $choice = $response.choices | Select-Object -First 1
    if (-not $choice) {
        throw 'No completion choices were returned by the provider.'
    }

    $content = [string]$choice.message.content
    if (-not $content.Trim()) {
        throw 'The provider returned an empty draft.'
    }

    return $content.Trim()
}

function Show-Message {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'Kenshi Prompt Explorer',
        [System.Windows.MessageBoxButton]$Buttons = [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )

    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Show-TextEntryDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$DefaultValue = ''
    )

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Input"
        SizeToContent="WidthAndHeight"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#F8FAFC"
        Foreground="#111827"
        FontFamily="Segoe UI"
        MinWidth="480">
  <Border Padding="18">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="PromptText" TextWrapping="Wrap" Margin="0,0,0,10"/>
      <TextBox x:Name="ValueBox" Grid.Row="1" MinWidth="420" Padding="8" Background="#FFFFFF" Foreground="#111827" BorderBrush="#CBD5E1"/>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="CancelButton" Content="Cancel" Width="88" Margin="0,0,8,0"/>
        <Button x:Name="OkButton" Content="OK" Width="88" IsDefault="True"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Title = $Title
    ($window.FindName('PromptText')).Text = $Prompt
    $valueBox = $window.FindName('ValueBox')
    $valueBox.Text = $DefaultValue
    $window.FindName('CancelButton').Add_Click({ $window.DialogResult = $false })
    $window.FindName('OkButton').Add_Click({ $window.DialogResult = $true })
    $valueBox.SelectAll()

    $result = $window.ShowDialog()
    if ($result) {
        return $valueBox.Text
    }

    return $null
}

function Show-NewEntityDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [string]$FolderName = '',
        [string]$DisplayName = '',
        [string]$EntryId = ''
    )

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="New Entity"
        SizeToContent="WidthAndHeight"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#F8FAFC"
        Foreground="#111827"
        FontFamily="Segoe UI"
        MinWidth="520">
  <Border Padding="18">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="CategoryText" Margin="0,0,0,12" FontWeight="SemiBold"/>
      <Grid Grid.Row="1" Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Folder Name" VerticalAlignment="Center"/>
        <TextBox x:Name="FolderNameBox" Grid.Column="1" Padding="8" Background="#FFFFFF" Foreground="#111827" BorderBrush="#CBD5E1"/>
      </Grid>
      <Grid Grid.Row="2" Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Display Name" VerticalAlignment="Center"/>
        <TextBox x:Name="DisplayNameBox" Grid.Column="1" Padding="8" Background="#FFFFFF" Foreground="#111827" BorderBrush="#CBD5E1"/>
      </Grid>
      <Grid Grid.Row="3">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Id" VerticalAlignment="Center"/>
        <TextBox x:Name="IdBox" Grid.Column="1" Padding="8" Background="#FFFFFF" Foreground="#111827" BorderBrush="#CBD5E1"/>
      </Grid>
      <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="TemplateButton" Content="Create from template" Margin="0,0,8,0"/>
        <Button x:Name="CancelButton" Content="Cancel" Width="88" Margin="0,0,8,0"/>
        <Button x:Name="OkButton" Content="OK" Width="88" IsDefault="True"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Title = $Title
    $window.FindName('CategoryText').Text = "Category: $Category"
    $folderBox = $window.FindName('FolderNameBox')
    $displayBox = $window.FindName('DisplayNameBox')
    $idBox = $window.FindName('IdBox')
    $folderBox.Text = $FolderName
    $displayBox.Text = $DisplayName
    $idBox.Text = $EntryId

    $displayBox.Add_TextChanged({
        if (-not $folderBox.IsKeyboardFocusWithin -and -not $folderBox.Text.Trim()) {
            $folderBox.Text = ConvertTo-Slug -Text $displayBox.Text
        }
        if (-not $idBox.IsKeyboardFocusWithin -and -not $idBox.Text.Trim()) {
            $idBox.Text = ConvertTo-Slug -Text $displayBox.Text
        }
    })

    $window.FindName('TemplateButton').Add_Click({
        $window.Tag = 'CreateFromTemplate'
        $window.DialogResult = $true
    })
    $window.FindName('CancelButton').Add_Click({ $window.DialogResult = $false })
    $window.FindName('OkButton').Add_Click({
        if (-not $folderBox.Text.Trim()) {
            Show-Message -Message 'Folder Name is required.' -Icon Warning | Out-Null
            return
        }
        if (-not $idBox.Text.Trim()) {
            $idBox.Text = ConvertTo-Slug -Text $folderBox.Text
        }
        if (-not $displayBox.Text.Trim()) {
            $displayBox.Text = $folderBox.Text.Replace('_', ' ')
        }
        $window.DialogResult = $true
    })

    $result = $window.ShowDialog()
    if (-not $result) {
        return $null
    }

    return [pscustomobject]@{
        Action      = if ($window.Tag) { [string]$window.Tag } else { 'CreateNew' }
        FolderName  = (ConvertTo-Slug -Text $folderBox.Text)
        DisplayName = $displayBox.Text.Trim()
        EntryId     = (ConvertTo-Slug -Text $idBox.Text)
    }
}

function Show-FolderPicker {
    param([string]$Description = 'Select a folder')
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Show-OpenFilePicker {
    param(
        [string]$Title = 'Open File',
        [string]$Filter = 'All files (*.*)|*.*'
    )

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    if ($dialog.ShowDialog()) {
        return $dialog.FileName
    }
    return $null
}

function Show-TemplatePickerDialog {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$InitialMode = 'Content Prompts'
    )

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Create From Template"
        Width="900"
        Height="680"
        MinWidth="760"
        MinHeight="560"
        WindowStartupLocation="CenterOwner"
        Background="#FFFFFF"
        Foreground="#111827"
        FontFamily="Segoe UI">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <WrapPanel Margin="0,0,0,10">
      <TextBlock Text="Source Workspace" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="PickerSourceCombo" Width="170" Margin="0,0,18,0"/>
      <TextBlock Text="Browse Mode" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="PickerModeCombo" Width="180" Margin="0,0,18,0"/>
      <TextBlock Text="Search" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="PickerSearchBox" Width="280" Height="32"/>
    </WrapPanel>
    <Grid Grid.Row="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="SelectionText" Text="Select a template file or entity." Foreground="#475569" Margin="0,0,0,8"/>
      <TreeView x:Name="PickerTree" Grid.Row="1" Background="#FFFFFF" BorderBrush="#CBD5E1" Foreground="#111827"/>
    </Grid>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="CancelButton" Content="Cancel" Width="88" Margin="0,0,8,0"/>
      <Button x:Name="CreateButton" Content="Create Copy" Width="110" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $sourceCombo = $window.FindName('PickerSourceCombo')
    $modeCombo = $window.FindName('PickerModeCombo')
    $searchBox = $window.FindName('PickerSearchBox')
    $tree = $window.FindName('PickerTree')
    $selectionText = $window.FindName('SelectionText')
    $sourceCombo.Items.Add((Get-TemplateWorkspaceName)) | Out-Null
    foreach ($campaign in $Context.Campaigns) {
        $sourceCombo.Items.Add($campaign.Name) | Out-Null
    }
    $sourceCombo.SelectedItem = (Get-TemplateWorkspaceName)
    $modeCombo.Items.Add('Gameplay Prompts') | Out-Null
    $modeCombo.Items.Add('Content Prompts') | Out-Null
    $modeCombo.SelectedItem = if ($InitialMode -eq 'Gameplay Prompts') { 'Gameplay Prompts' } else { 'Content Prompts' }

    $refreshTree = {
        $tree.Items.Clear()
        $selectedWorkspace = [string]$sourceCombo.SelectedItem
        $selectedMode = [string]$modeCombo.SelectedItem
        $sourceRoot = Get-ModeRootPath -Context $Context -Campaign $selectedWorkspace -Mode $selectedMode
        $search = $searchBox.Text.Trim()
        if ($selectedMode -eq 'Gameplay Prompts') {
            Add-MandatoryTreeChildren -RootPath $sourceRoot -BasePath $sourceRoot -TargetCollection $tree.Items -Search $search
        }
        else {
            Add-ContentTreeChildren -RootPath $sourceRoot -BasePath $sourceRoot -TargetCollection $tree.Items -Search $search
        }
        $workspaceLabel = if (Test-IsTemplateWorkspace -Campaign $selectedWorkspace) { 'Template' } else { $selectedWorkspace }
        $selectionText.Text = "Source: $workspaceLabel / $selectedMode"
    }

    $tree.Add_SelectedItemChanged({
        $selected = $tree.SelectedItem
        if ($selected -and $selected.Tag) {
            $selectionText.Text = "Selected: $($selected.Tag.RelativePath)"
        }
    })

    $sourceCombo.Add_SelectionChanged({ & $refreshTree })
    $modeCombo.Add_SelectionChanged({ & $refreshTree })
    $searchBox.Add_TextChanged({ & $refreshTree })
    $window.FindName('CancelButton').Add_Click({ $window.DialogResult = $false })
    $window.FindName('CreateButton').Add_Click({
        $selected = $tree.SelectedItem
        if (-not $selected -or -not $selected.Tag) {
            Show-Message -Message 'Select a template file or entity first.' -Icon Warning | Out-Null
            return
        }

        $selectedMode = [string]$modeCombo.SelectedItem
        $expectedKind = if ($selectedMode -eq 'Gameplay Prompts') { 'MandatoryFile' } else { 'EntityFile' }
        if ($selected.Tag.Kind -ne $expectedKind) {
            Show-Message -Message 'Select a template file or entity, not a folder.' -Icon Warning | Out-Null
            return
        }

        $window.Tag = [pscustomobject]@{
            Mode            = $selectedMode
            SourceWorkspace = [string]$sourceCombo.SelectedItem
            Node            = $selected.Tag
        }
        $window.DialogResult = $true
    })

    & $refreshTree
    $result = $window.ShowDialog()
    if ($result -and $window.Tag) {
        return $window.Tag
    }

    return $null
}

if ($SelfTest) {
    if (-not $InitialModRoot) {
        throw 'SelfTest requires -InitialModRoot.'
    }

    $ctx = Get-ModContext -ModRoot $InitialModRoot
    Write-Output ("MOD_ROOT={0}" -f $ctx.ModRoot)
    Write-Output ("ACTIVE_CAMPAIGN={0}" -f $ctx.ActiveCampaign)
    Write-Output ("ACTIVE_MODEL={0}" -f $ctx.ActiveModel)
    Write-Output ("CAMPAIGN_COUNT={0}" -f $ctx.Campaigns.Count)
    Write-Output ("PROVIDER_COUNT={0}" -f $ctx.Providers.Count)
    Write-Output ("MODEL_COUNT={0}" -f $ctx.Models.Count)
    $campaignModeRoot = Get-ModeRootPath -Context $ctx -Campaign $ctx.ActiveCampaign -Mode 'Content Prompts'
    $sampleEntity = Get-ChildItem -LiteralPath $campaignModeRoot -Recurse -Filter entity.txt -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sampleEntity) {
        $entity = Parse-EntityDocument -Content ([System.IO.File]::ReadAllText($sampleEntity.FullName))
        Write-Output ("ENTITY_PARSE_CAN_ROUNDTRIP={0}" -f $entity.CanRoundTripStructured)
        Write-Output ("ENTITY_HEADER={0}" -f ($entity.Header.Keys -join ','))
        $rendered = Render-EntityDocument -Document $entity
        Write-Output ("ENTITY_RENDER_LENGTH={0}" -f $rendered.Length)
    }

    $tree = [System.Windows.Controls.TreeView]::new()
    $mandatoryRoot = Get-ModeRootPath -Context $ctx -Campaign $ctx.ActiveCampaign -Mode 'Gameplay Prompts'
    Add-MandatoryTreeChildren -RootPath $mandatoryRoot -BasePath $mandatoryRoot -TargetCollection $tree.Items -Search ''
    Write-Output ("MANDATORY_TREE_ROOT_ITEMS={0}" -f $tree.Items.Count)
    $tree.Items.Clear()

    $contentRoot = Get-ModeRootPath -Context $ctx -Campaign $ctx.ActiveCampaign -Mode 'Content Prompts'
    Add-ContentTreeChildren -RootPath $contentRoot -BasePath $contentRoot -TargetCollection $tree.Items -Search ''
    Write-Output ("CONTENT_TREE_ROOT_ITEMS={0}" -f $tree.Items.Count)
    exit
}

[xml]$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kenshi Prompt Explorer"
        Width="1660"
        Height="980"
        MinWidth="1320"
        MinHeight="760"
        Background="#F5F7FB"
        Foreground="#111827"
        FontFamily="Segoe UI"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Background" Value="#E8EEF9"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#C7D2E3"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="#F9FAFB"/>
      <Setter Property="BorderBrush" Value="#1D4ED8"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="Padding" Value="8"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="Padding" Value="6"/>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#111827"/>
    </Style>
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#D7DEE9"/>
      <Setter Property="Foreground" Value="#111827"/>
    </Style>
    <Style TargetType="TreeViewItem">
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#D7DEE9"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Padding" Value="10"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#D7DEE9"/>
      <Setter Property="Foreground" Value="#111827"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="Background" Value="#EDF2F7"/>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Padding="14" CornerRadius="14" Background="#FFFFFF" BorderBrush="#D7DEE9" BorderThickness="1" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="RootPathBox" Height="36" IsReadOnly="True" Margin="0,0,10,0" Background="#F8FAFC"/>
          <Button x:Name="OpenFolderButton" Grid.Column="1" Content="Open Mod Folder" Height="36" Margin="0,0,8,0" Style="{StaticResource AccentButton}"/>
          <Button x:Name="ImportZipButton" Grid.Column="2" Content="Import Zip" Height="36" Margin="0"/>
        </Grid>

        <Grid Grid.Row="1" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="170"/>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="170"/>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="260"/>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <StackPanel Grid.Column="0" Margin="0,0,12,0">
            <TextBlock Text="Campaign" Margin="0,0,0,6"/>
            <ComboBox x:Name="CampaignCombo" Height="36"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="0,0,12,0">
            <TextBlock Text="Mode" Margin="0,0,0,6"/>
            <ComboBox x:Name="ModeCombo" Height="36"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Margin="0,0,12,0">
            <TextBlock Text="Provider" Margin="0,0,0,6"/>
            <ComboBox x:Name="ProviderCombo" Height="36"/>
          </StackPanel>
          <StackPanel Grid.Column="3" Margin="0,0,12,0">
            <TextBlock Text="Model" Margin="0,0,0,6"/>
            <ComboBox x:Name="ModelCombo" Height="36"/>
          </StackPanel>
          <StackPanel Grid.Column="4" Margin="0,0,12,0">
            <TextBlock Text="Search" Margin="0,0,0,6"/>
            <TextBox x:Name="SearchBox" Height="36"/>
          </StackPanel>
          <StackPanel Grid.Column="5" Margin="0,0,12,0">
            <TextBlock x:Name="NewCategoryLabel" Text="New In" Margin="0,0,0,6"/>
            <ComboBox x:Name="NewCategoryCombo" Height="36"/>
          </StackPanel>
        </Grid>

        <WrapPanel Grid.Row="2" HorizontalAlignment="Right">
          <Button x:Name="NewButton" Content="New" Height="36"/>
          <Button x:Name="CreateFromTemplateButton" Content="From Existing" Height="36"/>
          <Button x:Name="DeleteButton" Content="Delete" Height="36"/>
          <Button x:Name="SaveButton" Content="Save" Height="36"/>
          <Button x:Name="SaveAsButton" Content="Save As" Height="36"/>
          <Button x:Name="GenerateButton" Content="Generate Draft" Height="36" Margin="12,0,8,0"/>
          <Button x:Name="ApplyDraftButton" Content="Apply Draft" Height="36" Margin="0"/>
        </WrapPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="460"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#D7DEE9" BorderThickness="1" CornerRadius="14" Padding="10" Margin="0,0,12,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <WrapPanel Margin="0,0,0,10">
            <Button x:Name="ExpandAllButton" Content="Expand All" Height="32" Style="{StaticResource AccentButton}"/>
            <Button x:Name="CollapseAllButton" Content="Collapse All" Height="32" Margin="0"/>
          </WrapPanel>
          <TreeView x:Name="PromptTree" Grid.Row="1"/>
        </Grid>
      </Border>

      <Border Grid.Column="1" Background="#FFFFFF" BorderBrush="#D7DEE9" BorderThickness="1" CornerRadius="14" Padding="12" Margin="0,0,12,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="EditorHeaderText" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,12"/>
          <Grid Grid.Row="1">
            <TextBox x:Name="MandatoryEditor" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Cascadia Code" Visibility="Collapsed"/>
            <ScrollViewer x:Name="StructuredEditorScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="StructuredEditorPanel"/>
            </ScrollViewer>
            <TextBox x:Name="RawEntityEditor" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Cascadia Code" Visibility="Collapsed"/>
            <TextBlock x:Name="EmptyStateText" Text="Open a mod folder, choose a campaign, then select a file or entity." Foreground="#64748B" FontSize="18" VerticalAlignment="Center" HorizontalAlignment="Center"/>
          </Grid>
        </Grid>
      </Border>

      <Border Grid.Column="2" Background="#FFFFFF" BorderBrush="#D7DEE9" BorderThickness="1" CornerRadius="14" Padding="12">
        <TabControl x:Name="RightTabs" Background="#FFFFFF" BorderBrush="#D7DEE9" Foreground="#111827">
          <TabItem Header="Preview">
            <Grid Margin="10">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock x:Name="MetadataText" TextWrapping="Wrap" Foreground="#64748B" Margin="0,0,0,10"/>
              <TextBox x:Name="PreviewTextBox" Grid.Row="1" AcceptsReturn="True" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Cascadia Code"/>
            </Grid>
          </TabItem>
          <TabItem Header="Reference">
            <Grid Margin="10">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <CheckBox x:Name="TemplateReferenceCheckBox" Content="Use Template Reference" Margin="0,0,0,10"/>
              <TextBox x:Name="ReferenceTextBox" Grid.Row="1" AcceptsReturn="True" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Cascadia Code"/>
            </Grid>
          </TabItem>
          <TabItem Header="AI Draft">
            <Grid Margin="10">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="110"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Text="Instructions" Margin="0,0,0,8"/>
              <TextBox x:Name="AiInstructionsBox" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Code"/>
              <TextBlock Grid.Row="2" Text="Draft Preview" Margin="0,12,0,8"/>
              <TextBox x:Name="AiDraftTextBox" Grid.Row="3" AcceptsReturn="True" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Cascadia Code"/>
            </Grid>
          </TabItem>
        </TabControl>
      </Border>
    </Grid>

    <Border Grid.Row="2" Padding="10" CornerRadius="12" Background="#FFFFFF" BorderBrush="#D7DEE9" BorderThickness="1" Margin="0,12,0,0">
      <TextBlock x:Name="StatusText" Text="Ready." Foreground="#334155"/>
    </Border>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($MainXaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

$Controls = @{}
foreach ($name in @(
        'RootPathBox', 'OpenFolderButton', 'ImportZipButton', 'CampaignCombo', 'ModeCombo', 'ProviderCombo', 'ModelCombo', 'SearchBox',
        'NewCategoryLabel', 'NewCategoryCombo',
        'ExpandAllButton', 'CollapseAllButton',
        'NewButton', 'CreateFromTemplateButton', 'DeleteButton', 'SaveButton', 'SaveAsButton', 'GenerateButton', 'ApplyDraftButton', 'PromptTree',
        'EditorHeaderText', 'MandatoryEditor', 'StructuredEditorScroll', 'StructuredEditorPanel', 'RawEntityEditor',
        'EmptyStateText', 'MetadataText', 'PreviewTextBox', 'ReferenceTextBox', 'TemplateReferenceCheckBox',
        'AiInstructionsBox', 'AiDraftTextBox', 'StatusText'
    )) {
    $Controls[$name] = $Window.FindName($name)
}

$script:State = [ordered]@{
    ModContext          = $null
    CurrentCampaign     = ''
    CurrentMode         = 'Gameplay Prompts'
    CurrentDocument     = $null
    IsDirty             = $false
    SuspendEditorEvents = $false
    SuspendUiEvents     = $false
    LastStatus          = 'Ready.'
}

function Set-Status {
    param([Parameter(Mandatory)][string]$Text)
    $script:State.LastStatus = $Text
    $Controls.StatusText.Text = $Text
}

function Update-WindowTitle {
    $dirty = if ($script:State.IsDirty) { ' *' } else { '' }
    $root = if ($script:State.ModContext) { $script:State.ModContext.ModRoot } else { 'No mod loaded' }
    $Window.Title = "Kenshi Prompt Explorer$dirty - $root"
}

function Set-Dirty {
    param([bool]$Value)
    $script:State.IsDirty = $Value
    Update-WindowTitle
}

function Invoke-UiAction {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Context
    )

    try {
        & $Action
    }
    catch {
        $message = $_.Exception.Message
        Set-Status -Text "$Context failed: $message"
        Show-Message -Message $message -Title 'Kenshi Prompt Explorer' -Icon Error | Out-Null
    }
}

function Confirm-DiscardChanges {
    if (-not $script:State.IsDirty) {
        return $true
    }

    $result = Show-Message -Message 'You have unsaved changes. Discard them?' -Buttons YesNo -Icon Warning
    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

function Get-CurrentEditorText {
    if (-not $script:State.CurrentDocument) {
        return ''
    }

    switch ($script:State.CurrentDocument.Type) {
        'Mandatory' { return $Controls.MandatoryEditor.Text }
        'EntityRaw' { return $Controls.RawEntityEditor.Text }
        'EntityStructured' { return (Render-EntityDocument -Document $script:State.CurrentDocument.Entity) }
        default { return '' }
    }
}

function Update-PreviewAndReference {
    if (-not $script:State.CurrentDocument -or -not $script:State.ModContext) {
        $Controls.PreviewTextBox.Text = ''
        $Controls.MetadataText.Text = ''
        $Controls.ReferenceTextBox.Text = ''
        return
    }

    $rendered = Get-CurrentEditorText
    $Controls.PreviewTextBox.Text = $rendered

    $doc = $script:State.CurrentDocument
    $metadata = @(
        "Mode: $($script:State.CurrentMode)"
        "Campaign: $($doc.Campaign)"
        "Path: $($doc.Path)"
    )
    if ($doc.FileProfile) {
        $metadata += "NewLine: " + ($doc.FileProfile.NewLine.Replace("`r", '\r').Replace("`n", '\n'))
        $metadata += "UTF8 BOM: " + [string]$doc.FileProfile.HasUtf8Bom
    }
    if ($doc.Type -eq 'EntityRaw' -and $doc.Entity) {
        $metadata += 'Structured editing disabled because the file contains unsupported free text or missing header lines.'
    }
    $Controls.MetadataText.Text = ($metadata -join '    ')

    $referenceText = Get-ReferenceTextForDocument -Context $script:State.ModContext -Document $doc -Mode $script:State.CurrentMode -UseTemplate:$Controls.TemplateReferenceCheckBox.IsChecked
    $Controls.ReferenceTextBox.Text = $referenceText
}

function Show-EmptyEditor {
    $Controls.EmptyStateText.Visibility = 'Visible'
    $Controls.MandatoryEditor.Visibility = 'Collapsed'
    $Controls.StructuredEditorScroll.Visibility = 'Collapsed'
    $Controls.RawEntityEditor.Visibility = 'Collapsed'
    $Controls.EditorHeaderText.Text = ''
    $Controls.PreviewTextBox.Text = ''
    $Controls.ReferenceTextBox.Text = ''
    $Controls.MetadataText.Text = ''
}

function Set-TreeExpansionState {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][bool]$Expanded
    )

    foreach ($item in @($Items)) {
        if ($item -is [System.Windows.Controls.TreeViewItem]) {
            $item.IsExpanded = $Expanded
            if ($item.Items.Count -gt 0) {
                Set-TreeExpansionState -Items $item.Items -Expanded:$Expanded
            }
        }
    }
}

function Add-StructuredTextBox {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Panel]$Panel,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)]$BindingInfo,
        $DeleteBindingInfo,
        [switch]$CanDelete,
        [switch]$MultiLine
    )

    $row = [System.Windows.Controls.Grid]::new()
    $row.Margin = '0,0,0,8'
    $row.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
    $row.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
    $row.ColumnDefinitions[0].Width = '160'
    $row.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    if ($CanDelete) {
        $row.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
        $row.ColumnDefinitions[2].Width = [System.Windows.GridLength]::Auto
    }

    $labelBlock = [System.Windows.Controls.TextBlock]::new()
    $labelBlock.Text = $Label
    $labelBlock.VerticalAlignment = 'Center'
    $labelBlock.Margin = '0,0,10,0'
    [System.Windows.Controls.Grid]::SetColumn($labelBlock, 0)

    $textBox = [System.Windows.Controls.TextBox]::new()
    $textBox.Text = $Value
    $textBox.AcceptsReturn = [bool]$MultiLine
    $textBox.TextWrapping = if ($MultiLine) { 'Wrap' } else { 'NoWrap' }
    $textBox.VerticalScrollBarVisibility = if ($MultiLine) { 'Auto' } else { 'Disabled' }
    $textBox.MinHeight = if ($MultiLine) { 80 } else { 0 }
    $textBox.Tag = $BindingInfo
    [System.Windows.Controls.Grid]::SetColumn($textBox, 1)
    $textBox.Add_TextChanged({
        if ($script:State.SuspendEditorEvents -or -not $script:State.CurrentDocument) {
            return
        }

        $binding = $this.Tag
        if (-not $binding) {
            return
        }

        if ($binding.Scope -eq 'Header') {
            $binding.Document.Header[$binding.FieldName] = $this.Text
        }
        else {
            $binding.Document.Fields[$binding.FieldName] = $this.Text
        }

        Set-Dirty -Value $true
        Update-PreviewAndReference
    })

    $row.Children.Add($labelBlock) | Out-Null
    $row.Children.Add($textBox) | Out-Null
    if ($CanDelete) {
        $deleteButton = [System.Windows.Controls.Button]::new()
        $deleteButton.Content = 'Delete'
        $deleteButton.Margin = '8,0,0,0'
        $deleteButton.Tag = $DeleteBindingInfo
        [System.Windows.Controls.Grid]::SetColumn($deleteButton, 2)
        $deleteButton.Add_Click({
            $binding = $this.Tag
            if (-not $binding -or -not $binding.Document -or -not $binding.FieldName) {
                return
            }

            $result = Show-Message -Message ("Delete custom field '{0}'?" -f $binding.FieldName) -Buttons YesNo -Icon Warning
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }

            [void]$binding.Document.Fields.Remove($binding.FieldName)
            if ($binding.Document.FieldMeta.Contains($binding.FieldName)) {
                [void]$binding.Document.FieldMeta.Remove($binding.FieldName)
            }
            $binding.Document.LayoutOrder = @($binding.Document.LayoutOrder | Where-Object { $_ -ne $binding.FieldName })
            Set-Dirty -Value $true
            Render-StructuredEditor
            Update-PreviewAndReference
        })
        $row.Children.Add($deleteButton) | Out-Null
    }
    $Panel.Children.Add($row) | Out-Null
}

function Render-StructuredEditor {
    if (-not $script:State.CurrentDocument -or $script:State.CurrentDocument.Type -ne 'EntityStructured') {
        return
    }

    $script:State.SuspendEditorEvents = $true
    $panel = $Controls.StructuredEditorPanel
    $panel.Children.Clear()
    $document = $script:State.CurrentDocument.Entity

    $headerGroup = [System.Windows.Controls.GroupBox]::new()
    $headerGroup.Header = 'Header'
    $headerPanel = [System.Windows.Controls.StackPanel]::new()
    $headerGroup.Content = $headerPanel
    foreach ($fieldName in @('Category', 'Name', 'Id')) {
        $capturedHeaderField = [string]$fieldName
        Add-StructuredTextBox -Panel $headerPanel -Label $capturedHeaderField -Value ([string]$document.Header[$capturedHeaderField]) -BindingInfo ([pscustomobject]@{
                Document  = $document
                Scope     = 'Header'
                FieldName = $capturedHeaderField
            })
    }
    $panel.Children.Add($headerGroup) | Out-Null

    $groups = [ordered]@{
        'Identifiers'        = @()
        'Structural'         = @()
        'Knowledge / Traits' = @()
        'Prose'              = @()
        'Custom'             = @()
    }

    foreach ($key in (Get-SortedEntityFieldNames -Document $document)) {
        switch (Get-EntityGroupName -FieldName $key -Document $document) {
            'ids' { $groups['Identifiers'] += $key; continue }
            'structural' { $groups['Structural'] += $key; continue }
            'knowledge' { $groups['Knowledge / Traits'] += $key; continue }
            'prose' { $groups['Prose'] += $key; continue }
            default { $groups['Custom'] += $key; continue }
        }
    }

    foreach ($groupName in $groups.Keys) {
        $groupKeys = @($groups[$groupName])
        if ($groupKeys.Count -eq 0 -and $groupName -ne 'Custom') {
            continue
        }

        $groupBox = [System.Windows.Controls.GroupBox]::new()
        $groupBox.Header = $groupName
        $groupPanel = [System.Windows.Controls.StackPanel]::new()
        $groupBox.Content = $groupPanel

        foreach ($key in $groupKeys) {
            $isMultiLine = (Get-EntityGroupName -FieldName $key -Document $document) -in @('knowledge', 'prose', 'custom')
            $capturedKey = [string]$key
            $bindingInfo = [pscustomobject]@{
                Document  = $document
                Scope     = 'Field'
                FieldName = $capturedKey
            }
            $canDelete = ($groupName -eq 'Custom')
            Add-StructuredTextBox -Panel $groupPanel -Label $capturedKey -Value ([string]$document.Fields[$capturedKey]) -MultiLine:$isMultiLine -BindingInfo $bindingInfo -CanDelete:$canDelete -DeleteBindingInfo $bindingInfo
        }

        if ($groupName -eq 'Custom') {
            $addButton = [System.Windows.Controls.Button]::new()
            $addButton.Content = 'Add Custom Field'
            $addButton.Margin = '0,6,0,0'
            $addButton.Tag = [pscustomobject]@{
                Document = $document
            }
            $addButton.Add_Click({
                $binding = $this.Tag
                if (-not $binding -or -not $binding.Document) {
                    return
                }

                $document = $binding.Document
                $name = Show-TextEntryDialog -Title 'New Custom Field' -Prompt 'Enter the new custom field name.' -DefaultValue 'note'
                if (-not $name) {
                    return
                }
                $normalized = Normalize-FieldKey -FieldName $name
                if ($document.Fields.Contains($normalized)) {
                    Show-Message -Message "Field '$normalized' already exists." -Icon Warning | Out-Null
                    return
                }
                $document.Fields[$normalized] = ''
                $document.FieldMeta[$normalized] = [pscustomobject]@{ OriginalKey = $normalized; IsProse = $true }
                $document.LayoutOrder += $normalized
                Set-Dirty -Value $true
                Render-StructuredEditor
                Update-PreviewAndReference
            })
            $groupPanel.Children.Add($addButton) | Out-Null
        }

        $panel.Children.Add($groupBox) | Out-Null
    }

    $script:State.SuspendEditorEvents = $false
}

function Load-MandatoryDocument {
    param([Parameter(Mandatory)]$Node)

    $fileProfile = Read-TextFileDetailed -Path $Node.Path
    $script:State.CurrentDocument = [pscustomobject]@{
        Type         = 'Mandatory'
        Path         = $Node.Path
        RelativePath = $Node.RelativePath
        Campaign     = $script:State.CurrentCampaign
        FileProfile  = $fileProfile
    }
    $script:State.SuspendEditorEvents = $true
    $Controls.EmptyStateText.Visibility = 'Collapsed'
    $Controls.StructuredEditorScroll.Visibility = 'Collapsed'
    $Controls.RawEntityEditor.Visibility = 'Collapsed'
    $Controls.MandatoryEditor.Visibility = 'Visible'
    $Controls.EditorHeaderText.Text = $Node.RelativePath
    $Controls.MandatoryEditor.Text = $fileProfile.Content
    $Controls.AiDraftTextBox.Text = ''
    $script:State.SuspendEditorEvents = $false
    Set-Dirty -Value $false
    Update-PreviewAndReference
}

function Load-EntityDocument {
    param([Parameter(Mandatory)]$Node)

    $fileProfile = Read-TextFileDetailed -Path $Node.Path
    $entity = Parse-EntityDocument -Content $fileProfile.Content
    $common = [ordered]@{
        Path         = $Node.Path
        RelativePath = $Node.RelativePath
        Campaign     = $script:State.CurrentCampaign
        FileProfile  = $fileProfile
        Entity       = $entity
    }

    $Controls.EmptyStateText.Visibility = 'Collapsed'
    $Controls.MandatoryEditor.Visibility = 'Collapsed'
    $Controls.AiDraftTextBox.Text = ''

    if ($entity.CanRoundTripStructured) {
        $script:State.CurrentDocument = [pscustomobject]($common + @{ Type = 'EntityStructured' })
        $Controls.RawEntityEditor.Visibility = 'Collapsed'
        $Controls.StructuredEditorScroll.Visibility = 'Visible'
        $Controls.EditorHeaderText.Text = $Node.RelativePath
        Render-StructuredEditor
    }
    else {
        $script:State.CurrentDocument = [pscustomobject]($common + @{ Type = 'EntityRaw' })
        $script:State.SuspendEditorEvents = $true
        $Controls.StructuredEditorScroll.Visibility = 'Collapsed'
        $Controls.RawEntityEditor.Visibility = 'Visible'
        $Controls.RawEntityEditor.Text = $fileProfile.Content
        $Controls.EditorHeaderText.Text = "$($Node.RelativePath)  [raw mode]"
        $script:State.SuspendEditorEvents = $false
    }

    Set-Dirty -Value $false
    Update-PreviewAndReference
}

function Open-TreeNode {
    param($Node)

    if (-not $Node) {
        return
    }

    switch ($Node.Kind) {
        'MandatoryFile' { Load-MandatoryDocument -Node $Node }
        'EntityFile' { Load-EntityDocument -Node $Node }
        default {
            $script:State.CurrentDocument = $null
            Show-EmptyEditor
        }
    }

    Populate-NewCategoryCombo
}

function Refresh-Tree {
    param(
        [switch]$PreserveState,
        [string]$RevealRelativePath
    )

    $expandedKeys = @()
    if ($PreserveState) {
        $expandedKeys = @(Get-ExpandedTreeNodeKeys)
    }

    $Controls.PromptTree.Items.Clear()
    if (-not $script:State.ModContext -or -not $script:State.CurrentCampaign) {
        return
    }

    $root = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode $script:State.CurrentMode
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return
    }

    $search = $Controls.SearchBox.Text.Trim()
    if ($script:State.CurrentMode -eq 'Gameplay Prompts') {
        Add-MandatoryTreeChildren -RootPath $root -BasePath $root -TargetCollection $Controls.PromptTree.Items -Search $search
    }
    else {
        Add-ContentTreeChildren -RootPath $root -BasePath $root -TargetCollection $Controls.PromptTree.Items -Search $search
    }

    if ($PreserveState -or $RevealRelativePath) {
        Restore-ExpandedTreeNodeKeys -ExpandedKeys $expandedKeys -RevealRelativePath $RevealRelativePath
    }

    Populate-NewCategoryCombo
}

function Populate-Combos {
    if (-not $script:State.ModContext) {
        return
    }

    $script:State.SuspendUiEvents = $true
    try {
        $Controls.CampaignCombo.Items.Clear()
        [void]$Controls.CampaignCombo.Items.Add((Get-TemplateWorkspaceName))
        foreach ($campaign in $script:State.ModContext.Campaigns) {
            [void]$Controls.CampaignCombo.Items.Add($campaign.Name)
        }
        if ($script:State.CurrentCampaign -and $Controls.CampaignCombo.Items.Contains($script:State.CurrentCampaign)) {
            $Controls.CampaignCombo.SelectedItem = $script:State.CurrentCampaign
        }
        elseif ($Controls.CampaignCombo.Items.Count -gt 0) {
            $Controls.CampaignCombo.SelectedIndex = 0
            $script:State.CurrentCampaign = [string]$Controls.CampaignCombo.SelectedItem
        }

        $Controls.ProviderCombo.Items.Clear()
        foreach ($providerKey in @($script:State.ModContext.Providers.Keys | Sort-Object)) {
            [void]$Controls.ProviderCombo.Items.Add($providerKey)
        }

        $activeDescriptor = Get-CurrentModelDescriptor -Context $script:State.ModContext -ModelKey $script:State.ModContext.ActiveModel
        $selectedProvider = if ($activeDescriptor) { $activeDescriptor.ProviderKey } else { '' }
        if ($selectedProvider -and $Controls.ProviderCombo.Items.Contains($selectedProvider)) {
            $Controls.ProviderCombo.SelectedItem = $selectedProvider
        }
        elseif ($Controls.ProviderCombo.Items.Count -gt 0) {
            $Controls.ProviderCombo.SelectedIndex = 0
            $selectedProvider = [string]$Controls.ProviderCombo.SelectedItem
        }

        $Controls.ModelCombo.Items.Clear()
        foreach ($modelKey in (Get-ModelKeysForProvider -Context $script:State.ModContext -ProviderKey $selectedProvider)) {
            [void]$Controls.ModelCombo.Items.Add($modelKey)
        }
        if ($script:State.ModContext.ActiveModel -and $Controls.ModelCombo.Items.Contains($script:State.ModContext.ActiveModel)) {
            $Controls.ModelCombo.SelectedItem = $script:State.ModContext.ActiveModel
        }
        elseif ($Controls.ModelCombo.Items.Count -gt 0) {
            $Controls.ModelCombo.SelectedIndex = 0
        }

        Populate-NewCategoryCombo
    }
    finally {
        $script:State.SuspendUiEvents = $false
    }
}

function Load-ModRoot {
    param([Parameter(Mandatory)][string]$SelectedPath)

    $validation = Test-ModRoot -Path $SelectedPath
    if (-not $validation.IsValid) {
        Show-Message -Message $validation.ErrorText -Icon Error | Out-Null
        return
    }

    $script:State.ModContext = Get-ModContext -ModRoot $validation.ModRoot
    $script:State.CurrentCampaign = $script:State.ModContext.ActiveCampaign
    $Controls.RootPathBox.Text = $script:State.ModContext.ModRoot
    Populate-Combos
    Refresh-Tree
    Show-EmptyEditor
    Set-Dirty -Value $false
    $workspaceLabel = if (Test-IsTemplateWorkspace -Campaign $script:State.CurrentCampaign) { 'Template' } else { $script:State.CurrentCampaign }
    Set-Status -Text "Loaded mod root: $($script:State.ModContext.ModRoot)  Workspace: $workspaceLabel"
}

function Get-SelectedTreeNodeData {
    $selected = $Controls.PromptTree.SelectedItem
    if ($selected -and $selected.Tag) {
        return $selected.Tag
    }
    return $null
}

function Get-CurrentContentCategoryRoot {
    $selected = Get-SelectedTreeNodeData
    $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
    if ($selected) {
        switch ($selected.Kind) {
            'EntityFile' {
                $folderPath = Split-Path -Path $selected.FolderPath -Parent
                if ($folderPath) {
                    return $folderPath
                }
            }
            'Folder' {
                $full = $selected.Path
                if ((Split-Path -Path $full -Parent).Equals($modeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $full
                }
                if (Test-Path -LiteralPath (Join-Path $full 'entity.txt') -PathType Leaf) {
                    return (Split-Path -Path $full -Parent)
                }
                return $full
            }
        }
    }

    return $modeRoot
}

function Get-SelectedTopLevelCategoryName {
    $selected = Get-SelectedTreeNodeData
    if (-not $selected -or -not $selected.RelativePath) {
        return ''
    }

    return (($selected.RelativePath -split '\\')[0])
}

function Populate-NewCategoryCombo {
    $script:State.SuspendUiEvents = $true
    try {
        $Controls.NewCategoryCombo.Items.Clear()

        if (-not $script:State.ModContext) {
            $Controls.NewCategoryCombo.IsEnabled = $false
            $Controls.NewCategoryLabel.Visibility = 'Collapsed'
            $Controls.NewCategoryCombo.Visibility = 'Collapsed'
            return
        }

        $isContentMode = ($script:State.CurrentMode -eq 'Content Prompts')
        $visibility = if ($isContentMode) { 'Visible' } else { 'Collapsed' }
        $Controls.NewCategoryLabel.Visibility = $visibility
        $Controls.NewCategoryCombo.Visibility = $visibility
        $Controls.NewCategoryCombo.IsEnabled = $isContentMode
        if (-not $isContentMode) {
            return
        }

        $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
        foreach ($dir in @(Get-ChildItem -LiteralPath $modeRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            [void]$Controls.NewCategoryCombo.Items.Add($dir.Name)
        }

        $preferred = Get-SelectedTopLevelCategoryName
        if (-not $preferred -and $script:State.CurrentDocument -and $script:State.CurrentDocument.Entity -and $script:State.CurrentDocument.Entity.Header.Contains('Category')) {
            $preferred = [string]$script:State.CurrentDocument.Entity.Header['Category']
        }

        if ($preferred -and $Controls.NewCategoryCombo.Items.Contains($preferred)) {
            $Controls.NewCategoryCombo.SelectedItem = $preferred
        }
        elseif ($Controls.NewCategoryCombo.Items.Count -gt 0) {
            $Controls.NewCategoryCombo.SelectedIndex = 0
        }
    }
    finally {
        $script:State.SuspendUiEvents = $false
    }
}

function Get-ContentCreationTarget {
    param([string]$PreferredCategoryName)

    $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
    $selectedRoot = Get-CurrentContentCategoryRoot
    if ($selectedRoot -and (Test-Path -LiteralPath $selectedRoot -PathType Container)) {
        $relative = $selectedRoot.Substring($modeRoot.Length).TrimStart('\')
        if ($relative -and $relative.Contains('\')) {
            return [pscustomobject]@{
                RootPath     = $selectedRoot
                CategoryName = (($relative -split '\\')[0])
                IsCustomRoot = $true
            }
        }
    }

    $categoryName = if ($PreferredCategoryName) { $PreferredCategoryName } elseif ($Controls.NewCategoryCombo.SelectedItem) { [string]$Controls.NewCategoryCombo.SelectedItem } else { '' }
    if ($categoryName) {
        $categoryRoot = Join-Path $modeRoot $categoryName
        if (Test-Path -LiteralPath $categoryRoot -PathType Container) {
            return [pscustomobject]@{
                RootPath     = $categoryRoot
                CategoryName = $categoryName
                IsCustomRoot = $false
            }
        }
    }

    if ($selectedRoot -and (Test-Path -LiteralPath $selectedRoot -PathType Container)) {
        $relative = $selectedRoot.Substring($modeRoot.Length).TrimStart('\')
        return [pscustomobject]@{
            RootPath     = $selectedRoot
            CategoryName = (($relative -split '\\')[0])
            IsCustomRoot = ($relative -and $relative.Contains('\'))
        }
    }

    return $null
}

function Get-UniqueFolderName {
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$BaseName
    )

    $candidate = $BaseName
    $index = 2
    while (Test-Path -LiteralPath (Join-Path $ParentPath $candidate)) {
        $candidate = '{0}{1}' -f $BaseName, $index
        $index++
    }
    return $candidate
}

function Get-UniqueFileName {
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Extension
    )

    $candidate = $BaseName + $Extension
    $index = 2
    while (Test-Path -LiteralPath (Join-Path $ParentPath $candidate)) {
        $candidate = '{0}{1}{2}' -f $BaseName, $index, $Extension
        $index++
    }
    return $candidate
}

function Copy-EntityDocumentForNewEntry {
    param(
        [Parameter(Mandatory)]$SourceDocument,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$EntryId
    )

    $fields = [ordered]@{}
    $meta = @{}
    foreach ($key in $SourceDocument.LayoutOrder) {
        $fields[$key] = if ($SourceDocument.Fields.Contains($key)) { [string]$SourceDocument.Fields[$key] } else { '' }
        if ($SourceDocument.FieldMeta.ContainsKey($key)) {
            $meta[$key] = $SourceDocument.FieldMeta[$key]
        }
    }

    if (-not $fields.Contains('display_name')) {
        $fields['display_name'] = ''
        $meta['display_name'] = [pscustomobject]@{ OriginalKey = 'display_name'; IsProse = $false }
    }

    $fields['display_name'] = $DisplayName

    return [pscustomobject]@{
        Header                 = [ordered]@{ Category = $Category; Name = $FolderName; Id = $EntryId }
        Fields                 = $fields
        FieldMeta              = $meta
        LayoutOrder            = @($SourceDocument.LayoutOrder)
        FreeLines              = @()
        Warnings               = @()
        CanRoundTripStructured = $true
    }
}

function Copy-TemplateItemToWorkspace {
    param(
        [Parameter(Mandatory)]$Selection,
        [string]$ForcedMode
    )

    $selectedMode = if ($ForcedMode) { $ForcedMode } else { [string]$Selection.Mode }
    if ($selectedMode -eq 'Gameplay Prompts') {
        $targetFolder = Get-CurrentMandatoryTargetFolder
        Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetFolder

        $sourceInfo = Read-TextFileDetailed -Path $Selection.Node.Path
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Selection.Node.DisplayName) + '_copy'
        $extension = [System.IO.Path]::GetExtension($Selection.Node.DisplayName)
        $targetName = Get-UniqueFileName -ParentPath $targetFolder -BaseName $baseName -Extension $extension
        $targetPath = Join-Path $targetFolder $targetName
        Write-TextFileDetailed -Path $targetPath -Content $sourceInfo.Content -FileProfile $sourceInfo

        $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Gameplay Prompts'
        Refresh-Tree -PreserveState -RevealRelativePath ($targetPath.Substring($modeRoot.Length).TrimStart('\'))
        Open-TreeNode -Node ([pscustomobject]@{
            Kind         = 'MandatoryFile'
            Path         = $targetPath
            RelativePath = $targetPath.Substring($modeRoot.Length).TrimStart('\')
        })
        Set-Dirty -Value $true
        Set-Status -Text "Created template copy: $targetPath"
        return
    }

    $sourceContent = [System.IO.File]::ReadAllText($Selection.Node.Path)
    $sourceDocument = Parse-EntityDocument -Content $sourceContent
    if (-not $sourceDocument.CanRoundTripStructured) {
        throw 'The selected template entity is not compatible with structured copying.'
    }

    $sourceCategory = [string]$sourceDocument.Header['Category']
    $target = Get-ContentCreationTarget -PreferredCategoryName $sourceCategory
    if (-not $target -or -not (Test-Path -LiteralPath $target.RootPath -PathType Container)) {
        throw 'Unable to resolve a target content folder for the template copy.'
    }

    if (-not $target.IsCustomRoot -and $Controls.NewCategoryCombo.Items.Contains($sourceCategory)) {
        $Controls.NewCategoryCombo.SelectedItem = $sourceCategory
    }

    $sourceFolderName = if ($sourceDocument.Header.Contains('Name') -and $sourceDocument.Header['Name']) { [string]$sourceDocument.Header['Name'] } else { $Selection.Node.DisplayName }
    $sourceId = if ($sourceDocument.Header.Contains('Id') -and $sourceDocument.Header['Id']) { [string]$sourceDocument.Header['Id'] } else { $sourceFolderName }
    $sourceDisplayName = if ($sourceDocument.Fields.Contains('display_name') -and $sourceDocument.Fields['display_name']) { [string]$sourceDocument.Fields['display_name'] } else { $sourceFolderName }
    $folderName = Get-UniqueFolderName -ParentPath $target.RootPath -BaseName (ConvertTo-Slug -Text ($sourceFolderName + '_copy'))
    $entryId = ConvertTo-Slug -Text ($sourceId + '_copy')
    $displayName = $sourceDisplayName + '_copy'
    $newEntity = Copy-EntityDocumentForNewEntry -SourceDocument $sourceDocument -Category $sourceCategory -FolderName $folderName -DisplayName $displayName -EntryId $entryId

    $targetFolder = Join-Path $target.RootPath $folderName
    [System.IO.Directory]::CreateDirectory($targetFolder) | Out-Null
    $targetPath = Join-Path $targetFolder 'entity.txt'
    $newEntityProfile = [pscustomobject]@{ NewLine = [Environment]::NewLine; Encoding = (New-Utf8Encoding); HasUtf8Bom = $false }
    Write-TextFileDetailed -Path $targetPath -Content (Render-EntityDocument -Document $newEntity) -FileProfile $newEntityProfile

    $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
    Refresh-Tree -PreserveState -RevealRelativePath ($targetPath.Substring($modeRoot.Length).TrimStart('\'))
    Open-TreeNode -Node ([pscustomobject]@{
        Kind         = 'EntityFile'
        DisplayName  = $folderName
        Path         = $targetPath
        RelativePath = $targetPath.Substring($modeRoot.Length).TrimStart('\')
        CategoryName = $sourceCategory
        FolderPath   = $targetFolder
    })
    Set-Dirty -Value $true
    Set-Status -Text "Created template copy: $targetPath"
}

function Get-CurrentMandatoryTargetFolder {
    $selected = Get-SelectedTreeNodeData
    $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Gameplay Prompts'
    if ($selected) {
        switch ($selected.Kind) {
            'MandatoryFile' { return (Split-Path -Path $selected.Path -Parent) }
            'Folder' { return $selected.Path }
        }
    }
    return $modeRoot
}

function Get-NextMandatoryFileName {
    param([Parameter(Mandatory)][string]$TargetFolder)

    $existing = Get-ChildItem -LiteralPath $TargetFolder -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $numbers = foreach ($name in $existing) {
        if ($name -match '^(\d+)_') {
            [int]$matches[1]
        }
    }
    $next = if ($numbers) { (($numbers | Measure-Object -Maximum).Maximum + 1) } else { 1 }
    return ('{0}_new_prompt.txt' -f $next)
}

function Get-SiblingTemplateDocument {
    param(
        [Parameter(Mandatory)][string]$CategoryRoot,
        [Parameter(Mandatory)][string]$TemplateModeRoot
    )

    $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
    $relative = $CategoryRoot.Substring($modeRoot.Length).TrimStart('\')
    $templateCategory = Join-Path $TemplateModeRoot $relative
    $templateDocument = Get-FirstEntityDocumentFromRoot -RootPath $templateCategory
    $campaignDocument = Get-FirstEntityDocumentFromRoot -RootPath $CategoryRoot
    if ($templateDocument) {
        return $templateDocument
    }

    return $campaignDocument
}

function Delete-CurrentDocument {
    if (-not $script:State.CurrentDocument -or -not $script:State.ModContext) {
        return
    }

    $doc = $script:State.CurrentDocument
    switch ($doc.Type) {
        'Mandatory' {
            $targetPath = $doc.Path
            Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetPath
            $result = Show-Message -Message ("Delete prompt file '{0}'?" -f $doc.RelativePath) -Buttons YesNo -Icon Warning
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
            [System.IO.File]::Delete($targetPath)
            $script:State.CurrentDocument = $null
            Show-EmptyEditor
            Refresh-Tree -PreserveState
            Set-Dirty -Value $false
            Set-Status -Text "Deleted: $targetPath"
        }
        { $_ -in @('EntityRaw', 'EntityStructured') } {
            $targetFolder = Split-Path -Path $doc.Path -Parent
            Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetFolder
            $result = Show-Message -Message ("Delete entry '{0}'?" -f $doc.RelativePath) -Buttons YesNo -Icon Warning
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
            Remove-Item -LiteralPath $targetFolder -Recurse -Force
            $script:State.CurrentDocument = $null
            Show-EmptyEditor
            Refresh-Tree -PreserveState
            Set-Dirty -Value $false
            Set-Status -Text "Deleted: $targetFolder"
        }
    }
}

function Save-CurrentDocument {
    param([switch]$SaveAs)

    if (-not $script:State.CurrentDocument -or -not $script:State.ModContext) {
        return
    }

    $doc = $script:State.CurrentDocument
    $targetPath = $doc.Path

    if ($SaveAs) {
        if ($doc.Type -eq 'Mandatory') {
            $folder = Split-Path -Path $doc.Path -Parent
            $default = [System.IO.Path]::GetFileName($doc.Path)
            $newName = Show-TextEntryDialog -Title 'Save Prompt As' -Prompt 'Enter the new prompt filename.' -DefaultValue $default
            if (-not $newName) {
                return
            }
            $targetPath = Join-Path $folder $newName.Trim()
            if ((Test-Path -LiteralPath $targetPath) -and -not $targetPath.Equals($doc.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                Show-Message -Message 'That prompt file already exists.' -Icon Warning | Out-Null
                return
            }
        }
        else {
            $currentFolder = Split-Path -Path $doc.Path -Parent
            $parentFolder = Split-Path -Path $currentFolder -Parent
            $dialog = Show-NewEntityDialog -Title 'Save Entity As' -Category $doc.Entity.Header['Category'] -FolderName (Split-Path -Path $currentFolder -Leaf) -DisplayName $doc.Entity.Fields['display_name'] -EntryId $doc.Entity.Header['Id']
            if (-not $dialog) {
                return
            }
            $newFolder = Join-Path $parentFolder $dialog.FolderName
            Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $newFolder
            $targetPath = Join-Path $newFolder 'entity.txt'
            if ((Test-Path -LiteralPath $targetPath) -and -not $targetPath.Equals($doc.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                Show-Message -Message 'That entity already exists.' -Icon Warning | Out-Null
                return
            }
            [System.IO.Directory]::CreateDirectory($newFolder) | Out-Null
            if ($doc.Type -eq 'EntityStructured') {
                $doc.Entity.Header['Name'] = $dialog.FolderName
                $doc.Entity.Header['Id'] = $dialog.EntryId
                if ($doc.Entity.Fields.Contains('display_name')) {
                    $doc.Entity.Fields['display_name'] = $dialog.DisplayName
                }
            }
        }
    }

    Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetPath
    $content = Get-CurrentEditorText
    $outputProfile = if ($doc.FileProfile) { $doc.FileProfile } else { [pscustomobject]@{ NewLine = [Environment]::NewLine; Encoding = (New-Utf8Encoding); HasUtf8Bom = $false } }
    Write-TextFileDetailed -Path $targetPath -Content $content -FileProfile $outputProfile

    if ($SaveAs) {
        Refresh-Tree -PreserveState
    }

    $doc.Path = $targetPath
    $doc.RelativePath = $targetPath.Substring((Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode $script:State.CurrentMode).Length).TrimStart('\')
    Set-Dirty -Value $false
    Set-Status -Text "Saved: $targetPath"
    Update-PreviewAndReference
}

function New-Document {
    if (-not $script:State.ModContext) {
        return
    }

    if (-not (Confirm-DiscardChanges)) {
        return
    }

    if ($script:State.CurrentMode -eq 'Gameplay Prompts') {
        $targetFolder = Get-CurrentMandatoryTargetFolder
        Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetFolder
        $defaultName = Get-NextMandatoryFileName -TargetFolder $targetFolder
        $fileName = Show-TextEntryDialog -Title 'New Prompt File' -Prompt 'Enter the filename for the new prompt.' -DefaultValue $defaultName
        if (-not $fileName) {
            return
        }
        $targetPath = Join-Path $targetFolder $fileName.Trim()
        if (Test-Path -LiteralPath $targetPath) {
            Show-Message -Message 'That file already exists.' -Icon Warning | Out-Null
            return
        }

        $sibling = Get-ChildItem -LiteralPath $targetFolder -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
        $newFileProfile = if ($sibling) { Read-TextFileDetailed -Path $sibling.FullName } else { [pscustomobject]@{ Content = ''; NewLine = [Environment]::NewLine; Encoding = (New-Utf8Encoding); HasUtf8Bom = $false } }
        Write-TextFileDetailed -Path $targetPath -Content '' -FileProfile $newFileProfile
        Refresh-Tree -PreserveState -RevealRelativePath ($targetPath.Substring((Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Gameplay Prompts').Length).TrimStart('\'))
        Open-TreeNode -Node ([pscustomobject]@{
            Kind         = 'MandatoryFile'
            Path         = $targetPath
            RelativePath = $targetPath.Substring((Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Gameplay Prompts').Length).TrimStart('\')
        })
        Set-Dirty -Value $true
        Set-Status -Text "Created new prompt file: $targetPath"
    }
    else {
        $creationTarget = Get-ContentCreationTarget
        if (-not $creationTarget -or -not (Test-Path -LiteralPath $creationTarget.RootPath -PathType Container)) {
            Show-Message -Message 'Choose a category to create the new entry in.' -Icon Warning | Out-Null
            return
        }

        $modeRoot = Get-ModeRootPath -Context $script:State.ModContext -Campaign $script:State.CurrentCampaign -Mode 'Content Prompts'
        $categoryRoot = $creationTarget.RootPath
        $category = $creationTarget.CategoryName
        if (-not $category) {
            Show-Message -Message 'Select a concrete category folder inside categories.' -Icon Warning | Out-Null
            return
        }

        $dialog = Show-NewEntityDialog -Title 'New Entity' -Category $category
        if (-not $dialog) {
            return
        }
        if ($dialog.Action -eq 'CreateFromTemplate') {
            $selection = Show-TemplatePickerDialog -Context $script:State.ModContext -InitialMode 'Content Prompts'
            if (-not $selection) {
                return
            }
            Copy-TemplateItemToWorkspace -Selection $selection
            return
        }

        $targetFolder = Join-Path $categoryRoot $dialog.FolderName
        Assert-ChildPath -RootPath $script:State.ModContext.ModRoot -CandidatePath $targetFolder
        if (Test-Path -LiteralPath $targetFolder) {
            Show-Message -Message 'That entity folder already exists.' -Icon Warning | Out-Null
            return
        }
        [System.IO.Directory]::CreateDirectory($targetFolder) | Out-Null
        $targetPath = Join-Path $targetFolder 'entity.txt'

        $templateRoot = Get-TemplateModeRootPath -Context $script:State.ModContext -Mode 'Content Prompts'
        $builtinCategoryRoot = Join-Path $modeRoot $category
        $templateCategoryRoot = Join-Path $templateRoot $category
        $prototypeDocument = if ($creationTarget.IsCustomRoot) {
            $customPrototype = Get-FirstEntityDocumentFromRoot -RootPath $categoryRoot
            if ($customPrototype) {
                $customPrototype
            }
            elseif (Test-Path -LiteralPath $templateCategoryRoot -PathType Container) {
                Get-FirstEntityDocumentFromRoot -RootPath $templateCategoryRoot
            }
            else {
                Get-FirstEntityDocumentFromRoot -RootPath $builtinCategoryRoot
            }
        }
        else {
            $templatePrototype = if (Test-Path -LiteralPath $templateCategoryRoot -PathType Container) {
                Get-FirstEntityDocumentFromRoot -RootPath $templateCategoryRoot
            }
            else {
                $null
            }
            if ($templatePrototype) {
                $templatePrototype
            }
            else {
                Get-FirstEntityDocumentFromRoot -RootPath $builtinCategoryRoot
            }
        }
        $newEntity = New-EntityDocumentFromTemplate -Category $category -FolderName $dialog.FolderName -DisplayName $dialog.DisplayName -EntryId $dialog.EntryId -TemplateDocument $prototypeDocument
        $content = Render-EntityDocument -Document $newEntity
        $newEntityProfile = [pscustomobject]@{ NewLine = [Environment]::NewLine; Encoding = (New-Utf8Encoding); HasUtf8Bom = $false }
        Write-TextFileDetailed -Path $targetPath -Content $content -FileProfile $newEntityProfile
        Refresh-Tree -PreserveState -RevealRelativePath ($targetPath.Substring($modeRoot.Length).TrimStart('\'))
        Open-TreeNode -Node ([pscustomobject]@{
            Kind         = 'EntityFile'
            DisplayName  = $dialog.FolderName
            Path         = $targetPath
            RelativePath = $targetPath.Substring($modeRoot.Length).TrimStart('\')
            CategoryName = $category
            FolderPath   = $targetFolder
        })
        Set-Dirty -Value $true
        Set-Status -Text "Created new entity: $targetPath"
    }
}

function Generate-AiDraft {
    if (-not $script:State.ModContext -or -not $script:State.CurrentDocument) {
        return
    }

    $modelKey = if ($Controls.ModelCombo.SelectedItem) { [string]$Controls.ModelCombo.SelectedItem } else { $script:State.ModContext.ActiveModel }
    $currentText = Get-CurrentEditorText
    $referenceText = Get-ReferenceTextForDocument -Context $script:State.ModContext -Document $script:State.CurrentDocument -Mode $script:State.CurrentMode -UseTemplate:$Controls.TemplateReferenceCheckBox.IsChecked
    $instructions = $Controls.AiInstructionsBox.Text.Trim()

    if (-not $instructions) {
        $instructions = 'Improve or generate the selected entry while keeping it consistent with Sentient Sands and Kenshi.'
    }

    try {
        Set-Status -Text "Generating AI draft with model '$modelKey'..."
        $draft = Invoke-AiDraft -Context $script:State.ModContext -Document $script:State.CurrentDocument -ModelKey $modelKey -CurrentText $currentText -ReferenceText $referenceText -UserInstructions $instructions
        $Controls.AiDraftTextBox.Text = $draft
        Set-Status -Text "AI draft generated with model '$modelKey'."
    }
    catch {
        $Controls.AiDraftTextBox.Text = ''
        Set-Status -Text "AI draft failed: $($_.Exception.Message)"
        Show-Message -Message $_.Exception.Message -Icon Error | Out-Null
    }
}

function Apply-AiDraft {
    $draft = $Controls.AiDraftTextBox.Text
    if (-not $draft.Trim()) {
        return
    }
    if (-not $script:State.CurrentDocument) {
        return
    }

    switch ($script:State.CurrentDocument.Type) {
        'Mandatory' {
            $Controls.MandatoryEditor.Text = $draft
        }
        'EntityRaw' {
            $Controls.RawEntityEditor.Text = $draft
        }
        'EntityStructured' {
            $parsed = Parse-EntityDocument -Content $draft
            if ($parsed.CanRoundTripStructured) {
                $script:State.CurrentDocument.Entity = $parsed
                Render-StructuredEditor
            }
            else {
                Show-Message -Message 'The AI draft does not round-trip as a structured entity. It will be applied to raw mode instead.' -Icon Warning | Out-Null
                $script:State.CurrentDocument.Type = 'EntityRaw'
                $Controls.StructuredEditorScroll.Visibility = 'Collapsed'
                $Controls.RawEntityEditor.Visibility = 'Visible'
                $Controls.RawEntityEditor.Text = $draft
                $Controls.EditorHeaderText.Text = "$($script:State.CurrentDocument.RelativePath)  [raw mode]"
            }
        }
    }

    Set-Dirty -Value $true
    Update-PreviewAndReference
    Set-Status -Text 'AI draft applied to the editor.'
}

$Controls.ModeCombo.Items.Add('Gameplay Prompts') | Out-Null
$Controls.ModeCombo.Items.Add('Content Prompts') | Out-Null
$Controls.ModeCombo.SelectedItem = 'Gameplay Prompts'

$Controls.OpenFolderButton.Add_Click({
    Invoke-UiAction -Context 'Open Mod Folder' -Action {
        $path = Show-FolderPicker -Description 'Select the extracted Sentient Sands mod root'
        if ($path) {
            Load-ModRoot -SelectedPath $path
        }
    }
})

$Controls.ImportZipButton.Add_Click({
    Invoke-UiAction -Context 'Import Zip' -Action {
        $zipPath = Show-OpenFilePicker -Title 'Select SentientSands.zip' -Filter 'Zip archives (*.zip)|*.zip'
        if (-not $zipPath) {
            return
        }

        $destination = Show-FolderPicker -Description 'Select the destination folder for extracting the mod'
        if (-not $destination) {
            return
        }

        $target = Join-Path $destination ([System.IO.Path]::GetFileNameWithoutExtension($zipPath))
        if (-not (Test-Path -LiteralPath $target)) {
            [System.IO.Directory]::CreateDirectory($target) | Out-Null
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $target -Force
        Load-ModRoot -SelectedPath $target
        Set-Status -Text "Imported zip into $target"
    }
})

$Controls.CampaignCombo.Add_SelectionChanged({
    if ($script:State.SuspendUiEvents) {
        return
    }
    if (-not $Controls.CampaignCombo.SelectedItem) {
        return
    }
    Invoke-UiAction -Context 'Campaign switch' -Action {
        if ($script:State.ModContext -and -not (Confirm-DiscardChanges)) {
            $script:State.SuspendUiEvents = $true
            try {
                $Controls.CampaignCombo.SelectedItem = $script:State.CurrentCampaign
            }
            finally {
                $script:State.SuspendUiEvents = $false
            }
            return
        }

        $script:State.CurrentCampaign = [string]$Controls.CampaignCombo.SelectedItem
        $script:State.CurrentDocument = $null
        Refresh-Tree
        Show-EmptyEditor
        Set-Dirty -Value $false
        if (Test-IsTemplateWorkspace -Campaign $script:State.CurrentCampaign) {
            Set-Status -Text "Switched to template workspace."
        }
        else {
            Set-Status -Text "Switched to campaign '$($script:State.CurrentCampaign)'."
        }
    }
})

$Controls.ModeCombo.Add_SelectionChanged({
    if ($script:State.SuspendUiEvents) {
        return
    }
    if (-not $Controls.ModeCombo.SelectedItem) {
        return
    }
    Invoke-UiAction -Context 'Mode switch' -Action {
        if ($script:State.ModContext -and -not (Confirm-DiscardChanges)) {
            $script:State.SuspendUiEvents = $true
            try {
                $Controls.ModeCombo.SelectedItem = $script:State.CurrentMode
            }
            finally {
                $script:State.SuspendUiEvents = $false
            }
            return
        }

        $script:State.CurrentMode = [string]$Controls.ModeCombo.SelectedItem
        $script:State.CurrentDocument = $null
        Refresh-Tree
        Show-EmptyEditor
        Set-Dirty -Value $false
        Set-Status -Text "Mode changed to '$($script:State.CurrentMode)'."
    }
})

$Controls.ProviderCombo.Add_SelectionChanged({
    if ($script:State.SuspendUiEvents) {
        return
    }
    Invoke-UiAction -Context 'Provider switch' -Action {
        $selectedProvider = [string]$Controls.ProviderCombo.SelectedItem
        $currentModel = if ($Controls.ModelCombo.SelectedItem) { [string]$Controls.ModelCombo.SelectedItem } else { '' }

        $script:State.SuspendUiEvents = $true
        try {
            $Controls.ModelCombo.Items.Clear()
            foreach ($modelKey in (Get-ModelKeysForProvider -Context $script:State.ModContext -ProviderKey $selectedProvider)) {
                [void]$Controls.ModelCombo.Items.Add($modelKey)
            }

            if ($currentModel -and $Controls.ModelCombo.Items.Contains($currentModel)) {
                $Controls.ModelCombo.SelectedItem = $currentModel
            }
            elseif ($Controls.ModelCombo.Items.Count -gt 0) {
                $Controls.ModelCombo.SelectedIndex = 0
            }
        }
        finally {
            $script:State.SuspendUiEvents = $false
        }
    }
})

$Controls.ModelCombo.Add_SelectionChanged({
    if ($script:State.SuspendUiEvents) {
        return
    }
    Invoke-UiAction -Context 'Model switch' -Action {
        $selectedModel = [string]$Controls.ModelCombo.SelectedItem
        if (-not $selectedModel) {
            return
        }

        $descriptor = Get-CurrentModelDescriptor -Context $script:State.ModContext -ModelKey $selectedModel
        if (-not $descriptor) {
            return
        }

        if (-not [string]::Equals([string]$Controls.ProviderCombo.SelectedItem, $descriptor.ProviderKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:State.SuspendUiEvents = $true
            try {
                $Controls.ProviderCombo.SelectedItem = $descriptor.ProviderKey
            }
            finally {
                $script:State.SuspendUiEvents = $false
            }
        }
    }
})

$Controls.SearchBox.Add_TextChanged({
    if ($script:State.SuspendUiEvents) {
        return
    }
    Invoke-UiAction -Context 'Search refresh' -Action {
        if ($script:State.ModContext) {
            Refresh-Tree -PreserveState
        }
    }
})

$Controls.PromptTree.Add_SelectedItemChanged({
    Invoke-UiAction -Context 'Open tree node' -Action {
        $node = Get-SelectedTreeNodeData
        if (-not $node) {
            return
        }
        if (-not (Confirm-DiscardChanges)) {
            return
        }
        Open-TreeNode -Node $node
    }
})

$Controls.MandatoryEditor.Add_TextChanged({
    if ($script:State.SuspendEditorEvents -or -not $script:State.CurrentDocument) {
        return
    }
    Set-Dirty -Value $true
    Update-PreviewAndReference
})

$Controls.RawEntityEditor.Add_TextChanged({
    if ($script:State.SuspendEditorEvents -or -not $script:State.CurrentDocument) {
        return
    }
    Set-Dirty -Value $true
    Update-PreviewAndReference
})

$Controls.TemplateReferenceCheckBox.Add_Click({
    Invoke-UiAction -Context 'Reference refresh' -Action {
        Update-PreviewAndReference
    }
})

$Controls.NewButton.Add_Click({
    Invoke-UiAction -Context 'Create document' -Action {
        New-Document
    }
})

$Controls.CreateFromTemplateButton.Add_Click({
    Invoke-UiAction -Context 'Create from template' -Action {
        if (-not $script:State.ModContext) {
            return
        }
        $selection = Show-TemplatePickerDialog -Context $script:State.ModContext -InitialMode $script:State.CurrentMode
        if ($selection) {
            Copy-TemplateItemToWorkspace -Selection $selection
        }
    }
})

$Controls.DeleteButton.Add_Click({
    Invoke-UiAction -Context 'Delete document' -Action {
        Delete-CurrentDocument
    }
})

$Controls.SaveButton.Add_Click({
    Invoke-UiAction -Context 'Save document' -Action {
        Save-CurrentDocument
    }
})

$Controls.SaveAsButton.Add_Click({
    Invoke-UiAction -Context 'Save document as' -Action {
        Save-CurrentDocument -SaveAs
    }
})

$Controls.GenerateButton.Add_Click({
    Invoke-UiAction -Context 'Generate AI draft' -Action {
        Generate-AiDraft
    }
})

$Controls.ApplyDraftButton.Add_Click({
    Invoke-UiAction -Context 'Apply AI draft' -Action {
        Apply-AiDraft
    }
})

$Controls.ExpandAllButton.Add_Click({
    Invoke-UiAction -Context 'Expand tree' -Action {
        Set-TreeExpansionState -Items $Controls.PromptTree.Items -Expanded:$true
    }
})

$Controls.CollapseAllButton.Add_Click({
    Invoke-UiAction -Context 'Collapse tree' -Action {
        Set-TreeExpansionState -Items $Controls.PromptTree.Items -Expanded:$false
    }
})

$Window.Add_Closing({
    if (-not (Confirm-DiscardChanges)) {
        $_.Cancel = $true
    }
})

Show-EmptyEditor
Populate-NewCategoryCombo
Update-WindowTitle

if ($InitialModRoot) {
    try {
        Load-ModRoot -SelectedPath $InitialModRoot
    }
    catch {
        Set-Status -Text $_.Exception.Message
    }
}

[void]$Window.ShowDialog()
