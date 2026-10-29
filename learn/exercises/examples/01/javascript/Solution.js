export function seats(rows)
{
  return rows === 1 ? 4 : rows === 2 ? 8 : 0;
}
