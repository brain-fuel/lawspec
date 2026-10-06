// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
import * as data from '.././lawspec_data.js';
import * as ls from '../lawspec_runtime.js';
import * as secure from '../lawspec_network.js';

export function encoded(value0: string, value1: bigint, value2: number, value3: number): string[] {
  return ls.wireEncoded(value0, value1, value2, value3);
}

export function roundTrips(value0: string, value1: bigint, value2: number, value3: number): boolean {
  return ls.wireRoundTrips(value0, value1, value2, value3);
}

export async function remoteShifted(value0: number): Promise<bigint> {
  const remote = await import('../lawspec_remote.js');
  const network = new ls.MemoryNetwork({seed: BigInt(value0) & 0xFFFFn, loss: 0.2, duplicate: 0.2});
  const here = new ls.Node(network.transport('here')), there = new ls.Node(network.transport('there'));
  try {
    remote.serve(there);
    return await remote.evaluate(here, there.address, 'example.distribution::shifted', BigInt(value0));
  } finally {
    await here.close();
    await there.close();
  }
}

export function openTally(value0: unknown): data.Tally {
  return new data.Tally(0n);
}

export function add(value0: data.Tally, value1: number): data.Pair<bigint, data.Tally> {
  const after = value0.count + BigInt(value1);
  return new data.Pair(after, new data.Tally(after));
}

export async function remoteAdds(value0: number): Promise<bigint> {
  const {TallyActor} = await import('../lawspec_actors.js');
  const server = new ls.Node(await ls.TcpTransport.listen()), client = new ls.Node(await ls.TcpTransport.listen());
  try {
    const address = TallyActor.start().serve(server, 'tally');
    const tally = TallyActor.connect(client, address);
    await tally.add(value0);
    return await tally.add(value0);
  } finally {
    await client.close();
    await server.close();
  }
}

export async function remoteDoubling(value0: number): Promise<bigint> {
  const {Doubling} = await import('../lawspec_sessions.js');
  const server = new ls.Node(await ls.HttpTransport.listen()), client = new ls.Node(await ls.HttpTransport.listen());
  try {
    const first = Doubling.listen(server, 'doubling');
    const second = Doubling.dial(client, server.address + '/doubling');
    const worker = (async () => {
      const [x, reply] = await second.receive();
      reply.send(2n * BigInt(x));
    })();
    const [result] = await first.send(value0).receive();
    await worker;
    return result;
  } finally {
    await client.close();
    await server.close();
  }
}

export async function remoteLedger(value0: number): Promise<bigint> {
  const {LedgerMailbox} = await import('../lawspec_mailboxes.js');
  const here = new ls.Node(await ls.TcpTransport.listen()), there = new ls.Node(await ls.TcpTransport.listen());
  try {
    const ledger = LedgerMailbox.serve(there, 'ledger');
    const sender = LedgerMailbox.connect(here, there.address + '/ledger');
    await sender.send(BigInt(value0));
    await sender.send(BigInt(value0));
    const total = (await ledger.receive(5000)) + (await ledger.receive(5000));
    // receive within: nothing more comes, so it gives null in time.
    if ((await ledger.receiveWithin(20)) !== null) return -1n;
    return total;
  } finally {
    await here.close();
    await there.close();
  }
}

export async function remoteHandoff(value0: number): Promise<bigint> {
  const {Doubling, Handoff} = await import('../lawspec_sessions.js');
  const here = new ls.Node(await ls.TcpTransport.listen()), there = new ls.Node(await ls.TcpTransport.listen());
  try {
    // A local conversation on this node; its first end goes to the other.
    const [first, second] = Doubling.open();
    const worker = (async () => {
      const [x, reply] = await second.receive();
      reply.send(2n * BigInt(x));
    })();
    const giving = Handoff.listen(here, 'handoff');
    const taking = Handoff.dial(there, here.address + '/handoff');
    giving.send(first);
    const [end] = await taking.receive();
    const [result] = await end.send(value0).receive();
    await worker;
    return result;
  } finally {
    await there.close();
    await here.close();
  }
}

export async function remoteHandoffOnward(value0: number): Promise<bigint> {
  const {Answering, Passing} = await import('../lawspec_sessions.js');
  const network = new ls.MemoryNetwork({seed: BigInt(value0) & 0xFFFFn, loss: 0.1, duplicate: 0.1, delay: 0.005});
  const [a, b, c, d] = ['a', 'b', 'c', 'd'].map((n) => new ls.Node(network.transport(n)));
  try {
    // A conversation between A and C, which sends at once; A's end moves to
    // B, then to D, and answers from there.
    const first = Answering.listen(a, 'answering');
    const second = Answering.dial(c, a.address + '/answering').send(value0);
    const toB = Passing.listen(a, 'to-b');
    const atB = Passing.dial(b, a.address + '/to-b');
    toB.send(first);
    const [moved] = await atB.receive();
    const toD = Passing.listen(b, 'to-d');
    const atD = Passing.dial(d, b.address + '/to-d');
    toD.send(moved);
    const [end] = await atD.receive();
    // The end no longer needs A or B.
    await a.close();
    await b.close();
    const [x, reply] = await end.receive();
    reply.send(2n * BigInt(x));
    const [result] = await second.receive();
    return result;
  } finally {
    for (const node of [a, b, c, d]) await node.close();
  }
}

// Whether needle occurs in haystack.
function contains(haystack: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

export async function sealedOnTheWire(value0: number): Promise<boolean> {
  // A definition evaluated on another node: its request names the
  // definition's content hash, which shows on the wire only in the clear.
  const remote = await import('../lawspec_remote.js');
  const name = 'example.distribution::shifted';
  const digest = new TextEncoder().encode(remote.digest(name));
  const seen: Map<boolean, boolean> = new Map();
  for (const insecure of [false, true]) {
    const network = new ls.MemoryNetwork({seed: BigInt(value0) & 0xFFFFn, record: true});
    const make = (n: string) => (insecure ? network.insecureTransportForTests(n) : network.transport(n));
    const here = new ls.Node(make('here')), there = new ls.Node(make('there'));
    try {
      remote.serve(there);
      if ((await remote.evaluate(here, there.address, name, BigInt(value0))) !== BigInt(value0) + 1000n) return false;
      seen.set(insecure, network.recorded.some((frame: Uint8Array) => contains(frame, digest)));
    } finally {
      await here.close();
      await there.close();
    }
  }
  return seen.get(false) === false && seen.get(true) === true;
}

export function handshakeAgrees(value0: string): boolean {
  const fields = value0.split(' ');
  if (fields.length !== 13) return false;
  const [a, b, c, d, e, f, g, h, i, j, k, l, m] = fields;
  return secure.handshakeVector(a, b, c, d, e, f, g, h, i, j, k, l, m);
}
