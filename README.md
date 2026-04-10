# Kenshi Prompt Explorer

`Kenshi Prompt Explorer` is a Windows PowerShell + WPF editor for the **Sentient Sands 0.32** with **KayakDB** AI mod for **Kenshi**.

It is built to make the mod's prompt and KayakDB data easier to browse, edit, duplicate, and generate without manually digging through the folder structure.

## What It Does

At a high level, the tool lets you:

- open Sentient Sands mod folder for database access
- switch between campaign data and the shared `Template` workspace
- edit `Gameplay Prompts` as plain text
- edit `Content Prompts` as structured Kayak `entity.txt` entries
- create new entries with the same field layout as real existing entries
- copy entries and prompt files from `Template` or from other campaigns
- preview the exact text that will be written to disk
- generate AI drafts using the provider and model configuration already defined by the mod

The goal is simple: make Sentient Sands content editing practical, fast, and safe.

## Main Features

- Campaign selector with a first-class `Template` workspace
- Searchable file tree
- Expand / Collapse controls for the explorer tree
- Plain-text editor for gameplay prompt files
- Structured editor for Kayak `entity.txt` files
- Raw fallback mode for malformed entries
- Exact output preview
- Reference tab with:
  - template reference mode
  - manual editable reference text mode
- `New`, `Save`, `Save As`, and `Delete`
- `From Template` copy flow for both gameplay prompts and content entries
- Content entry creation that clones the real field layout from existing category prototypes
- Safe path checks to prevent writes outside the opened mod root
- AI draft generation using the mod's own provider/model settings
- Provider selector and filtered model selector

## Quick Start

### 1. Prepare the mod folder

Use an extracted `SentientSands` mod folder that contains paths like:

```text
SentientSands/
  Kayak/KayakDB/
  server/config/models.json
  server/config/providers.json
```

### 2. Run the script

Easiest way: Right-click and select 'run with PowerShell'

Use the script that matches your PowerShell version:

```powershell
pwsh -STA -File .\KenshiPromptExplorerPS7.ps1
```

or:

```powershell
powershell.exe -STA -File .\KenshiPromptExplorerPS5.ps1
```

The scripts can also relaunch themselves in STA mode if needed.

### 3. Open the mod

- Click `Open Mod Folder`
- Select the extracted `SentientSands` folder
- Choose a campaign or select `Template`

### 4. Start editing

- Use `Gameplay Prompts` for mandatory text prompt files
- Use `Content Prompts` for Kayak category entries
- Select an item in the tree
- Edit it in the center pane
- Review the exact output in `Preview`
- Save when ready

## Workspaces and Folder Rules

The tool intentionally follows the current Kayak-backed Sentient Sands layout.

### Editable workspaces

- `Kayak\KayakDB\Campaigns\<campaign>\mandatory`
- `Kayak\KayakDB\Campaigns\<campaign>\categories`
- `Kayak\KayakDB\Template\mandatory`
- `Kayak\KayakDB\Template\categories`

### Ignored as legacy / non-live sources

- `server\campaigns`
- `Kayak\addons`

That means the tool edits the active KayakDB content, not the older leftover server campaign files.

## Editing Modes

## Gameplay Prompts

This mode edits plain text files under:

```text
mandatory
```

Typical examples are chat, biography, loremaster, and speech-related prompt sets.

These files are edited directly as text and saved with their existing file characteristics preserved as closely as possible.

## Content Prompts

This mode edits structured Kayak content entries under:

```text
categories\<category>\<entry>\entity.txt
```

The structured editor understands the standard format:

- header lines:
  - `Category = ...`
  - `Name = ...`
  - `Id = ...`
- normal key/value fields
- prose fields with `$`

If an entry cannot be safely round-tripped as structured data, the tool automatically falls back to raw text mode.

## Creating and Copying Content

### New content entries

When you create a new content entry, the tool does not invent a schema from scratch. It clones the field inventory, ordering, and prose metadata from a real existing prototype entry for that category, then blanks the values for the new item.

