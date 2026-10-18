# Pinned Unicode data

`17.0.0/CaseFolding.txt` is the unmodified Unicode 17.0.0 data file from
<https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt>.
Its SHA-256 is
`ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.
The Unicode license is included in `LICENSE.txt`.

Full default folding selects the 1,585 C and F entries. S and Turkic T
entries are excluded. Unlisted code points map to themselves. Folding may
expand a code point; it performs no normalization or word segmentation.

`lawspec-dev generate` checks the pinned digest and embeds the table. The
compiler turns it into ordinary checked definitions over portable text
operations. Native and WASM compilation use the same table and definitions.
Updating the version is an explicit language behavior change.
