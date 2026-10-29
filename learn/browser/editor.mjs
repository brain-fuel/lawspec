import * as monaco from 'monaco-editor/editor/editor.api.js';
import 'monaco-editor/languages/definitions/fsharp/register.js';
import 'monaco-editor/languages/definitions/javascript/register.js';
import 'monaco-editor/languages/definitions/typescript/register.js';
export {monaco};
import {registerLawspec} from './lawspec-language.mjs';
registerLawspec(monaco, __LAWSPEC_RULES__);
// Match the reading surfaces while inheriting Monaco's language token palettes.
// ref:DEC-learn-theme
monaco.editor.defineTheme('lawspec-light', {
  base: 'vs',
  inherit: true,
  rules: [],
  colors: {
    'editor.background': '#ffffff',
    'editor.foreground': '#233636',
    'editorLineNumber.foreground': '#606e68',
    'editorLineNumber.activeForeground': '#233636',
    'editorCursor.foreground': '#146c55',
    'editor.selectionBackground': '#cee7da',
    'editor.lineHighlightBackground': '#f0f3ee',
    'editorIndentGuide.background1': '#d5ded7',
  },
});
monaco.editor.defineTheme('lawspec-dark', {
  base: 'vs-dark',
  inherit: true,
  rules: [
    {token: 'comment', foreground: '8FB77A'},
    {token: 'comment.doc', foreground: '8FB77A'},
  ],
  colors: {
    'editor.background': '#1b2523',
    'editor.foreground': '#e4ece7',
    'editorLineNumber.foreground': '#afbdb5',
    'editorLineNumber.activeForeground': '#e4ece7',
    'editorCursor.foreground': '#7bd6b3',
    'editor.selectionBackground': '#385c4b',
    'editor.lineHighlightBackground': '#24312d',
    'editorIndentGuide.background1': '#40514b',
  },
});
