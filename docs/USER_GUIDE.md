# Hexa user guide

## Start exploring

Launch Hexa to open `Welcome.bin`, a bundled sample with readable text, byte patterns, and example bookmarks. Editing the sample never modifies the bundled resource. Save opens a panel so you can save your own copy. **File → New** creates an empty document. **⌘O** opens any regular file; drag files onto the grid or use Finder → Open With → Hexa. Each document has its own selection, editing mode, undo history, and analysis.

Use **Bytes / Structure / Analysis** below the toolbar, or **⌘1 / ⌘2 / ⌘3**, to switch workspaces. In Bytes, the left sidebar contains Bookmarks, Search, Compare, and Strings. The center shows offsets, hex bytes, and one character per byte. The right inspector interprets bytes at the current offset. The status bar reports the exact file size, offset, selection length, encoding, and row width.

Hide either panel with the toolbar’s sidebar buttons when you want more room. View settings persist across launches. macOS can group document windows as native tabs according to its window-tabbing preferences.

## Select and navigate

- Click a byte in either the hex or text column. The other column highlights the same bytes.
- Drag to select; dragging beyond the visible grid scrolls the document.
- Shift-click or Shift-arrow extends the selection. Double-click selects a row; triple-click selects all bytes.
- Arrow keys move one byte or row. Page Up / Down move one visible page. Home / End go to file boundaries. ⌘Left / Right move to row boundaries; ⌘Up / Down move to file boundaries.
- **⌘L** opens Go to Offset. Enter `256`, `0x100`, `+16`, or `-0x20`. Relative offsets use the current selection start. Underscores are allowed in numbers.
- **⇧⌘L** opens Select Range. Enter a start offset and byte count. The end offset must stay inside the file.
- The empty cell at the end of the file is a valid insertion position.

## Edit safely and predictably

Click the grid before typing. **Tab** switches between hex and text entry; Return also switches the active pane.

In the hex pane, type **two hexadecimal digits** per byte. The first digit is a pending preview; the second commits the byte as one undoable edit and advances the caret. Escape, moving the selection, leaving the grid, or saving cancels an incomplete byte. A single digit is never silently written to disk.

In the text pane, text is encoded using the encoding selected in the status bar or inspector. UTF-8 is the default. ASCII rejects characters it cannot represent; UTF-16 uses the chosen byte order. The grid is deliberately byte-oriented: multibyte characters are decoded in the inspector preview, not across grid cells. Complex IME composition is not implemented in the grid; paste text or use Edit Bytes for that workflow.

The toolbar offers two editing modes:

| Selection | Overwrite | Insert |
| --- | --- | --- |
| One byte / caret | Replace existing bytes starting at the offset. Any bytes beyond EOF append. | Insert immediately before the byte at the offset. |
| More than one selected byte | Replace the entire selection with the typed/pasted value. | Replace the entire selection with the typed/pasted value. |
| Empty selection at EOF | Append. | Append. |

Hex entry produces one byte per pair of digits. Text entry, numeric writes, and paste may produce several bytes. A multi-byte selection can change length when replaced. **Delete** removes selected bytes and changes file size even in overwrite mode; at an empty caret, Backspace removes the preceding byte. Use Fill with `00` if you want to zero bytes without changing length.

**⌘Z** undoes, **⇧⌘Z** redoes. Fill, transformation, paste, and Replace All each form a single undo step. Undo history remains available after a save. The document becomes clean again when you undo/redo to its saved revision. Orange underlines mark bytes inserted or replaced **since opening**, including edits already saved.

The toolbar lock disables mutation while leaving viewing and copying available. Files that appear unwritable open locked. You can unlock and use Save As to create an editable copy. Analysis and file operations temporarily suspend editing so their results describe a consistent snapshot.

## Clipboard, fill, and transformations

