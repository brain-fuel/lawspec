// User-owned LawSpec adapter: adding through a server process, over the
// generated channel ends (src/lawspec_sessions.ts).
//
// The spec declares add and addHired synchronous, so the processes take
// turns in this one call: a send is queued at once, and receiveNow takes a
// value already sent. Asynchronous code would await receive() instead and
// run the processes with par or spawn from lawspec_runtime.
import {Hire, Serve} from '../lawspec_sessions.js';

// The server: receive two numbers, send their sum.
function serve(server: Serve.First.ReceiveInt32Step1): void {
  const [a, second] = server.receiveNow();
  const [b, reply] = second.receiveNow();
  reply.send(BigInt(a) + BigInt(b));
}

// The client's half: send a and b, giving the end that receives the sum.
function ask(client: Serve.Second.SendInt32Step1, a: number, b: number): Serve.Second.ReceiveInt64 {
  const afterA = client.send(a);
  const waiting = afterA.send(b);
  return waiting;
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export function add(value0: number, value1: number): bigint {
  const [server, client] = Serve.open();
  const waiting = ask(client, value0, value1);
  serve(server);
  const [sum] = waiting.receiveNow();
  return sum;
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export function addHired(value0: number, value1: number): bigint {
  const [server, client] = Serve.open();
  const [hirer, manager] = Hire.open();
  hirer.send(server);
  const waiting = ask(client, value0, value1);
  // The manager is handed the server's end over Hire, and serves it.
  const [hired] = manager.receiveNow();
  serve(hired);
  const [sum] = waiting.receiveNow();
  return sum;
}
