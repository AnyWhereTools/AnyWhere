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
  /** `documents` capability. UTF-8, <=50 MiB; native picker grants file access.
   * Transfers use bounded chunks without increasing the ordinary 1 MiB bridge limit.
   * Drafts are isolated per action. markDirty/saveDraft version prevents stale saves clearing newer edits.
   */
  documents: {
    open(): Promise<{name: string; text: string} | null>;
    draft(): Promise<{name: string; text: string} | null>;
    markDirty(version: number): Promise<void>;
    saveDraft(text: string, version: number): Promise<boolean>;
    saveAs(text: string, name?: string): Promise<boolean>;
    /** Also requires clipboard.write; supports documents larger than an ordinary bridge message. */
    copyText(text: string): Promise<boolean>;
  };
  /** `launcher.entries` capability. Entries persist beyond the page; disabled tools are omitted. */
  launcher: {
    setEntries(entries: {id: string; title: string; keywords: string[]; url: string}[]): Promise<void>;
    /** Opens an existing registered entry; substitutes percent-encoded argument for {query}. */
    open(id: string, argument?: string): Promise<void>;
  };
  /** `notifications` capability. Requires the owning tool's launcher switch to stay enabled. */
  notifications: {
    status(): Promise<'authorized' | 'denied' | 'notDetermined'>;
    /** Replaces this action's desired reminders (<=50); [] cancels them.
     * date is Unix seconds. daily/weekly use the date's local time/weekday, starting at next match.
     * Persist application data first. Check authorization/errors; success is not a promise of visible delivery.
     * Notification click opens this action with invocation.argument = reminder.id.
     */
    replace(reminders: {id: string; title: string; body: string; date: number; recurrence: 'none' | 'daily' | 'weekly'}[]):
      Promise<{authorization: 'authorized' | 'denied' | 'notDetermined'; errors: string[]}>;
  };
  /** Fires on initial entry and when an existing window is activated (e.g. notification click). */
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
