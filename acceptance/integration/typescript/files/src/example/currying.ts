export const sumFour = (a: bigint,b: bigint,c: bigint,d: bigint): bigint => a+b+c+d;
export const format = (prefix: string,enabled: boolean,port: number,suffix: string): string => prefix+(enabled?String(port):"")+suffix;
export const referenceFormat = (prefix: string,enabled: boolean,port: number,suffix: string): string => [prefix,enabled?port.toString():"",suffix].join("");
export const trim = (x: string): string => x.trim();