This keeps new entries consistent with the way real Sentient Sands data is already structured.

### From Template

The `From Template` action works for both content entries and gameplay prompts.

You can copy from:

- `Template`
- other campaigns

The picker includes:

- source workspace selection
- gameplay/content mode selection
- searchable tree navigation

For content entries, the copied entry is created in the current target workspace as a renamed copy such as:

```text
originalname_copy
```

For gameplay prompts, the selected prompt file is copied into the current target prompt folder with a safe `_copy` style name.

## Reference Tab

The `Reference` tab has two modes.

### Use Template Reference enabled

The tool shows the template reference for the current document. This is useful when you want a fixed example from the shared template set.

### Use Template Reference disabled

The reference box becomes an editable text area. You can type or paste your own notes, constraints, examples, or temporary context there.

That manual reference text is also used by AI draft generation.

## AI Draft Generation

The tool can generate drafts for:

- gameplay prompt files
- content `entity.txt` entries

It reads the provider/model setup from the mod itself:

- `server/config/providers.json`
- `server/config/models.json`
- active model from `config_master.txt`
- fallback from `SentientSands_Config.ini`

The AI flow:

- takes the current document
- takes either template reference text or your manual reference text
- uses the selected model
- sends an OpenAI-compatible `chat/completions` request
- shows the draft in a preview pane first
- applies it only if you choose to

The tool does not silently overwrite content.

## Template Workspace

`Template` is a full editing workspace, not just a reference source.

You can:

- browse template gameplay prompts
- browse template content entries
- edit and save template files directly
- create new template entries
- copy template items into Template itself or into campaigns

This is useful when you want to maintain the shared base content used across campaigns.

## Technical Notes

### Content parsing

Structured editing follows the real parser assumptions used by the tool:

- the first three reserved lines are `Category`, `Name`, and `Id`
- key/value forms such as `=`, `:`, and `->` are accepted during parsing
- prose fields are tracked through `$` metadata
- unsupported free text forces raw mode instead of destructive rewriting

### Save behavior

- gameplay prompt files are treated as text files
- content entries are rendered back into a stable structured format
- writes are restricted to the selected mod root
- unsaved-change prompts help prevent accidental loss

### Tree behavior

- content trees start collapsed by default
- tree state is preserved during normal refresh operations where possible
- search filters the currently selected workspace and mode

## Requirements

- Windows
- PowerShell 5.1 or PowerShell 7
- desktop environment with WPF support
- extracted Sentient Sands mod folder
- valid provider/API setup only if you want AI drafting

## Known Limitations

- Windows-only GUI
- no engine-side or DLL-side editing
- AI generation depends entirely on valid provider configuration
- malformed files may require raw editing
- this tool edits on-disk content only

## Safety Notes

- The tool is designed to write only inside the selected mod root
- It warns about unsaved changes
- It ignores `server\campaigns` on purpose
- It previews exact output before save
- AI drafts are previewed before they are applied

## Included Scripts

```text
KenshiPromptExplorerPS5.ps1
KenshiPromptExplorerPS7.ps1
```

Use the PS5 version for Windows PowerShell 5.1 and the PS7 version for PowerShell 7.

## Disclaimer

This project is an external editor for Sentient Sands data. It is not Kenshi itself and does not replace the original mod or its compiled game-side components.

## Known Issues

- "Create from template" button in "Create new entity" windows broken and obsolete. Use "From Template" in main window.

## Changelog

v1.5

- updated for SentientSands-v0.32
- dialogue and stats tab added for entities

v1.4

- reworked 'Reference' system, now allows user input
- fixed ai draft apply for custom entities

v1.3

- Template folder can now be edited
- Added 'Create from template' with search
- Reordered upper menu ui

v1.2

- cleaned some dirty code fragments

v1.1

- fixed failed creation of new custom fields
- fixed explorer tree in content prompts always expanded
- added Expand/Collapse all button
- added default custom fields when creating a new entry
- new entry selection via drop down
- added option to delete entries
