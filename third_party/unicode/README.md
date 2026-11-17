# Unicode data

Baldr carries no Unicode data files of its own, but it compiles in tables
built from them, and their licence, the [Unicode License v3](LICENSE), asks
that its notice travel with copies or with their documentation:

- `baldr/emoji_data.odin`, built by `tools/emoji_gen` from Unicode's
  `emoji-test.txt`: the emoji the picker offers, their names and groups.
- runa's tables (`third_party/runa/`), built from the Unicode Character
  Database files in `third_party/runa/tools/ucd/`: line breaking, word,
  sentence and grapheme boundaries, bidirectional text, scripts and
  normalisation.

`baldr.notices()` includes this licence, so an app that shows its notices
passes it on.
