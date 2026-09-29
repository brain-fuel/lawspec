export const render = (x: number): string => String(x);
export const referenceRender = (x: number): string => x.toString(10);
export const clamp = (x: number): number => Math.max(0, x);
export const referenceClamp = (x: number): number => x < 0 ? 0 : x;
