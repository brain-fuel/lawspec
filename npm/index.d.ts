// Generated from LawSpec.Gen. Do not edit.
export type Target = 'java' | 'python' | 'javascript' | 'typescript' | 'go' | 'haskell' | 'kotlin' | 'rust';
export interface Source { path: string; content: string }
export interface Location { file: string; line: number; column: number }
export interface Span { start: Location; end: Location }
export interface Diagnostic { code: string; message: string; at: Location | null }
export interface Artifact { path: string; content: string; ownership: 'user' | 'generated'; placement: 'source' | 'test' }
export type Type = {kind:'constructor'; name:string; arguments:TypeArgument[]} | {kind:'variable'; id:string} | {kind:'function'; parameter:Type; result:Type};
export type TypeArgument = {kind:'type'; type:Type} | {kind:'natural'; value:string} | {kind:'indexVariable'; id:string};
export type Origin = {kind:'source'; span:Span} | {kind:'generated'; declaration:string};
export type Evidence = {kind:'numeric'|'structural'; type:Type};
export interface Expr {type:Type; origin:Origin; text:string; node:ExprNode}
export type ExprNode = {kind:'constant'; value:ScalarValue} | {kind:'local'; id:string} | {kind:'call'; declaration:string; arguments:Expr[]} | {kind:'binary'; operator:string; evidence:Evidence; left:Expr; right:Expr} | {kind:'unary'; operator:'-'|'!'; argument:Expr} | {kind:'shortCircuit'; operator:'&&'|'||'; left:Expr; right:Expr} | {kind:'convert'; conversion:'explicit'|'checked'; argument:Expr} | {kind:'helper'; name:string; arguments:Expr[]};
export type Assertion = {kind:'equal'; evidence:Evidence; left:Expr; right:Expr} | {kind:'implies'; guard:Expr; body:Assertion} | {kind:'all'; items:Assertion[]};
export interface Generation {cases:number; maxAttempts:number; maxShrinks:number; exhaustiveLimit:number}
export interface Binder {id:string; name:string; type:Type}
export interface Input extends Binder {predicates:Expr[]; bounds:{operator:string; value:Expr}[]}
export interface Example {name:string; bindings:(Binder & {value:ScalarValue})[]; expectations:Assertion[]}
export interface Law {id:string; owner:string; name:string; inputs:Input[]; assertion:Assertion; examples:Example[]; description:string; rationale:string; references:string[]; location:Location; trace:string[]; generation:Generation}
export interface Unit {id:string; declarations:(Binder & {origin:Origin})[]}
export interface Contract {id:string; name:string; arguments:Binder[]; result:Binder; preconditions:Expr[]; postconditions:Expr[]}
export interface Refinement {owner:string; name:string; parameters:{name:string; kind:'type'|'value'; type:string}[]; requirements:{capability:string; type:string}[]; definition:string}
export interface CheckRequest {sources:Source[]; schemaVersion?:3; machineBits?:32|64; generation?:Partial<Generation>}
export interface GenerationRequest extends CheckRequest {target:Target; sourceDir?:string; testDir?:string}
export interface Result {schemaVersion:3; machineBits?:32|64; generation?:Generation; units?:Unit[]; laws?:Law[]; contracts?:{owner:string; contract:Contract}[]; refinements?:Refinement[]; diagnostics:Diagnostic[]; expansions?:string[]; files?:Artifact[]}
export type IntegerType = 'Int8' | 'Int16' | 'Int32' | 'Int64' | 'UInt8' | 'UInt16' | 'UInt32' | 'UInt64' | 'IntSize' | 'UIntSize' | 'UIntPtr' | 'Integer' | 'BigInt' | 'BigUInt';
export type ScalarValue = {type: IntegerType; value: string} | {type: 'Bool'; value: boolean} | {type: 'Decimal'; coefficient: string; exponent: string} | {type: 'Rational'; numerator: string; denominator: string} | {type: 'Float32' | 'Float64'; bits: string} | {type: 'Complex64' | 'Complex128'; real: ScalarValue; imaginary: ScalarValue} | {type: 'Char' | 'CodePoint' | 'CodeUnit16'; value: number} | {type: 'Text' | 'CodePointText' | 'Utf16Text' | 'Bytes'; units: number[]} | {type: 'Symbol'; id: string; description: string} | {type: 'Unit' | 'Null' | 'Undefined'} | {type: 'Nullable' | 'Optional'; value: ScalarValue | null};
export interface Compiler { check(input: CheckRequest): Promise<Result>; expand(input: CheckRequest): Promise<Result>; planGeneration(input: GenerationRequest): Promise<Result> }
export function createCompiler(): Promise<Compiler>;
