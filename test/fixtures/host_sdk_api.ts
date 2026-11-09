// Public compatibility: the existing factory remains valid; runtime names are closed.
// ref:DEC-host-sdk-independent-consumer
import {
  createCompiler,
  type Compiler,
  type CompilerOptions,
} from '../../npm/index.js';

const options: CompilerOptions = {runtime: 'component'};
const component: Promise<Compiler> = createCompiler(options);
const existing: Promise<Compiler> = createCompiler();
const legacy: Promise<Compiler> = createCompiler({runtime: 'legacy'});
// @ts-expect-error Unknown runtimes cannot silently select a fallback.
createCompiler({runtime: 'unrestricted'});
const source: Promise<Compiler> = createCompiler({
  runtime: 'component',
  // @ts-expect-error Source compilation is an installation operation.
  compilation: 'source',
});
const precompiled: Promise<Compiler> = createCompiler({
  runtime: 'component',
  compilation: 'precompiled',
});
// @ts-expect-error Compilation never silently falls back.
createCompiler({runtime: 'component', compilation: 'automatic'});
void [component, existing, legacy, source, precompiled];
