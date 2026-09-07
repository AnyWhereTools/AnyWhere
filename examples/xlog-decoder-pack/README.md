# Xlog Decoder for AnyWhere

English · [简体中文](README.zh.md) · [Back to home](../../README.md)

A Finder action following the [AnyWhere pack specification](../../docs/pack-spec.md).
It includes the standalone Rust CLI `bin/xlog-decoder`; **XlogDecoder.app is not required**.
No private key is bundled. The script locates the CLI relative to itself, so preserve the
`actions/` and `bin/` directory layout when moving the pack.

The CLI was extracted from XlogDecoder 1.3.1. It includes Intel (`x86_64`) and Apple Silicon
(`arm64`) architectures and links only to macOS system libraries, without Flutter or app frameworks.

## Usage

1. Save the entire pack folder locally and retain the executable permission on `bin/xlog-decoder`.
2. In AnyWhere → **Extension Packs → Import → Choose Local Folder…**, select this folder
   containing `manifest.json`. Review the script and bundled CLI, confirm, then enable **解密 Xlog**.
   No Git repository is needed.
3. Select the action under **Context Menu**, enter the decryption key in **Plugin Configuration**
   and click **Save Configuration**. Leave it blank for unencrypted logs. Subsequent runs use
   the saved key without an input dialog.
4. Select `.xlog` files in Finder. Output is saved beside each input: `sample.xlog` → `sample.log`.
   Existing outputs are preserved by choosing `sample 2.log`, `sample 3.log`, and so on.

You can also publish this folder as its own Git repository, keeping `manifest.json` at the
root, then import its URL through the regular pack review flow.

Local import copies the whole pack; moving the source does not affect installed actions.
Local packs do not check Git updates. Duplicate imports from the same folder are rejected;
uninstall the existing pack before reimporting a replacement.

When running the script in Terminal, supply its configuration environment variable yourself
(AnyWhere injects this automatically):

```sh
ANYWHERE_CONFIG_PRIVATE_KEY="<private-key>" /bin/zsh actions/decode-xlog.zsh "/absolute/path/sample.xlog"
```

Or call the CLI directly, omitting `-p` for unencrypted logs:

```sh
./bin/xlog-decoder decode -i "/absolute/path/sample.xlog" -o "/absolute/path/sample.log" -p "<private-key>"
```

Direct CLI invocation does not include the wrapper's output checks or automatic output numbering.

To change the key, edit and save the action's configuration, or choose **Clear Configuration**.
After upgrading from the old version, enter and save the key once again. The new version neither
reads nor deletes old Keychain entries and does not request Keychain authorization.
This pack uses **schemaVersion 3**, requiring a client with plugin configuration and suffix matching.

## Manifest and configuration

- `targets: "files"` and `extensions: ["xlog"]` match files only, ignoring case, without a dynamic UTI.
- `PRIVATE_KEY` is a `password` setting: masked in the UI, saved once and reused. It is optional for unencrypted logs.
- No `filenamePattern` is declared, so file prefixes are unrestricted. To restrict naming, add
  `"filenamePattern": "device-.*\\.xlog"` to the source action and reimport. Regex matches the
  whole filename and ignores case by default.
- Configuration lives outside the pack. Reimporting the same source can reuse it; clear
  configuration before uninstalling if you want to remove the saved key.

See the [pack specification](../../docs/pack-spec.md) for filter combinations, version compatibility
and the four configuration controls.

## Behavior and limits

- Inputs arrive through `"$@"`, supporting spaces, Chinese filenames and multi-selection.
  The `.xlog` suffix is case-insensitive.
- The menu action appears only when every selected item is an `.xlog` file. It is independent
  of the UTI registered on each Mac. The script also checks every input is readable before decoding.
- AnyWhere encrypts the key locally with AES-256-GCM in `PrivateData/`, isolated by action.
  The script reads `ANYWHERE_CONFIG_PRIVATE_KEY`; it does not use Keychain. The key is excluded
  from the pack and ordinary configuration files, and literal key echoes are masked in execution
  output. The decoder CLI still receives the key through its `-p` argument.
- Backups require both `PrivateData/key` and `PrivateData/secrets.enc`; ciphertext without the key cannot be restored.
- Temporary directories and output default to current-user access only. Results are first written
  to a temporary file, then saved only when the decoder exits successfully and output is nonempty.
  Original files are preserved.
- Failure returns nonzero and writes to stderr. Successful outputs from a partially failed batch
  are retained. Success writes a first-line stdout summary; the batch timeout is 600 seconds.
- The script does not reimplement decryption or verify log completeness. Recovery of damaged logs
  depends on the bundled decoder; nonempty output does not prove every record was recovered.