- **⌘C** copies hex from the hex pane or text from the text pane. Hexa also places raw bytes on the clipboard, so copying within Hexa preserves exact bytes.
- Edit → Copy As exports hex, decoded text, an offset-annotated hex dump, a Swift array, or Base64.
- **⌘V** prefers Hexa’s raw clipboard bytes. For outside text, the active hex pane parses hexadecimal and the text pane encodes text.
- **⇧⌘V** always pastes as text. Text is encoded with the chosen encoding.
- Hex parsing accepts `DE AD BE EF`, `DEADBEEF`, `0xDE, 0xAD`, commas, whitespace, and underscores. A hex dump or Swift array with brackets is not paste-input syntax.
- **Edit → Edit Bytes** opens a multiline hexadecimal/text replacement dialog. It replaces exactly the selected range or inserts at an empty selection. The hex preview shows at most 4 KiB, with an explicit notice for larger selections.
- **Edit → Fill / Insert Pattern** repeats a hex pattern to fill exactly the selection length, or inserts a specified byte count. A partial final repetition is allowed.
- **Edit → Transform Selection** inverts bits, XORs with a repeated key, reverses bytes, or swaps byte order per 2/4/8-byte word. Swaps require a selection divisible by the word size.
- **File → Insert File** inserts file contents at the current offset, or replaces a selection of more than one byte.
- **File → Export Selection** streams the selected raw bytes to a new binary file.

## Find and replace

Press **⌘F**. Choose Hex or Text, enter a query, and click Find or press Return in the query field.

Hex examples:

| Query | Matches |
| --- | --- |
| `89 50 4E 47` | Exact PNG signature prefix |
| `DE AD ?? EF` | Any third byte |
| `A? ?F` | First byte starts with A; second byte ends with F |

Text search uses the selected encoding and is case-sensitive. Check Selection to restrict a search to the range currently selected when you run it. Search results appear in the sidebar and are highlighted in yellow. **⌘G** and **⇧⌘G** cycle through results, wrapping at the ends. Changing the query, format, encoding, or scope clears stale results. Edits also invalidate results.

Replace operates only on a selected search match and runs the query again afterward. Replace All uses the completed search results and applies one undoable transaction. Replacement hex does not allow wildcards. An empty replacement deletes matches. Searches include overlapping matches; Replace All takes disjoint matches from left to right. For example, searching `AA AA` in `AA AA AA` yields two matches, but Replace All replaces the first one and skips the overlap.

There is no regex engine or case-insensitive text mode. Use nibble/byte wildcards for byte-pattern matching. Search and replace are local; no document content leaves your Mac.

## Inspect and analyze

The Inspector reads from the selection’s first byte, even when only one byte is selected. A dash means too few bytes remain for a type. Toggle little/big endian to reinterpret integers and IEEE-754 Float32/Float64. It also shows the selected byte’s bits, octal and hex values, decoded text, and signed 32-bit Unix time in UTC.

Click a bit to toggle it as an undoable edit. **Write Numeric Value** validates the selected type, encodes it in the chosen byte order, and writes using the current editing mode. Unsigned integers accept decimal or `0x` hexadecimal; signed integers use decimal. Floating-point inputs accept Swift’s numeric syntax, including scientific notation.

Choose **Analysis (⌘3)** to open the full dashboard. Analyze File or Analyze Selection calculates entropy and byte types across the range, digram and layered distributions, byte frequencies, cryptographic constant matches, SHA-256, SHA-512, MD5, and CRC-32/ISO-HDLC. Expand Checksums & fingerprints to copy hashes. The compact right-hand Analysis inspector remains available in Bytes. MD5 and CRC are provided for compatibility and error checking, not cryptographic security.

Entropy ranges from 0 to 8 bits per byte. **Highest** is the maximum window entropy; **Average** weights each window by its byte count; **Global** comes from the entire analyzed range's byte histogram. Windows contain at least 4 KiB, with at most 1,024 windows per scan and a possibly shorter final window. Click an entropy or byte-type window to select its bytes. Byte types are disjoint: zero, whitespace, printable ASCII excluding space, other ASCII controls, high bytes, and FF.

