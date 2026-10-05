// User-owned LawSpec adapter: adding through a server process, over the
// generated channel ends (src/lawspec_sessions.ts).
//
// Receives wait for the other process, so the adapters are asynchronous and
// run their processes at once with Promise.all.
import {Hire, Serve} from '../lawspec_sessions.js';

// The server: receive two numbers, send their sum.
async function serve(server: Serve.First.ReceiveInt32Step1): Promise<void> {
  const [a, second] = await server.receive();
  const [b, reply] = await second.receive();
  reply.send(BigInt(a) + BigInt(b));
}

// The client: send a and b, then receive the sum.
async function ask(client: Serve.Second.SendInt32Step1, a: number, b: number): Promise<bigint> {
  const afterA = client.send(a);
  const waiting = afterA.send(b);
  const [sum] = await waiting.receive();
  return sum;
}

// The manager is handed the server's end over Hire, and serves it.
async function manage(manager: Hire.Second.ReceiveServe): Promise<void> {
  const [hired] = await manager.receive();
  await serve(hired);
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export async function add(value0: number, value1: number): Promise<bigint> {
  const [server, client] = Serve.open();
  const [, sum] = await Promise.all([serve(server), ask(client, value0, value1)]);
  return sum;
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export async function addHired(value0: number, value1: number): Promise<bigint> {
  const [server, client] = Serve.open();
  const [hirer, manager] = Hire.open();
  hirer.send(server);
  const [, sum] = await Promise.all([manage(manager), ask(client, value0, value1)]);
  return sum;
}
