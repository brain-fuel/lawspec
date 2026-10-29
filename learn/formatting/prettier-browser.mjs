// The brace-style plugin calls Prettier again with an empty plugin list.
// Node's Prettier loads built-in parsers automatically; standalone requires
// them explicitly. Supply the same built-ins without modifying the plugin.
// ref:DEC-google-style-allman
import * as prettier from 'prettier/standalone';
import * as babel from 'prettier/plugins/babel';
import * as estree from 'prettier/plugins/estree';
import * as typescript from 'prettier/plugins/typescript';
import * as html from 'prettier/plugins/html';
import * as postcss from 'prettier/plugins/postcss';
export * from 'prettier/standalone';
export function format(source, options)
{
  return prettier.format(source, {
    ...options,
    plugins: [
      babel,
      estree,
      typescript,
      html,
      postcss,
      ...(options.plugins ?? []),
    ],
  });
}