The **digram** heatmap counts adjacent byte pairs, with the preceding byte on X and following byte on Y. Click an occupied cell to select its first occurrence inside the analyzed range. The **layered** heatmap puts file position on X and byte value on Y; click to select a position bin. Both use logarithmic brightness so rare patterns remain visible. Hover for counts or offsets.

The dashboard identifies formats by magic bytes, shows MIME types, and includes a searchable **Signature Database** with 71 built-in rules. Recognized encryption/compression envelopes receive explicit labels. Otherwise average window entropy of at least 7.5, over at least 4 KiB, is labeled possibly compressed or encrypted. Random and multimedia data can also have high entropy; this is a heuristic, not proof. Cryptographic detection finds 20 exact signature variants from AES, SHA, MD5, ChaCha/Salsa, Blowfish, and CRC tables. Click a match to select it. Constants do not prove an algorithm is in use, and an empty result does not rule it out.

The Strings sidebar scans printable ASCII bytes (`0x20` through `0x7E`) with a configurable minimum length. Click a string to select its full byte range. Extraction is ASCII-only; use encoded text search for UTF-8/UTF-16 content. A string’s displayed preview is capped at 512 characters.

## Decode file structure

Choose **Structure (⌘2)** to explore PE32/PE32+, ELF32/ELF64, and thin or universal Mach-O. Files are recognized from their bytes. Expand the tree to inspect headers, segments, sections, and fields. Select a tree item to populate the table, then select a table row for its value, file offset, byte count, description, and hex preview. **Show in Bytes** reveals the selection in the editor. The three-lane colored map locates headers, segments/sections, and payloads; its regions are clickable. **Color fields** controls matching color overlays in the byte grid.

The Parser menu supports automatic recognition, explicit format selection, and raw interpretation. To inspect an embedded image, select its bytes in Bytes and choose **Tools → Decode Selection**. Format offsets are interpreted relative to that selection, while displayed file offsets remain absolute. Universal Mach-O slice offsets are handled independently. Memory-only ELF NOBITS and Mach-O zero-fill sections do not create nonexistent payload ranges.

Unknown bytes receive a raw tree with numeric interpretations in both byte orders, a text preview, and bounded chunks covering the selection. Arbitrary application-specific field meanings require a schema and are not inferred. Truncated or malformed formats show parsing notices and retain available decoded fields. Some payloads, including import/export and symbol records, remain opaque ranges. This is structural inspection, not disassembly, extraction, decompression, or executable validation.

Editing or undoing clears structure and analysis results. Reopen the workspace or use Decode / Analyze to refresh. These tools run on a consistent snapshot and support cancellation. Full format coverage and chart definitions are documented in `docs/STRUCTURE_AND_ANALYSIS.md` in the source project.

## Compare files

