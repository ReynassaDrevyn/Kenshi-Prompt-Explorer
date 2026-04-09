# Kenshi Prompt Explorer

`Kenshi Prompt Explorer` is a Windows PowerShell + WPF editor for the **Sentient Sands** AI mod for **Kenshi**.

It gives you a cleaner way to browse, edit, create, and AI-generate the prompt files and KayakDB content entries that drive the mod.

## What This Tool Does

If you just want the simple version:

- Open your extracted `SentientSands` mod folder
- Pick a campaign
- Switch between:
  - `Gameplay Prompts`
  - `Content Prompts`
- Browse files in a readable tree
- Edit them safely
- Save them back in place
- Create new prompt files or new content entries
- Optionally ask an AI to draft or rewrite entries using the same provider/model settings the mod already uses

This tool is meant to be easier than manually digging through folders and editing files in a text editor.

## Who It Is For

This project is useful for:

- players who want to tweak prompt behavior without digging through the whole mod by hand
- campaign authors who want to create or maintain their own content packs
- modders who want a structured editor for `entity.txt` content
- people who want to use AI to draft consistent entries faster

## Main Features

- Folder-first workflow for extracted Sentient Sands installs
- Zip import helper for `SentientSands.zip`
- Campaign selector
- Provider selector
- Model selector
- Searchable file tree
- Plain-text editing for gameplay prompt files
- Structured editing for Kayak `entity.txt` content
- Raw preview of the exact text that will be saved
- Read-only template/sibling reference pane
- New / Save / Save As flows
- AI draft generation using the mod's configured API provider and model
- Safe-path checks to prevent writing outside the selected mod root
- Raw fallback mode for malformed `entity.txt` files

## Quick Start

### 1. Prepare the mod

Use an **extracted** copy of the `SentientSands` mod folder.

The tool expects a folder containing paths like:

```text
SentientSands/
  Kayak/KayakDB/
  server/config/models.json
  server/config/providers.json
```

If you only have `SentientSands.zip`, the app can import and extract it for you.

### 2. Run the script

From PowerShell:

```powershell
pwsh -STA -File .\KenshiPromptExplorer.ps1
```

The script can also relaunch itself in STA mode automatically if needed.

### 3. Open your mod folder

- Click `Open Mod Folder`
- Select the extracted `SentientSands` folder
- Choose your campaign
- Choose a provider/model if you want to use AI drafting

### 4. Edit content

- Use `Gameplay Prompts` for the mod's mandatory prompt files
- Use `Content Prompts` for Kayak category entries such as characters, factions, locations, lore, and other structured content
- Click a file or entry in the left tree
- Edit it in the center pane
- Review exact output in the preview pane
- Save when ready

## Important Folder Rules

This tool intentionally follows the **real runtime source** used by the newer Sentient Sands + Kayak setup.

### Used as the editable source of truth

- `Kayak\KayakDB\Campaigns\<campaign>\mandatory`
- `Kayak\KayakDB\Campaigns\<campaign>\categories`

### Used as reference only

- `Kayak\KayakDB\Template`

### Intentionally not used as the live editing source

- `server\campaigns`
- `Kayak\addons`

That means if you edit old leftover data in `server\campaigns`, the tool will ignore it on purpose.

## Editing Modes

## Gameplay Prompts

This mode is for prompt text files under:

```text
Kayak\KayakDB\Campaigns\<campaign>\mandatory
```

These files are edited as plain text.

Typical prompt groups include:

- `Chat`
- `Biography`
- `Loremaster`
- `Speak`

## Content Prompts

This mode is for structured Kayak content entries under:

```text
Kayak\KayakDB\Campaigns\<campaign>\categories
```

Each entry usually lives in its own folder with an `entity.txt`.

The editor understands the common Sentient Sands / Kayak structure:

- reserved headers:
  - `Category`
  - `Name`
  - `Id`
- normal key/value fields
- prose fields using `$`

If a file does not safely round-trip as structured content, the tool falls back to raw text mode instead of rewriting it destructively.

## AI Draft Generation

The tool can generate drafts for:

- gameplay prompt files
- content `entity.txt` entries

It reads provider and model information from the mod itself:

- `server/config/providers.json`
- `server/config/models.json`
- active model from `config_master.txt`
- fallback from `SentientSands_Config.ini`

### What the AI feature does

- uses the selected provider and model
- sends an OpenAI-compatible `chat/completions` request
- uses the current document plus reference examples
- places the result into a draft preview first
- lets you apply the draft manually

### What it does not do

- it does not silently overwrite your file
- it does not change the mod's config files
- it does not expose API keys in the UI beyond what is needed to make the request

## For Non-Technical Users

If you are not interested in the internals, you mostly need to remember four things:

1. Open the extracted mod folder.
2. Pick the campaign you want to edit.
3. Use `Gameplay Prompts` for core behavior and `Content Prompts` for structured world/NPC data.
4. Always review the preview pane before saving.

## For Modders

This tool is built around the current Kayak-backed Sentient Sands layout.

### Content parser assumptions

Structured `entity.txt` editing follows the real Kayak parsing rules:

- first three reserved lines must be:
  - `Category = ...`
  - `Name = ...`
  - `Id = ...`
- body supports key/value formats such as:
  - `key = value`
  - `key: value`
  - `key -> value`
- prose fields use a `$` prefix
- unsupported free-text or malformed structures force raw mode

### Save behavior

- mandatory prompt files are treated as plain text
- `entity.txt` files are reconstructed in a stable order
- new entries use sibling/template structure when possible
- writes are restricted to the selected mod root

### Reference behavior

The right-hand reference pane can show:

- a template reference from `Kayak\KayakDB\Template`
- a sibling example from the same campaign/category

### Provider/model behavior

- provider dropdown is populated from `providers.json`
- model dropdown is populated from `models.json`
- model list is filtered by selected provider
- selected model drives AI generation requests

## Requirements

- Windows
- PowerShell 7 recommended
- WPF-capable desktop environment
- Extracted Sentient Sands mod folder
- API access only if you want to use AI drafting

## Known Limitations

- Windows-only GUI
- Not a replacement for engine-side or DLL-side mod changes
- AI generation depends entirely on valid provider configuration
- Malformed content can require raw editing instead of structured editing
- This tool edits files on disk; it does not patch the compiled game DLL

## Safety Notes

- The tool is designed to write only inside the selected mod root
- It warns about unsaved changes
- It does not use `server\campaigns` as a live source
- It keeps template data read-only inside the UI
- There may be bugs

## Disclaimer

This project is an external editor for Sentient Sands content. It is not Kenshi itself and is not a replacement for the original mod.

## Changelog

v1.4

- Reference system reworked, can now use entity data or user input

v1.3

- Template folder can now be edited
- Added 'Create from template' with search
- Reordered upper menu ui

v1.2

- Cleaned some dirty code fragments

v1.1

- fixed failed creation of new custom fields
- fixed explorer tree in content prompts always expanded
- Added Expand/Collapse all button
- Added default custom fields when creating a new entry
- New entry selection via drop down
- Added option to delete entries
