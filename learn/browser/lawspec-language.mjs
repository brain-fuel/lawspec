// Public token patterns come from the maintained VS Code grammar at build time.
// The state machine handles comments and quoted/phrase literals before words.
/** Highlight LawSpec using the maintained grammar vocabulary and stateful literal handling in Monaco. ref:DEC-learn-course-preview */
export function registerLawspec(monaco, patterns)
{
  monaco.languages.register({
    id: 'lawspec',
    extensions: ['.lawspec'],
    aliases: ['LawSpec'],
  });
  monaco.languages.setLanguageConfiguration('lawspec', {
    comments: {lineComment: '--'},
    brackets: [
      ['(', ')'],
      ['[', ']'],
      ['{', '}'],
    ],
    autoClosingPairs: [
      {open: '(', close: ')'},
      {open: '[', close: ']'},
      {open: '{', close: '}'},
      {open: '"|', close: '|', notIn: ['string', 'comment']},
    ],
  });
  monaco.languages.setMonarchTokensProvider('lawspec', {
    unicode: true,
    defaultToken: '',
    tokenPostfix: '.lawspec',
    tokenizer: {
      root: [
        [/--.*$/, 'comment'],
        [/"\|/, 'type.identifier', '@phrase'],
        [/`\|/, 'type.identifier', '@phrase'],
        [/"""/, 'string', '@triple'],
        [/"/, 'string', '@string'],
        [/`[^`\n]*`/, 'type.identifier'],
        ...patterns.map(([pattern, token]) => [
          new RegExp(pattern, 'u'),
          token,
        ]),
        [/\b(?:true|false|Absent|Present|Nil|Cons|Left|Right)\b/, 'constant'],
        [
          /[-+]?(?:0x[\da-fA-F]+|0b[01]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)(?:us|ms|min|s|h|d)?\b/,
          'number',
        ],
        [/[\p{L}_][\p{L}\p{N}_.]*/u, 'identifier'],
        [/::|->|=>|>=|<=|<>|&&|\|\||[=+*/<>!|&?.:-]/, 'operator'],
        [/[{}()[\]]/, '@brackets'],
        [/[,;]/, 'delimiter'],
      ],
      string: [
        [/\\./, 'string.escape'],
        [/"/, 'string', '@pop'],
        [/[^"\\]+/, 'string'],
      ],
      triple: [
        [/"""/, 'string', '@pop'],
        [/[^"\\]+/, 'string'],
        [/\\./, 'string.escape'],
        [/"/, 'string'],
      ],
      phrase: [
        [/\\./, 'string.escape'],
        [/\|/, 'type.identifier', '@pop'],
        [/[^|\\]+/, 'type.identifier'],
      ],
    },
  });
}
