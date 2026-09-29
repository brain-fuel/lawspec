export const validPort = x => x >= 1 && x <= 65535;
export function render(x) { if (!validPort(x)) throw new Error("invalid port"); return String(x); }
export const parse = x => Number(x);
