export function sort(xs: number[]): number[]
{
  return [...xs].sort((a, b) => a - b);
}
