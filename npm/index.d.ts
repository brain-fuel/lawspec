// Generated from LawSpec.Gen. Do not edit.
export type Target = 'java' | 'python' | 'javascript' | 'typescript' | 'go' | 'haskell' | 'kotlin';
export interface Source { path: string; content: string }
export interface Location { file: string; line: number; column: number }
export interface Diagnostic { code: string; message: string; at: Location | null }
export interface Artifact { path: string; content: string; ownership: 'user' | 'generated' }
export type Type = {tag: 'Named' | 'Variable'; contents: string} | {tag: 'Arrow'; contents: [Type, Type]};
export type Expr = {tag: 'Var'; contents: string} | {tag: 'Number'; contents: number} | {tag: 'Apply' | 'Compose'; contents: [Expr, Expr]};
export type Definition = {tag: 'Forall'; contents: [[string, Type][], Definition]} | {tag: 'Equal'; contents: [Expr, Expr]} | {tag: 'Invoke'; contents: [string, Expr[]]};
export interface Example { exampleName: string; bindings: [string, number][] }
export interface Law { lawName: string; parameters: [string, Type][]; requirements: Type[]; definition: Definition; description: string; rationale: string; examples: Example[]; references: string[]; location: Location }
export interface Expanded { owner: string; name: string; inputs: {inputName: string; inputId: string; inputType: Type}[]; left: Expr; right: Expr; trace: string[]; original: Law }
export interface CheckRequest { sources: Source[] }
export interface GenerationRequest extends CheckRequest { target: Target; sourceDir?: string; testDir?: string }
export interface Result { diagnostics: Diagnostic[]; laws?: Expanded[]; expansions?: string[]; files?: Artifact[] }
export interface Compiler { check(input: CheckRequest): Promise<Result>; expand(input: CheckRequest): Promise<Result>; planGeneration(input: GenerationRequest): Promise<Result> }
export function createCompiler(): Promise<Compiler>;
