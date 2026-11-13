# CloudKit schema for Prompter

This is a written description, not a `cktool` schema file. The `.ckdb` format that `cktool import-schema` reads could
not be checked here: `cktool validate-schema` needs a signed-in team and a container, and none exists yet. Once the
container exists, create the record type in the CloudKit Dashboard (development environment), run
`xcrun cktool export-schema`, and commit the result as `schema.ckdb`. The code that reads and writes these records is
`Core/Sync/CloudRecordMapping.swift`.

- Container: `iCloud.<bundle id prefix>.prompter`. Private database only. No public or shared database.
- Zone: `Scripts` (a custom zone, created by the app on first launch).
- Record type: `Script`. One record per script. The record name is the script's UUID string.

| Field | Type | Encrypted | Meaning |
|---|---|---|---|
| `title` | String | yes | Script title. Live scripts only. |
| `body` | String | yes | Script text, when title plus body are 500,000 bytes of UTF-8 or less. Absent when `bodyAsset` is used. |
| `bodyAsset` | Asset | not confirmed (see below) | Script text as a UTF-8 file, when title plus body are more than 500,000 bytes. |
| `createdAt` | Double | no | Seconds since 1970, exactly `Script.createdAt`. Live scripts only. |
| `updatedAt` | Double | no | Seconds since 1970, exactly `Script.updatedAt`. Live scripts only. |
| `clock` | Double | no | The sync clock of this version (milliseconds-precise seconds since 1970). For a deletion it is the time of the deletion. |
| `deleted` | Int64 | no | 1 for a deletion, 0 for a live script. |
| `digest` | String | yes | `SyncDigest.of(script)`, live scripts only. The reader recomputes it and drops the record if it differs. Encrypted so a reader of the server can't test guesses against the text. |

Rules:

- A deletion keeps its record with `deleted` = 1 and its `clock`. Its title, body, asset, dates and digest are set to nil, also on a record that already had them.
- Dates are Doubles on purpose. The digest uses whole seconds, and a server that rounded a Date to the millisecond could
  change them.
- A reader ignores fields it doesn't know, so later versions can add fields.
- Assets: whether CloudKit encrypts an asset's file end to end the way it does `encryptedValues` is not confirmed. As far
  as we know, assets are encrypted at rest but only end to end with Advanced Data Protection. The Dashboard can't show
  this. Check it against Apple's CloudKit and Advanced Data Protection documentation before launch. If assets are not end
  to end, the large-body path has to encrypt the file itself (CryptoKit, with a per-record key in `encryptedValues`).
- Every write is a full write: `CloudScriptRecord.apply(_:to:)` sets every key it owns, nil for the ones that don't apply,
  because CloudKit keeps the server's value for a key that is not changed. The engine applies a version to the last
  record the server sent, not to a fresh one. Each asset write makes a plaintext temp file that the engine deletes after
  the upload, also after a failed try.
- Dates outside about +/-31,000 years are treated as damage and the record is skipped.
- The 500,000 byte limit (title plus body) is a safe guess under CloudKit's record size limit of about 1 MB (unverified).
- No indexes are needed: the engine fetches by zone changes, not by query.
