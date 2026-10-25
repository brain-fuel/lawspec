import type {CheckRequest,Compiler,Location,Recursion,Result} from './index.d.ts';

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
  /** Current task binding when a semantic result reuses an earlier execution. */
  currentTaskFingerprint?: string;
  /** Provenance of the completed execution reused; no fresh solver run occurred. */
  reused?: {key:string; owner:string; declaration:string; taskFingerprint:string; runFingerprint:string};
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
  lawFingerprint: string;
  taskFingerprint?: string;
  /** Current names for the same semantic induction plan; original cases remain in induction. */
  currentInduction?: {on:string; using:string[]};
  status: 'proved' | 'refuted' | 'incomplete' | 'unsupported';
  model?: string;
  modelValidated?: boolean;
  counterexample?: {inputs:{name:string;value:string}[]; values:string; fingerprint:string; runFingerprint:string;
    check:'refuted'|'model-not-confirmed'|'incomplete'};
  /** For a law over recursive definitions: the encoding of the run reported,
      and each encoding tried, in order. */
  recursion?: Recursion;
  attempts?: {recursion:Recursion; taskFingerprint:string; outcome:SolverRun['outcome']; runFingerprint?:string; elapsedMs?:number}[];
  /** Induction on an input: the cited laws, and each case's receipt. */
  induction?: {on:string; using:string[]; asked?:boolean; cases:{case:string; outcome?:SolverRun['outcome']; recursion?:Recursion;
    taskFingerprint?:string; runFingerprint?:string; values?:string; reason?:string;
    attempts?:{recursion:Recursion; taskFingerprint:string; outcome:SolverRun['outcome']; runFingerprint?:string; elapsedMs?:number}[]}[]};
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
/** A model law's task: induction, Spacer, an invariant re-check or the
    bounded run search; the law's own row says what they settled. */
export interface ModelSolverEvidence extends SolverRun {
  kind: 'model';
  owner: string;
  declaration: string;
  task: string;
  taskFingerprint: string;
  encoding: 'lawspec-smtlib-v2';
  status: 'proved' | 'incomplete';
  model?: undefined;
  modelValidated?: undefined;
  counterexample?: undefined;
}
export type SolverEvidence = LawSolverEvidence | AnalysisSolverEvidence | ModelSolverEvidence;
export function proofTaskFingerprint(task: {encoding:string;lawFingerprint:string;machineBits:number;owner:string;declaration:string;script:string}):string;
export function proveWithZ3(compiler:Compiler,request:CheckRequest,options?:Z3Options):Promise<Result & {solverEvidence:SolverEvidence[]}>;
