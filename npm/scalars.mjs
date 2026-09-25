// Human-readable, lossless API v2 scalar display.
export function showScalar(v) {
  if (!v || typeof v !== 'object') throw new TypeError('Expected an API v2 scalar');
  if ('coefficient' in v) return `${v.coefficient}e${v.exponent}`;
  if ('numerator' in v) return `rational(${v.numerator}, ${v.denominator})`;
  if ('bits' in v) return `${v.type === 'Float32' ? 'float32Bits' : 'float64Bits'}(${JSON.stringify(v.bits)})`;
  if ('real' in v) return `${v.type}(${showScalar(v.real)}, ${showScalar(v.imaginary)})`;
  if ('units' in v) return v.type === 'Text' ? JSON.stringify(v.units.map(c => String.fromCodePoint(c)).join('')) : `${v.type}([${v.units.join(', ')}])`;
  if (v.type === 'Symbol') return `symbol(${JSON.stringify(v.id)}, ${JSON.stringify(v.description)})`;
  if (v.type === 'Optional' || v.type === 'Nullable') return v.value === null ? (v.type === 'Optional' ? 'undefined' : 'null') : `${v.type.toLowerCase()}(${showScalar(v.value)})`;
  if ('value' in v) return String(v.value);
  return {Unit:'unitValue', Null:'null', Undefined:'undefined'}[v.type] ?? v.type;
}
