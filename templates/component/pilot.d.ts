import type {HostOptions, Identity} from 'wasm-platform-kit';
import type {
  Source,
  Location,
  Span,
  Diagnostic as WireDiagnostic,
} from './assets/interfaces/lawspec-format-pilot-application.js';
export type {Source, Location, Span};
/** Uses generated WIT diagnostic types with the existing JavaScript optional-field convention. */
export type Diagnostic = Omit<WireDiagnostic, 'at' | 'related'> & {
  /** Primary source location, or null when no location applies. */
  at: Location | null;
  /** Additional diagnostic spans when supplied by the existing compiler. */
  related?: WireDiagnostic['related'];
};
/** Preserves the public formatter result shape. */
export interface FormatResult
{
  /** Formatted content; empty when formatting produces no sources. */
  formattedSources: Source[];
  /** Original compiler diagnostic classifications and coordinates. */
  diagnostics: Diagnostic[];
  /** Profile checked by this pilot build. */
  languageProfile: '1.0-rc.2';
}
/** Runs the real Haskell formatter under per-instance capability policy. */
export interface Formatter
{
  /** Runtime, provider, policy and artifact identities for this formatter. */
  readonly identity: Identity;
  /** Formats supplied content; mandatory definition checks remain enabled by default. */
  format(
    input: {sources: Source[]; compile?: boolean},
    controls?: {signal?: AbortSignal},
  ): Promise<FormatResult>;
  /** Reads and formats all inputs in Haskell, writing only with authority and no diagnostics. */
  formatFiles(
    provider: string,
    paths: string[],
    options?: {write?: boolean; compile?: boolean; signal?: AbortSignal},
  ): Promise<FormatResult>;
  /** Terminates the runtime and releases all instance resources. */
  close(): void;
  /** Cancels pending work and prevents subsequent invocations. */
  revoke(): void;
}
/** Resolves component and worker assets automatically for either runtime. */
export function createFormatter(
  options?: Omit<HostOptions, 'manifest'>,
): Promise<Formatter>;
