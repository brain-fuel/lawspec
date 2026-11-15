export function loanDays(renewals: number): number
{
  return 14 + 7 * renewals;
}
