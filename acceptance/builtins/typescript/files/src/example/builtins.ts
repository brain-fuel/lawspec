// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments.
import { execFileSync } from 'node:child_process';
import * as data from '.././lawspec_data.js';

// LawSpec argument 0: Int32
// LawSpec result: lawspec.time::type::Duration
export function elapsed(
    clock: import('.././lawspec_abilities/lawspec/time.js').Clock,
    value0: number
): data.Duration {
  const start = clock.now();
  for (let i = 0; i < value0; i++) clock.now();
  return new data.Duration(clock.now().value - start.value);
}

// LawSpec argument 0: Int32
// LawSpec result: Bytes
export function token(
    secureRandom: import('.././lawspec_abilities/lawspec/random.js').SecureRandom,
    value0: number
): Uint8Array {
  return secureRandom.secureBytes(value0);
}

// A child process listens on the port, since Node binds sockets only
// asynchronously.
const listen = "const s=require('net').createServer();s.listen(Number(process.argv[1]),'127.0.0.1',()=>{s.close();});";

// LawSpec argument 0: Int32
// LawSpec result: Bool
export function listening(
    ports: import('.././lawspec_abilities/lawspec/system.js').Ports,
    value0: number
): boolean {
  execFileSync(process.execPath, ['-e', listen, String(ports.freePort())]);
  return true;
}

// LawSpec argument 0: Int32
// LawSpec result: Bool
export function charge(
    log: import('.././lawspec_abilities/lawspec/log.js').Log,
    value0: number
): boolean {
  if (value0 % 2 === 0) {
    log.logMessage(new data.LogLevelInfo(), `charged ${value0}`);
    return true;
  }
  return false;
}
