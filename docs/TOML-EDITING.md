# Editing TOML values

For writable TOML files up to the 2 MB inspection limit, the Structured tab
offers an **Edit TOML values** form for existing strings, booleans, signed 64-bit
integers and finite floating-point numbers. It displays the first 200 supported
values in source order. Remaining values can be inspected in the read-only tree
and edited in Source. Files processed in the background use Source editing.

Enter a replacement and click **Apply** beside that value. Apply updates the
editor buffer; it does not write the file. **Save** uses the same diff review,
confirmation, conflict checks and atomic save as other edits. An input not yet
applied is a local form draft; changing files or modes can discard that draft.

## What is preserved

The editor locates the existing value token and patches only that byte range.
Comments, whitespace, line endings, key spelling and all other values remain
unchanged. The selected value can acquire a different spelling: a modified
literal string becomes an escaped basic string, for example, or a hexadecimal
integer becomes a decimal integer. Applying the same native value preserves its
original token as well.

The replacement must keep the existing native TOML type. Integers are handled as
Int64 without a JSON/Double conversion. Enter integer input in decimal; an
out-of-range integer or a fractional replacement is rejected. Floating-point
values remain floating point even when the input is a whole number. Strings
accept text and logical newlines; quotes, backslashes and control characters are
escaped into one valid TOML value, without creating another setting. The complete
result is reparsed and checked against the expected native TOML tree before the
buffer changes.

For example, changing `count` below preserves the comment, the literal spelling
of `label` and the datetime type of `when`:

```toml
label = 'fictional example'
count   = 42  # keep this comment
when = 2026-10-28T12:00:00Z
```

With masking enabled, sensitive keys and recognizable credential-bearing values
use secure input; sensitive labels are redacted. The normal heuristic masking
limits still apply. Source deliberately shows real values for editing.

## Values that use Source

Use Source to add or remove keys, change a value's type, create tables, or edit
arrays, inline tables, array-of-table members, dates, times and datetimes. NaN,
infinities, strings containing escaped NUL and syntax the source lexer cannot
locate unambiguously also remain in Source. Invalid documents must be corrected
there first. Read-only sources never expose the scalar editing form.

## MCP add/copy is a separate operation

MCP add/copy into Codex edits the native typed TOML table and preserves unrelated
types, but its serializer can normalize comments and formatting across the
document. It presents that warning and a diff review before changing the buffer;
saving still requires the subsequent Save review. Scalar token editing does not
change those MCP conversion rules or make unsupported cross-client fields
equivalent. See [MCP schemas](MCP-SCHEMAS.md).
