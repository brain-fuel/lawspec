module LawSpec.Gen (generate) where
import LawSpec.Scalar
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
    , "export interface Artifact { path: string; content: string; ownership: 'user' | 'generated'; placement: 'source' | 'test' }"
    , "export type Type = {tag: 'Named' | 'Variable'; contents: string} | {tag: 'Arrow'; contents: [Type, Type]} | {tag: 'Applied'; contents: ['Nullable' | 'Optional', Type]} | {tag:'Refined'; contents:[string, Type, Expr | null]} | {tag:'Qualified'; contents:[Constraint[],Type]} | {tag:'CheckedType'; contents:[Expr[],Type]} | {tag:'RefinementApp'; contents:[string,RefinementArgument[]]};"
    , "export interface Constraint {tag:'Capability'; contents:['Eq'|'Integer'|'Ordered'|'Bounded',Type]}"
    , "export type RefinementArgument = {tag:'TypeArgument'; contents:Type} | {tag:'ValueArgument'; contents:Expr};"
    , "export interface Refinement {refinementName:string; refinementParameters:[string,Type][]; refinementRequirements:Constraint[]; refinementBody:Type}"
    , "export interface Contract {contractName:string; contractArguments:[string,Type][]; contractResult:[string,Type]; contractPreconditions:Expr[]; contractPostconditions:Expr[]}"
    , "export interface Generation {cases:number; maxAttempts:number; maxShrinks:number; exhaustiveLimit:number}"
    , "export interface Input {inputName:string; inputId:string; inputType:Type; inputRefinements:Expr[]}"
    , "export interface DomainPlan {domainInput:Input; domainBounds:[string,Expr][]}"
    , "export type IntegerType = " ++ intercalate " | " ["'" ++ primitiveName p ++ "'" | p <- primitives, family p == IntegerFamily] ++ ";"
    , "export type ScalarValue = {type: IntegerType; value: string} | {type: 'Bool'; value: boolean} | {type: 'Decimal'; coefficient: string; exponent: string} | {type: 'Rational'; numerator: string; denominator: string} | {type: 'Float32' | 'Float64'; bits: string} | {type: 'Complex64' | 'Complex128'; real: ScalarValue; imaginary: ScalarValue} | {type: 'Char' | 'CodePoint' | 'CodeUnit16'; value: number} | {type: 'Text' | 'CodePointText' | 'Utf16Text' | 'Bytes'; units: number[]} | {type: 'Symbol'; id: string; description: string} | {type: 'Unit' | 'Null' | 'Undefined'} | {type: 'Nullable' | 'Optional'; value: ScalarValue | null};"
    , "export type Expr = {tag: 'Var' | 'StringLit'; contents: string} | {tag: 'Number'; contents: string} | {tag: 'DecimalNumber'; contents: [string, string]} | {tag: 'BoolLit'; contents: boolean} | {tag: 'Apply' | 'Compose'; contents: [Expr, Expr]} | {tag: 'ScalarLit'; contents: ScalarValue} | {tag: 'Annotate'; contents: [Expr, Type]} | {tag: 'Unary'; contents: [string, Expr]} | {tag: 'Binary'; contents: [string, Expr, Expr]} | {tag:'TypeBound'; contents:['min'|'max',Type]};"
    , "export type Definition = {tag: 'Forall'; contents: [[string, Type][], Definition]} | {tag: 'Equal'; contents: [Expr, Expr]} | {tag: 'Holds'; contents: Expr} | {tag: 'Implies'; contents: [Expr, Definition]} | {tag: 'And'; contents: [Definition, Definition]} | {tag: 'Invoke'; contents: [string, Expr[]]};"
    , "export interface Expectation { actual: Expr; expected: ScalarValue }"
    , "export interface Example { exampleName: string; bindings: [string, ScalarValue][]; expectations: Expectation[] }"
    , "export interface Law { lawName: string; parameters: [string, Type][]; requirements: Constraint[]; definition: Definition; description: string; rationale: string; examples: Example[]; references: string[]; location: Location }"
    , "export type Assertion = {tag: 'AssertEqual'; contents: [Expr, Expr]} | {tag: 'AssertImplies'; contents: [Expr, Assertion]} | {tag: 'AssertAll'; contents: Assertion[]};"
    , "export interface Expanded { owner: string; name: string; inputs: Input[]; left: Expr; right: Expr; guards: Expr[]; assertion: Assertion; trace: string[]; original: Law; typedExpressions: TypedExpr[]; propertyKind: 'law'|'contract'; generation:Generation; generationPlan:DomainPlan[] }"
    , "export interface TypedExpr { expressionType: Type; expression: Expr; operands: TypedExpr[]; requiredConversion: Type | null }"
    , "export interface CheckRequest { sources: Source[]; schemaVersion?: 2; machineBits?: 32 | 64; generation?:Partial<Generation> }"
    , "export interface GenerationRequest extends CheckRequest { target: Target; sourceDir?: string; testDir?: string }"
    , "export interface Result { schemaVersion: 2; machineBits?: 32 | 64; generation?:Generation; refinements?:{owner:string; declaration:Refinement}[]; contracts?:{owner:string; contract:Contract}[]; diagnostics: Diagnostic[]; laws?: Expanded[]; expansions?: string[]; files?: Artifact[] }"
    , "export interface Compiler { " ++ intercalate "; " [n ++ "(input: " ++ t ++ "): Promise<Result>" | (n,t) <- methods] ++ " }"
    , "export function createCompiler(): Promise<Compiler>;"
    ]
