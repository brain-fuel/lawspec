export interface Identity {name: string; version: string;}
export interface DependencySource {version: string; path?: string; git?: string; rev?: string; tagPrefix?: string; subdir?: string; archive?: string; sha256?: string;}
export interface ContractRequirement {contract: string; abilities?: string[]; declarations?: string[]; settings?: string[];}
export interface ComponentTarget {
  name?: string; language: import('./index.js').Target; root: string;
  sourceDir?: string; testDir?: string;
  python?: string; maven?: string; gradle?: string; rustc?: string; cargo?: string;
  scala?: string; swift?: string; clojure?: string; dotnet?: string;
  nativeBindings?: import('./index.js').NativeBindings;
}
export interface ComponentManifest {
  manifestVersion: 1;
  component?: Identity;
  package?: Identity;
  languageProfile: '1.0-rc.2';
  sources: string[];
  targets?: ComponentTarget[];
  dependencies?: Record<string, string | DependencySource>;
  packages?: string[];
  inputs?: string[];
  assets?: string[];
  provides?: ContractRequirement[];
  requires?: Record<string, ContractRequirement>;
  verification?: import('./index.js').Verification;
  generation?: Partial<import('./index.js').Generation>;
  machineBits?: 32 | 64;
  cache?: boolean;
  attestation?: string;
  description?: string;
}
export interface ResolutionOptions {locked?: boolean; offline?: boolean; update?: boolean | string;}
export interface ResolvedContract extends ContractRequirement {version: string; digest: string; versionRequirement?: string;}
export interface ComponentDescriptor {
  format: 'lawspec-component'; version: 1; manifest: string; root: string;
  component: Identity | null; package: Identity | null;
  fingerprint: string; manifestDigest: string;
  targets: ComponentTarget[]; provides: ResolvedContract[]; requires: Record<string, ResolvedContract>;
  dependencies: unknown[]; laws: unknown[]; declarations: string[];
}
/** Parses EDN data; readManifest also validates the component schema. */
export function parseManifest(text: string, file?: string): Record<string, unknown>;
export function writeManifest(value: ComponentManifest | Record<string, unknown>, options?: {compact?: boolean}): string;
export function readManifest(file: string): Promise<ComponentManifest>;
export function findManifest(start?: string): Promise<string>;
export function resolveComponent(file: string, options?: ResolutionOptions): Promise<ComponentDescriptor>;
