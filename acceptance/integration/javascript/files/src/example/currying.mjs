export const sumFour = (a,b,c,d) => a+b+c+d;
export const format = (prefix,enabled,port,suffix) => prefix+(enabled?String(port):"")+suffix;
export const referenceFormat = (prefix,enabled,port,suffix) => [prefix,enabled?port.toString():"",suffix].join("");
export const trim = (x) => x.trim();
