export function loanDays(renewals: number): number
{
  return 28 + 7 * renewals;
}
