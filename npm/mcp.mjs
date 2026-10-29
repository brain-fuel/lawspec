// Generated from templates/npm/mcp.mjs by lawspec-dev generate. Do not edit.
// Generated from templates/npm/mcp.mjs by lawspec-dev generate. Do not edit.
import {McpServer} from '@modelcontextprotocol/server';
import {serveStdio} from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import path from 'node:path';
import {createCompiler} from './api.mjs';
import {readManifest, findManifest, dependencyRanges} from './component.mjs';
import {resolveDependencies} from './component-packages.mjs';
import {collectSources} from './files.mjs';
const VERSION = '0.31.0';
function diagnostics(result)
{
  if (result.diagnostics?.length)
  {
    const error = new Error(
      result.diagnostics
        .map(
          item =>
            `${item.at ? `${item.at.file}:${item.at.line}:${item.at.column}: ` : ''}${item.code}: ${item.message}`,
        )
        .join('\n'),
    );
    error.diagnostics = result.diagnostics;
    throw error;
  }
  return result;
}
function toolError(error)
{
  return {content: [{type: 'text', text: error.message}], isError: true};
}
export async function serveLawSpec(configFile)
{
  configFile ??= await findManifest();
  configFile = path.resolve(configFile);
  const root = path.dirname(configFile);
  const compiler = await createCompiler();
  async function request()
  {
    const config = await readManifest(configFile);
    const dependencies = await resolveDependencies(configFile, config, {
      writeLock: false,
    });
    return {
      sources: await collectSources(root, config.sources, root),
      languageProfile: config.languageProfile,
      verification: config.verification ?? {layers: []},
      ...(config.package ? {package: config.package} : {}),
      dependencies: dependencyRanges(config),
      packages: dependencies.packages,
      ...(config.generation ? {generation: config.generation} : {}),
      machineBits: config.machineBits ?? 64,
      ...((config.component?.version ?? config.package?.version)
        ? {projectVersion: config.component?.version ?? config.package?.version}
        : {}),
      now: new Date().toISOString(),
    };
  }
  const server = new McpServer({name: 'lawspec', version: VERSION});
  server.registerTool(
    'lawspec_check',
    {
      description:
        'Validate the current LawSpec project and run only the law checks selected by lawspec.edn. Returns compiler diagnostics, verification selection, and explicit evidence statuses.',
      inputSchema: z.object({}),
    },
    async () =>
    {
      try
      {
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(
                diagnostics(await compiler.check(await request())),
                null,
                2,
              ),
            },
          ],
        };
      }
      catch (error)
      {
        return toolError(error);
      }
    },
  );
  server.registerTool(
    'lawspec_list_laws',
    {
      description:
        'List the laws declared in the current LawSpec project after validating its definitions. This does not imply that laws have been proved or tested.',
      inputSchema: z.object({}),
    },
    async () =>
    {
      try
      {
        const result = diagnostics(
          await compiler.check({
            ...(await request()),
            verification: {layers: []},
          }),
        );
        const laws = result.laws.map(law => ({
          id: `${law.owner}::${law.name}`,
          owner: law.owner,
          name: law.name,
          description: law.description,
          location: law.location,
        }));
        return {
          content: [{type: 'text', text: JSON.stringify({laws}, null, 2)}],
        };
      }
      catch (error)
      {
        return toolError(error);
      }
    },
  );
  server.registerTool(
    'lawspec_explain',
    {
      description:
        'Explain one LawSpec law in readable, mathematical, or developer form. Reads and validates the current project before explaining it.',
      inputSchema: z.object({
        law: z
          .string()
          .describe('Law identity, such as example.codec::round trip'),
        view: z
          .enum(['eng', 'math', 'dev'])
          .default('eng')
          .describe('Explanation style'),
      }),
    },
    async ({law, view}) =>
    {
      try
      {
        const result = diagnostics(
          await compiler.explain({...(await request()), law, view}),
        );
        return {content: [{type: 'text', text: result.text}]};
      }
      catch (error)
      {
        return toolError(error);
      }
    },
  );
  void serveStdio(() => server);
}
