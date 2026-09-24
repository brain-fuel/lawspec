module LawSpec.Gen (generate) where
import Data.List (intercalate)

methods :: [(String,String)]
methods = [("check", "CheckRequest"), ("expand", "CheckRequest"), ("planGeneration", "GenerationRequest")]

generate :: IO ()
generate = do
  writeFile "npm/api.mjs" $ unlines
    [ "// Generated from LawSpec.Gen. Do not edit."
    , "import { loadCore } from './launcher.mjs';"
    , "export async function createCompiler() {"
    , "  const call = await loadCore();"
    , "  return { " ++ intercalate ", " [n ++ ": (input) => call({ ...input, method: '" ++ n ++ "' })" | (n,_) <- methods] ++ " };"
    , "}"
    ]
  writeFile "npm/index.d.ts" $ unlines
    [ "// Generated from LawSpec.Gen. Do not edit."
    , "export type Target = 'java' | 'python' | 'javascript' | 'typescript' | 'go' | 'haskell' | 'kotlin';"
    , "export interface Source { path: string; content: string }"
    , "export interface Location { file: string; line: number; column: number }"
    , "export interface Diagnostic { code: string; message: string; at: Location | null }"
    , "export interface Artifact { path: string; content: string; ownership: 'user' | 'generated' }"
    , "export type Type = {tag: 'Named' | 'Variable'; contents: string} | {tag: 'Arrow'; contents: [Type, Type]};"
    , "export type Expr = {tag: 'Var'; contents: string} | {tag: 'Number'; contents: number} | {tag: 'Apply' | 'Compose'; contents: [Expr, Expr]};"
    , "export type Definition = {tag: 'Forall'; contents: [[string, Type][], Definition]} | {tag: 'Equal'; contents: [Expr, Expr]} | {tag: 'Invoke'; contents: [string, Expr[]]};"
    , "export interface Example { exampleName: string; bindings: [string, number][] }"
    , "export interface Law { lawName: string; parameters: [string, Type][]; requirements: Type[]; definition: Definition; description: string; rationale: string; examples: Example[]; references: string[]; location: Location }"
    , "export interface Expanded { owner: string; name: string; inputs: {inputName: string; inputId: string; inputType: Type}[]; left: Expr; right: Expr; trace: string[]; original: Law }"
    , "export interface CheckRequest { sources: Source[] }"
    , "export interface GenerationRequest extends CheckRequest { target: Target; sourceDir?: string; testDir?: string }"
    , "export interface Result { diagnostics: Diagnostic[]; laws?: Expanded[]; expansions?: string[]; files?: Artifact[] }"
    , "export interface Compiler { " ++ intercalate "; " [n ++ "(input: " ++ t ++ "): Promise<Result>" | (n,t) <- methods] ++ " }"
    , "export function createCompiler(): Promise<Compiler>;"
    ]
