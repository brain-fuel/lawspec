import type {CheckRequest,Compiler,Location,Result} from './index.d.ts';

export interface Z3Options {
  binary?: string;
  timeoutMs?: number;
  memoryMb?: number;
  resourceLimit?: number;
  seed?: number;
  maxOutputBytes?: number;
}
/** How a solver run went: shared by law and law-set evidence. */
interface SolverRun {
  outcome: 'unsat' | 'sat' | 'unknown' | 'timeout' | 'resource-limit' | 'out-of-memory' | 'unavailable' | 'failed' | 'unsupported';
  reason: string;
  stdout?: string;
  stderr?: string;
  elapsedMs?: number;
  exitCode?: number | null;
  signal?: string | null;
  runFingerprint?: string;
  prover?: {name:'z3'; version:string; binary:string; binaryFingerprint:string; fingerprint:string; arguments:string[]};
  configuration?: Required<Z3Options>;
}
/** A law's proof task, run by Z3. */
export interface LawSolverEvidence extends SolverRun {
  kind?: undefined;
  owner: string;
  declaration: string;
  at: Location;
  encoding: 'lawspec-smtlib-v1' | 'lawspec-smtlib-v2';
  machineBits: 32 | 64;
  programFingerprint: string;
  taskFingerprint?: string;
  status: 'proved' | 'refuted' | 'incomplete' | 'unsupported';
  model?: string;
  modelValidated?: boolean;
  counterexample?: {inputs:{name:string;value:string}[]; values:string; fingerprint:string; runFingerprint:string;
    check:'refuted'|'model-not-confirmed'|'incomplete'};
}
/** A law-set check's task (completeness, overlap, conflict or vacuity).
    status is the task's own result; check is its row's. */
export interface AnalysisSolverEvidence extends SolverRun {
  kind: 'analysis';
  owner: string;
  declaration: string;
  stage: 'completeness' | 'overlap' | 'conflict' | 'vacuity';
  encoding: 'lawspec-smtlib-v2';
  taskFingerprint?: string;
  status: 'proved' | 'refuted' | 'exempted' | 'incomplete' | 'unsupported';
  check?: 'proved' | 'refuted' | 'exempted' | 'incomplete';
  model?: undefined;
  modelValidated?: undefined;
  counterexample?: undefined;
}
export type SolverEvidence = LawSolverEvidence | AnalysisSolverEvidence;
export function proofTaskFingerprint(task: {encoding:string;programFingerprint:string;machineBits:number;owner:string;declaration:string;script:string}):string;
export function proveWithZ3(compiler:Compiler,request:CheckRequest,options?:Z3Options):Promise<Result & {solverEvidence:SolverEvidence[]}>;
