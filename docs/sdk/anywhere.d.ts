type JSONValue = null | boolean | number | string | JSONValue[] | {[key: string]: JSONValue};
interface PluginInvocation {
  apiVersion: 1;
  invocationID: string;
  actionID: string;
  source: 'launcher' | 'finder';
  query: string;
  argument: string;
  paths: string[];
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
  config: {get(): Promise<Record<string, string>>};
  storage: {get(key: string): Promise<JSONValue>; set(key: string, value: JSONValue): Promise<void>; remove(key: string): Promise<void>};
  clipboard: {writeText(text: string): Promise<void>};
  tasks: {run(input: JSONValue): Promise<PluginTask>};
}
declare const anywhere: AnyWhereSDK;
interface Window { anywhere: AnyWhereSDK; }
