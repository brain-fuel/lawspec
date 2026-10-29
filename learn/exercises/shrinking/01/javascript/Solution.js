export function unique(xs)
{
  return [...new Set(xs.filter(x => x !== 0))];
}
