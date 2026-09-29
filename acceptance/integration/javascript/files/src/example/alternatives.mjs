export const render = x => String(x);
export const referenceRender = x => x.toString(10);
export const clamp = x => Math.max(0, x);
export const referenceClamp = x => x < 0 ? 0 : x;
