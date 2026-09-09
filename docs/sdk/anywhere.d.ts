type JSONValue = null | boolean | number | string | JSONValue[] | {[key: string]: JSONValue};
interface PluginInvocation {
  /** API 1; actionID below is the installed UUID, not the manifest-local action ID. */
  apiVersion: 1;
  invocationID: string;
  actionID: string;
  source: 'launcher' | 'finder';
  query: string;
  argument: string;
  paths: string[];
  /** Captured Finder directory; falls back to the user's home directory. */
  finderPath: string;
  variant?: string;
}
interface PluginFailure {
  code: 'invalidArguments' | 'denied' | 'sessionClosed' | 'busy' | 'failed' |
    'timedOut' | 'cancelled' | 'outputLimit' | 'storageLimit';
  message: string;
}
interface PluginTaskResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  error: PluginFailure | null;
}
interface PluginTask {
  id: string;
  result: Promise<PluginTaskResult>;
  cancel(): Promise<void>;
  onOutput(callback: (event: {id: string; stream: 'stdout' | 'stderr'; text: string}) => void): () => void;
}
interface AnyWhereSDK {
  onEnter(callback: (context: PluginInvocation) => void): () => void;
  getInvocation(): Promise<PluginInvocation>;
  workflow: {
    /** Standalone: {active:false,input:null}. Active steps may also receive a null input. */
    context(): Promise<{active: boolean; input: JSONValue}>;
    /** Submit once from an interactive same-pack step. Host advances after replying.
     * denied: standalone; busy: duplicate or task still running; invalidArguments: invalid/oversized output.
     * Existing 1 MiB bridge limits apply. This cannot start workflows or call other packs.
     */
    complete(output: JSONValue): Promise<void>;
  };
  config: {get(): Promise<Record<string, string>>};
  storage: {get(key: string): Promise<JSONValue>; set(key: string, value: JSONValue): Promise<void>; remove(key: string): Promise<void>};
  clipboard: {writeText(text: string): Promise<void>};
  tasks: {run(input: JSONValue): Promise<PluginTask>};
}
declare const anywhere: AnyWhereSDK;
interface Window { anywhere: AnyWhereSDK; }
