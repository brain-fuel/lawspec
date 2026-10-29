export function sort(xs: number[]): number[]
{
  return [...new Set(xs)].sort((a, b) => a - b);
}
