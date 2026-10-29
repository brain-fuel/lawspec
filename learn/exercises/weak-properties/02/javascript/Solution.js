export function sort(xs)
{
  return [...new Set(xs)].sort((a, b) => a - b);
}
