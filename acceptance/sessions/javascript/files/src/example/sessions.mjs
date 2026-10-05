// User-owned LawSpec adapter: adding through a server process, over the
// generated channel ends (src/lawspec_sessions.mjs).
//
// Receives wait for the other process, so the adapters are asynchronous and
// run their processes at once with Promise.all.
import {Hire, Serve} from '../lawspec_sessions.mjs';

// The server: receive two numbers, send their sum.
async function serve(server) {
  const [a, second] = await server.receive();
  const [b, reply] = await second.receive();
  reply.send(BigInt(a) + BigInt(b));
}

// The client: send a and b, then receive the sum.
async function ask(client, a, b) {
  const afterA = client.send(a);
  const waiting = afterA.send(b);
  const [sum] = await waiting.receive();
  return sum;
}

// The manager is handed the server's end over Hire, and serves it.
async function manage(manager) {
  const [hired] = await manager.receive();
  await serve(hired);
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export async function add(value0, value1) {
  const [server, client] = Serve.open();
  const [, sum] = await Promise.all([serve(server), ask(client, value0, value1)]);
  return sum;
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Integer
export async function addHired(value0, value1) {
  const [server, client] = Serve.open();
  const [hirer, manager] = Hire.open();
  hirer.send(server);
  const [, sum] = await Promise.all([manage(manager), ask(client, value0, value1)]);
  return sum;
}
