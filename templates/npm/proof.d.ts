import type {CheckRequest,Compiler,Location,Result} from './index.d.ts';

export interface Z3Options {
  binary?: string;
  timeoutMs?: number;
  memoryMb?: number;
  resourceLimit?: number;
  seed?: number;
  maxOutputBytes?: number;
}
export interface SolverEvidence {
  owner: string;
  declaration: string;
  at: Location;
  encoding: 'lawspec-smtlib-v1' | 'lawspec-smtlib-v2';
  machineBits: 32 | 64;
  programFingerprint: string;
  taskFingerprint?: string;
  status: 'proved' | 'refuted' | 'incomplete' | 'unsupported';
  outcome: 'unsat' | 'sat' | 'unknown' | 'timeout' | 'resource-limit' | 'out-of-memory' | 'unavailable' | 'failed' | 'unsupported';
  reason: string;
  model?: string;
  modelValidated?: boolean;
  counterexample?: {inputs:{name:string;value:string}[]; values:string; fingerprint:string; runFingerprint:string;
    check:'refuted'|'model-not-confirmed'|'incomplete'};
  stdout?: string;
  stderr?: string;
  elapsedMs?: number;
  exitCode?: number | null;
  signal?: string | null;
  runFingerprint?: string;
  prover?: {name:'z3'; version:string; binary:string; binaryFingerprint:string; fingerprint:string; arguments:string[]};
  configuration?: Required<Z3Options>;
}
export function proofTaskFingerprint(task: {encoding:string;programFingerprint:string;machineBits:number;owner:string;declaration:string;script:string}):string;
export function proveWithZ3(compiler:Compiler,request:CheckRequest,options?:Z3Options):Promise<Result & {solverEvidence:SolverEvidence[]}>;