Choose **Tools → Compare with File**. Hexa compares bytes at the same offsets, highlights differences in pink, and lists contiguous changed ranges. Use the arrow buttons or **⌥⌘] / ⌥⌘[** for next/previous difference. The inspector shows up to 16 bytes from the comparison file at the current offset.

Comparison is **offset-aligned**, so an inserted byte may cause the remaining shifted bytes to differ; it does not attempt sequence alignment. If the other file has an extra tail, the difference list includes it and selecting it moves the current file to EOF. The inspector can display the other file’s bytes there. Editing invalidates the comparison; run it again for updated results.

## Bookmarks and saving

**⌘B** adds a named bookmark for the current offset/selection. Right-click a bookmark to rename or remove it. Bookmarks follow offsets when edits insert or delete bytes. They are stored locally in application preferences keyed by the full file path; they are not embedded in the binary or exported with it. Moving a file changes its bookmark identity. New documents acquire persistent bookmarks when saved to a path. Bookmarks are navigation preferences and do not mark a document dirty.

**⌘S** saves; **⇧⌘S** saves to another path. Save uses a sibling temporary file, streams its contents, synchronizes it, then atomically renames it over the destination. Existing POSIX file permissions are retained. The app checks the original file’s size, modification time, and identity before saving and again immediately before replacement. If they changed, Save refuses the overwrite; choose Save As or Revert to Saved.

Private file snapshots use APFS cloning when supported, with a normal file copy fallback, and memory mapping where safe. Outside edits cannot truncate the editor’s mapping. Unmodified data is shared across undo snapshots; inserted buffers remain in memory while referenced by undo history. Private snapshots are deleted when their last in-process reference is released. A forced termination can leave an OS temporary snapshot until temporary-folder cleanup.

Saving is explicit. Hexa does not autosave, keep crash-recovery drafts, or create backup/version-history files. Closing or quitting prompts to save dirty documents. Revert discards unsaved edits and undo history. Existing extended attributes, Finder tags, resource forks, hard-link relationships, and ACLs are not promised to survive replacement; use ordinary binary data files. Saving through a symlink path replaces the symlink entry. There is no atomic compare-and-swap against another process writing at precisely the final rename, so coordinate writers for shared files.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New / Open / Save | ⌘N / ⌘O / ⌘S |
| Save As | ⇧⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Paste as Text | ⇧⌘V |
| Select All | ⌘A |
| Edit Bytes | ⌘E |
| Export Selection | ⇧⌘E |
| Find / Next / Previous | ⌘F / ⌘G / ⇧⌘G |
| Go to Offset / Select Range | ⌘L / ⇧⌘L |
| Bookmark | ⌘B |
| Next / Previous Difference | ⌥⌘] / ⌥⌘[ |
| Toggle Sidebar / Inspector | ⌥⌘S / ⌥⌘I |
| Bytes / Structure / Analysis | ⌘1 / ⌘2 / ⌘3 |
| Zoom In / Out / Reset | ⌘+ / ⌘− / ⌘0 |
| Settings | ⌘, |
| Switch Hex / Text | Tab |
| Cancel pending hex digit | Escape |

## Limits and scope

The byte grid draws visible rows instead of creating a control for every byte, and search/analysis/save work in chunks on background tasks. This makes large-file viewing practical, but this release has not been benchmarked at multi-terabyte sizes. Full-file saves are proportional to file size. Very fragmented edit histories increase piece-table costs, and huge logical scroll heights eventually reach AppKit’s practical limits. Opening requires temporary disk space; non-APFS volumes may need a full file copy. A cancel request during an OS file copy takes effect after the copy completes.

| Operation | Limit |
| --- | --- |
| Clipboard / Edit Bytes input | 16 MiB |
| Fill / transform / Insert File | 64 MiB per operation |
| Search pattern | 1 MiB |
| Search results | 100,000 matches; truncation is indicated |
| Replace All | Disabled for truncated searches |
| Search / comparison visible sidebar | First 2,000 entries; navigation covers all retained entries |
| Comparison ranges | 100,000 retained ranges; total differing bytes still counted |
| Extracted ASCII strings | 10,000; truncation is indicated |
| Inspector text preview | 256 bytes |
| Structure | 4,096 entries per table, 4,096 load commands, 64 universal slices, 30,000 nodes; notices report limits |
| Raw interpretation | At most 128 chunks; previews do not copy entire payloads |
| Analysis windows / layered bins | At most 1,024 / 256; every byte is counted |
| Cryptographic matches | 2,000; truncation is indicated |
| Magic detection | First 64 KiB relative to the file or selection; built-in rules and subtype heuristics |

The scope is regular-file hexadecimal editing and structural analysis. Raw disks/process memory, disassembly, custom binary template languages, scripting/plugins, automatic file repair, regex search, and multi-file batch editing are not included. VoiceOver can read the grid’s selected-byte summary and standard inspector controls; the virtualized grid does not expose one accessibility element per byte. Heatmaps have textual labels and hover details, but no individual accessibility element for each of their 65,536 cells.
