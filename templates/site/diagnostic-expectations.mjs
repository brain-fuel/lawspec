// A rejection fixture checks compiler behavior. It establishes no law evidence.
export function rejectionOutcome(expected, result) {
  const diagnostics = result?.diagnostics;
  if (typeof expected !== "string" || !/^[\p{L}\p{N}_.-]+$/u.test(expected))
    return { matches: false, message: "A rejection fixture needs a diagnostic code." };
  if (!Array.isArray(diagnostics) || diagnostics.some(d => typeof d?.code !== "string"))
    return { matches: false, message: "The compiler returned an invalid diagnostic response." };
  if (diagnostics.length === 1 && diagnostics[0].code === expected)
    return { matches: true, diagnostics, message: `Expected compiler rejection: ${expected}.` };
  if (diagnostics.length === 0)
    return { matches: false, diagnostics, message: `Expected compiler rejection ${expected}; the specification compiled.` };
  return { matches: false, diagnostics, message: `Expected exactly one diagnostic (${expected}); received ${diagnostics.map(d => d.code).join(", ")}.` };
}

export function diagnosticText(diagnostics) {
  return diagnostics.map(d =>
    `${d.at ? `${d.at.file}:${d.at.line}:${d.at.column}: ` : ""}${d.code}: ${d.message}`,
  ).join("\n");
}
