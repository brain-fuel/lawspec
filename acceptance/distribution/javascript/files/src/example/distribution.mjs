// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
import * as data from '.././lawspec_data.mjs';
import * as ls from '../lawspec_runtime.mjs';

export function encoded(value0, value1, value2, value3) {
  return ls.wireEncoded(value0, value1, value2, value3);
}

export function roundTrips(value0, value1, value2, value3) {
  return ls.wireRoundTrips(value0, value1, value2, value3);
}

export async function remoteShifted(value0) {
  const remote = await import('../lawspec_remote.mjs');
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

export function openTally(value0) {
  return new data.Tally(0n);
}

export function add(value0, value1) {
  const after = value0.count + BigInt(value1);
  return new data.Pair(after, new data.Tally(after));
}

export async function remoteAdds(value0) {
  const {TallyActor} = await import('../lawspec_actors.mjs');
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

export async function remoteDoubling(value0) {
  const {Doubling} = await import('../lawspec_sessions.mjs');
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
