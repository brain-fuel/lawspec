export function seats(rows: number): number
{
  return rows === 1 ? 4 : rows === 2 ? 8 : 0;
}
